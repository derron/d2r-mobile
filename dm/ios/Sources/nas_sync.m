// NAS 仅在选中后接管已有保存与生命周期钩子，否则沿用 iCloud；不直接依赖游戏地址。
// NAS owns the existing save/lifecycle hooks only when selected; iCloud is unchanged otherwise.
#include "../../host/dm_i18n.h"
#import "nas_sync.h"
#import "nas_store.h"
#import <Security/Security.h>
#import <Network/Network.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#include <sys/clonefile.h>
#include <stdatomic.h>
#include <time.h>
#include <stdio.h>

extern void (*g_dm_save_commit_hook)(const char *);
extern void (*g_dm_ingame_hook)(int);
extern void (*g_dm_charsel_hook)(void);
void dm_icloud_boot(void), dm_icloud_flush(int), dm_icloud_foreground(void);
int dm_icloud_flush_wait(double);
static dispatch_queue_t queue;
static dispatch_source_t timer;
static nw_path_monitor_t monitor;
static DMNASStore *store;
static NSString *saveDir, *pending, *statusText;
static NSString *buttonTitle;
static dm_sync_badge buildBadge;
static BOOL nasActive, blocked, pendingAll;
static _Atomic int background;
// 网络占用串行队列时，保存钩子仍在游戏线程运行；快照派发块执行前立即公布时间与代次。
// Save hooks run on game threads while network work occupies queue. Publish
// their time/generation immediately, before their snapshot-delivery block runs.
static _Atomic uint64_t latestSaveClock, saveGeneration;
static _Atomic int exitMode;
static NSMutableDictionary *committedGroups, *pendingTimes;
static NSMutableSet *restartGroups;
static uint64_t pendingGeneration, lastAttemptClock, retryNotBefore, flushTicket, batchNumber;
static const uint64_t saveQuietTime = NSEC_PER_SEC / 5;
static uint64_t syncClock(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
static void initQueue(void) { static dispatch_once_t once; dispatch_once(&once, ^{ queue = dispatch_queue_create("dm.nas", DISPATCH_QUEUE_SERIAL); }); }
static NSString *baseDir(void) {
    const char *p = getenv("DM_SAVE");
    return p ? @(p).stringByDeletingLastPathComponent : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static NSString *configPath(void) { return [baseDir() stringByAppendingPathComponent:@"save-sync.json"]; }
static NSDictionary *readConfig(void) {
    NSData *d = [NSData dataWithContentsOfFile:configPath()]; id c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([c isKindOfClass:NSDictionary.class] && [@[@"off", @"icloud", @"nas"] containsObject:c[@"mode"]] && [c[@"url"] isKindOfClass:NSString.class] && [c[@"username"] isKindOfClass:NSString.class]) return c;
    return @{@"mode":d ? @"off" : @"icloud", @"url":@"", @"username":@""};
}
NSDictionary *dm_nas_config(void) { return readConfig(); }
static NSString *space(NSDictionary *c) { return DMNASHash([[NSString stringWithFormat:@"%@\n%@", c[@"url"], c[@"username"]] dataUsingEncoding:NSUTF8StringEncoding]); }
static NSDictionary *credentialKey(NSDictionary *c) { return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:@"D2RMobile.WebDAV", (__bridge id)kSecAttrAccount:space(c)}; }
static NSString *passwordFor(NSDictionary *c) {
    NSMutableDictionary *q = [credentialKey(c) mutableCopy]; q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef d = NULL; if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &d) != errSecSuccess) return @"";
    return [[NSString alloc] initWithData:CFBridgingRelease(d) encoding:NSUTF8StringEncoding] ?: @"";
}
static NSDictionary *normalized(NSDictionary *input, NSError **e) {
    NSString *mode = input[@"mode"], *user = input[@"username"], *url = input[@"url"];
    if (![@[@"off", @"icloud", @"nas"] containsObject:mode] || ![url isKindOfClass:NSString.class] || ![user isKindOfClass:NSString.class]) { DMNASIssue(e, DMNASConfigurationError, "ConfigInvalid", 0); return nil; }
    url = [url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([url hasSuffix:@"/"]) url = [url substringToIndex:url.length - 1];
    NSURLComponents *u = [NSURLComponents componentsWithString:url];
    if ([mode isEqual:@"nas"] && (![u.scheme isEqual:@"https"] || !u.host.length || u.user || u.password || u.query || u.fragment || !user.length || [user containsString:@":"])) { DMNASIssue(e, DMNASConfigurationError, "ConfigRequired", 0); return nil; }
    return @{@"mode":mode, @"url":url, @"username":user};
}
static DMNASStore *makeStore(NSDictionary *c, NSString *password) {
    DMNASStore *s = [DMNASStore new]; s.root = c[@"url"]; s.username = c[@"username"]; s.password = password.length ? password : passwordFor(c);
    s.cache = [[baseDir() stringByAppendingPathComponent:@"SaveSync"] stringByAppendingPathComponent:space(c)];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults; NSString *device = [defaults stringForKey:@"SaveSyncDeviceID"];
    if (!device) { device = NSUUID.UUID.UUIDString; [defaults setObject:device forKey:@"SaveSyncDeviceID"]; }
    s.device = device; return s;
}
BOOL dm_nas_configure(NSDictionary *input, NSString *password, NSError **e) {
    NSDictionary *c = normalized(input, e); if (!c) return NO;
    if ([c[@"mode"] isEqual:@"nas"]) {
        if (password.length) {
            NSMutableDictionary *q = [credentialKey(c) mutableCopy]; NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
            OSStatus r = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});
            if (r == errSecItemNotFound) { q[(__bridge id)kSecValueData] = data; q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; r = SecItemAdd((__bridge CFDictionaryRef)q, NULL); }
            if (r != errSecSuccess) return DMNASIssue(e, DMNASKeychainError, "KeychainFailed", r);
        } else if (!passwordFor(c).length) return DMNASIssue(e, DMNASConfigurationError, "PasswordRequired", 0);
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:c options:NSJSONWritingSortedKeys error:e];
    BOOL ok = d && [d writeToFile:configPath() options:NSDataWritingAtomic error:e];
    if (!ok && e) *e = DMNASNormalize(*e, "save-config");
    return ok;
}
static void status(NSString *text) { @synchronized(DMNASStore.class) { statusText = [text copy]; } }
NSString *dm_nas_status(void) { @synchronized(DMNASStore.class) { return statusText ?: @(dm_ui("dmNasOff")); } }
NSString *dm_nas_button_title(void) { @synchronized(DMNASStore.class) { return buttonTitle ?: @(dm_ui("dmNasTitle")); } }
static void activityTitle(NSString *text) { @synchronized(DMNASStore.class) { buttonTitle = [text copy]; } }
dm_sync_phase dm_nas_build_phase(void) {
    @synchronized(DMNASStore.class) { return dm_sync_badge_get(&buildBadge, syncClock()); }
}
static void withActivity(DMNASStore *s, BOOL (^work)(void)) {
    @synchronized(DMNASStore.class) { dm_sync_badge_begin(&buildBadge); }
    activityTitle(@(dm_ui("dmSyncCheck")));
    s.activityKind = nil;
    __weak DMNASStore *activeStore = s;
    s.activity = ^(DMNASActivity phase) {
        NSString *kind = activeStore.activityKind;
        BOOL character = [kind isEqual:@"character"], stash = [kind isEqual:@"stash"];
        dm_sync_phase display = DM_SYNC_VERIFY;
        NSString *title = @(dm_ui("dmSyncCheck"));
        if (phase == DMNASActivityUploading) {
            display = character ? DM_SYNC_CHARACTER_UPLOAD : stash ? DM_SYNC_STASH_UPLOAD : DM_SYNC_UPLOAD;
            title = character ? @(dm_ui("dmSyncCharacterUpload")) : stash ? @(dm_ui("dmSyncStashUpload")) : @(dm_ui("dmSyncUpload"));
        } else if (phase == DMNASActivityDownloading) {
            display = character ? DM_SYNC_CHARACTER_DOWNLOAD : stash ? DM_SYNC_STASH_DOWNLOAD : DM_SYNC_DOWNLOAD;
            title = character ? @(dm_ui("dmSyncCharacterDownload")) : stash ? @(dm_ui("dmSyncStashDownload")) : @(dm_ui("dmSyncDownload"));
        }
        activityTitle(title);
        // 请求记账保留传输提示，仅明确的发布后校验切换为检查中。
        // Request bookkeeping keeps the transfer caption. Only the explicit
        // post-publication verification switches to checking.
        if (phase != DMNASActivityChecking) @synchronized(DMNASStore.class) {
            dm_sync_badge_transfer(&buildBadge, display);
        }
    };
    s.groupFinished = ^(NSString *group, NSString *kind) {
        (void)group;
        @synchronized(DMNASStore.class) {
            dm_sync_badge_group_finish(&buildBadge, [kind isEqual:@"character"] ? DM_SYNC_CHARACTER_COMPLETE : [kind isEqual:@"stash"] ? DM_SYNC_STASH_COMPLETE : DM_SYNC_COMPLETE, syncClock());
        }
    };
    BOOL success = NO;
    @try { success = work(); }
    @finally {
        s.activity = nil; s.groupFinished = nil; activityTitle(@(dm_ui("dmNasTitle")));
        @synchronized(DMNASStore.class) { dm_sync_badge_finish(&buildBadge, success && (!s.needsRestart || buildBadge.complete_until != 0), syncClock()); }
    }
}
static void doneMain(void (^done)(NSString *), NSString *s) { if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(s); }); }
void dm_nas_test(NSDictionary *input, NSString *password, void (^done)(NSString *)) {
    initQueue(); NSError *e; NSDictionary *c = normalized(input, &e);
    if (!c || ![c[@"mode"] isEqual:@"nas"]) { if (!e) DMNASIssue(&e, DMNASConfigurationError, "SelectWebDAV", 0); doneMain(done, DMNASMessage(e)); return; }
    dispatch_async(queue, ^{ @autoreleasepool {
        DMNASStore *s = makeStore(c, password); s.deadline = NSDate.date.timeIntervalSince1970 + 30;
        withActivity(s, ^BOOL { NSError *error; BOOL ok = [s probe:&error]; doneMain(done, ok ? s.message : DMNASMessage(error)); return ok; });
    } });
}
static BOOL capabilities(NSError **e) {
    NSString *p = [store.cache stringByAppendingPathComponent:@"capabilities.json"];
    NSData *d = [NSData dataWithContentsOfFile:p]; id c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([c isKindOfClass:NSDictionary.class] && [c[@"schema"] isEqual:@4] && [c[@"mode"] isEqual:@"single"] && [c[@"root"] isEqual:store.root] && [c[@"username"] isEqual:store.username]) return YES;
    return [store probe:e];
}
static void flush(double seconds, BOOL force);
static void scheduleFlush(double delay, BOOL force) {
    uint64_t ticket = ++flushTicket;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.01, delay) * NSEC_PER_SEC)), queue, ^{
        if (ticket == flushTicket) flush(25, force);
    });
}
static void flush(double seconds, BOOL force) {
    if (!nasActive || blocked || !pending) return;
    uint64_t generation = pendingGeneration;
    if (!force && !atomic_load(&background) && generation != atomic_load(&saveGeneration)) { scheduleFlush(0.01, NO); return; }
    uint64_t now = syncClock();
    BOOL exiting = atomic_load(&exitMode);
    NSMutableSet *readyGroups = [NSMutableSet set];
    uint64_t nextReady = UINT64_MAX;
    for (NSString *key in pendingTimes) {
        if (!force && [restartGroups containsObject:key]) continue;
        uint64_t ready = [pendingTimes[key] unsignedLongLongValue] + saveQuietTime;
        if (force || atomic_load(&background) || ready <= now) [readyGroups addObject:key];
        else nextReady = MIN(nextReady, ready);
    }
    if (pendingAll && !force && !atomic_load(&background)) {
        uint64_t latestReady = now;
        for (NSNumber *stamp in pendingTimes.allValues) latestReady = MAX(latestReady, stamp.unsignedLongLongValue + saveQuietTime);
        if (latestReady > now) { scheduleFlush((double)(latestReady - now) / NSEC_PER_SEC, NO); return; }
    }
    if (pendingAll && !readyGroups.count) [readyGroups addObject:@"auxiliary"];
    if (force && !readyGroups.count) [readyGroups addObject:@"auxiliary"];
    if (!readyGroups.count) { if (nextReady != UINT64_MAX) scheduleFlush((double)(nextReady - now) / NSEC_PER_SEC, force); return; }
    if (!force && !atomic_load(&background)) {
        uint64_t ready = !exiting && lastAttemptClock ? lastAttemptClock + 30 * NSEC_PER_SEC : 0;
        ready = MAX(ready, retryNotBefore);
        if (ready > now) { activityTitle(@(dm_ui("dmNasWaiting"))); scheduleFlush((double)(ready - now) / NSEC_PER_SEC, NO); return; }
    }
    ++flushTicket; uint64_t batch = ++batchNumber;
    fprintf(stderr, "NAS sync batch %llu begin generation %llu\n", (unsigned long long)batch, (unsigned long long)generation);
    withActivity(store, ^BOOL {
        store.deadline = NSDate.date.timeIntervalSince1970 + seconds; NSError *e = nil; lastAttemptClock = syncClock();
        if (!capabilities(&e) || ![store sync:pending save:saveDir groups:(force || pendingAll) ? nil : readyGroups allowDownload:NO error:&e]) {
            retryNotBefore = syncClock() + 30 * NSEC_PER_SEC;
            status(DMNASMessage(e));
            fprintf(stderr, "NAS sync batch %llu failed after %.2fs\n", (unsigned long long)batch, (double)(syncClock() - now) / NSEC_PER_SEC); return NO;
        }
        retryNotBefore = 0;
        BOOL needsRestart = store.needsRestart;
        if (needsRestart) { if (!restartGroups) restartGroups = [NSMutableSet set]; [restartGroups unionSet:store.restartGroups ?: readyGroups]; }
        status(needsRestart ? store.message : [NSString stringWithFormat:@"%@ · %@", store.message, [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle]]);
        if (needsRestart) dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:@"DMSaveSyncNeedsRestart" object:store.message]; });
        if (force || pendingAll) [pendingTimes removeAllObjects];
        else for (NSString *key in readyGroups) [pendingTimes removeObjectForKey:key];
        pendingAll = NO;
        if (!pendingTimes.count && !needsRestart) { [NSFileManager.defaultManager removeItemAtPath:pending error:nil]; pending = nil; }
        else if (pendingTimes.count) scheduleFlush(0, force);
        fprintf(stderr, "NAS sync batch %llu finished after %.2fs; newer save %s\n", (unsigned long long)batch, (double)(syncClock() - now) / NSEC_PER_SEC, generation != atomic_load(&saveGeneration) ? "yes" : "no");
        return YES;
    });
}
static NSDictionary *rememberCandidate(NSString *snap, double stamp) {
    NSError *e; NSDictionary *m = [store snapshot:snap savedAt:stamp error:&e];
    if (m) [[NSJSONSerialization dataWithJSONObject:m options:NSJSONWritingSortedKeys error:nil] writeToFile:[store.cache stringByAppendingPathComponent:@"candidate.json"] atomically:YES];
    return m;
}
static void commit(const char *dir) {
    // 本回调持有文件系统锁，只克隆快照，不计算 hash 或联网。
    // This callback holds the filesystem lock: clone only, never hash or perform network I/O here.
    double stamp = NSDate.date.timeIntervalSince1970;
    NSString *snap = [store.cache stringByAppendingPathComponent:[NSString stringWithFormat:@"pending-%.0f-%@", stamp * 1000, NSUUID.UUID.UUIDString]];
    if (clonefile(dir, snap.fileSystemRepresentation, 0)) { status(DMNASMessage([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil])); return; }
    uint64_t savedClock = syncClock(); atomic_store(&latestSaveClock, savedClock);
    uint64_t generation = atomic_fetch_add(&saveGeneration, 1) + 1;
    dispatch_async(queue, ^{ @autoreleasepool {
        if (pending) [NSFileManager.defaultManager removeItemAtPath:pending error:nil]; pending = snap;
        pendingGeneration = generation;
        NSDictionary *manifest = rememberCandidate(snap, stamp);
        NSError *e = nil; NSDictionary *fresh = manifest ? DMNASGroups(manifest, committedGroups ?: @{}, &e) : nil;
        if (!fresh) { status(DMNASMessage(e)); return; }
        if (!pendingTimes) pendingTimes = [NSMutableDictionary dictionary];
        NSMutableSet *keys = [NSMutableSet setWithArray:fresh.allKeys]; [keys addObjectsFromArray:committedGroups.allKeys];
        for (NSString *key in keys) {
            NSDictionary *old = committedGroups[key], *new = fresh[key];
            if (new ? ![old[@"digest"] isEqual:new[@"digest"]] : [old[@"files"] count] > 0) pendingTimes[key] = @(savedClock);
        }
        if (!committedGroups) committedGroups = [NSMutableDictionary dictionary];
        // 保留描述以识别删除归属；使用空摘要避免反复排入未变化的删除。
        // Keep descriptors for deletion ownership; use an empty digest to avoid requeuing unchanged deletions.
        for (NSString *key in keys) {
            if (fresh[key]) committedGroups[key] = fresh[key];
            else { NSMutableDictionary *empty = [committedGroups[key] mutableCopy]; empty[@"files"] = @[]; empty[@"digest"] = @"deleted"; committedGroups[key] = empty; }
        }
        if (!pendingAll && !pendingTimes.count) {
            [NSFileManager.defaultManager removeItemAtPath:pending error:nil]; pending = nil; return;
        }
        if (!blocked) status(@(dm_ui("dmNasWaiting")));
        if (!blocked) { activityTitle(@(dm_ui("dmNasWaiting"))); scheduleFlush(0, NO); }
    } });
}
static void nasIngame(int on) { if (on) atomic_store(&exitMode, 0); }
static void nasCharsel(void) {
    // 后续提交继续保留退局模式，因为没有整次退局保存结束信号。
    // Keep exit mode through all later commits; there is no whole-exit end signal.
    atomic_store(&exitMode, 1);
    dispatch_async(queue, ^{ flush(25, NO); });
}
void dm_cloud_boot(void) {
    initQueue(); NSDictionary *c = readConfig(); NSString *mode = c[@"mode"];
    if ([mode isEqual:@"off"]) return;
    if (![mode isEqual:@"nas"]) { dm_icloud_boot(); return; }
    const char *p = getenv("DM_SAVE");
    if (!p || getenv("DM_TEST_ICLOUD_OFF") || getenv("DM_SAVE_FRESH") || getenv("DM_SAVE_TEST") || getenv("DM_APP_SUPPORT")) { status(@(dm_ui("dmNasOff"))); return; }
    saveDir = @(p);
#if TARGET_OS_IPHONE
    NSString *real = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"save"];
    if (![saveDir.stringByStandardizingPath isEqual:real.stringByStandardizingPath]) return;
#else
    if (!getenv("DM_CLOUD_REAL")) return;
#endif
    store = makeStore(c, nil); NSError *e;
    if (![NSFileManager.defaultManager createDirectoryAtPath:store.cache withIntermediateDirectories:YES attributes:nil error:&e]) { status(DMNASMessage(e)); return; }
    [[NSURL fileURLWithPath:store.cache] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    nasActive = YES;
    // 串行启动屏障：禁止晚到的下载替换已挂载存档。
    // Serial boot barrier: no late download is allowed to replace a mounted save.
    dispatch_sync(queue, ^{ @autoreleasepool {
        withActivity(store, ^BOOL {
            store.deadline = NSDate.date.timeIntervalSince1970 + 8; NSError *error = nil;
            NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:store.cache error:nil] sortedArrayUsingSelector:@selector(compare:)];
            NSString *latest = nil; for (NSString *n in names) if ([n hasPrefix:@"pending-"]) latest = n;
            if (latest) { NSString *snap = [store.cache stringByAppendingPathComponent:latest]; double t = [[[latest componentsSeparatedByString:@"-"] objectAtIndex:1] doubleValue] / 1000; rememberCandidate(snap, t); }
            if (capabilities(&error) && [store sync:saveDir save:saveDir allowDownload:YES error:&error]) {
                status(store.message);
                for (NSString *n in names) if ([n hasPrefix:@"pending-"]) [NSFileManager.defaultManager removeItemAtPath:[store.cache stringByAppendingPathComponent:n] error:nil];
                return YES;
            } else {
                status(DMNASMessage(error));
                NSString *snap = [store.cache stringByAppendingPathComponent:[NSString stringWithFormat:@"pending-%.0f-%@", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString]];
                if (!clonefile(saveDir.fileSystemRepresentation, snap.fileSystemRepresentation, 0)) { pending = snap; pendingAll = YES; }
                return NO;
            }
        });
    } });
    NSDictionary *initial = [store snapshot:saveDir savedAt:0 error:nil];
    committedGroups = [[store knownGroups] mutableCopy];
    [committedGroups addEntriesFromDictionary:DMNASGroups(initial, committedGroups, nil) ?: @{}];
    pendingTimes = [NSMutableDictionary dictionary];
    if (pending) for (NSString *key in committedGroups) pendingTimes[key] = @0;
    g_dm_save_commit_hook = commit; g_dm_ingame_hook = nasIngame; g_dm_charsel_hook = nasCharsel;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), 30 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { flush(25, NO); } }); dispatch_resume(timer);
    monitor = nw_path_monitor_create(); nw_path_monitor_set_queue(monitor, queue);
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) { if (nw_path_get_status(path) == nw_path_status_satisfied) flush(25, NO); }); nw_path_monitor_start(monitor);
}
void dm_cloud_flush(int bg) {
    if (!nasActive) { dm_icloud_flush(bg); return; }
    atomic_store(&background, bg != 0);
#if TARGET_OS_IPHONE
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    if (bg) task = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"dm.nas" expirationHandler:^{ fprintf(stderr, "NAS background time expired\n"); status(@(dm_ui("dmNasWaiting"))); if (task != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } }];
#endif
    dispatch_async(queue, ^{ @autoreleasepool { flush(25, bg != 0);
#if TARGET_OS_IPHONE
        if (bg) dispatch_async(dispatch_get_main_queue(), ^{ if (task != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } });
#endif
    } });
}
int dm_cloud_flush_wait(double seconds) {
    if (!nasActive) return dm_icloud_flush_wait(seconds);
    dispatch_semaphore_t sem = dispatch_semaphore_create(0); dispatch_async(queue, ^{ flush(seconds, YES); dispatch_semaphore_signal(sem); });
    return !dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)));
}
void dm_cloud_foreground(void) { if (!nasActive) { dm_icloud_foreground(); return; } atomic_store(&background, 0); dispatch_async(queue, ^{ flush(25, NO); }); }
void dm_nas_now(void (^done)(NSString *)) {
    initQueue(); dispatch_async(queue, ^{ @autoreleasepool {
        // 没有本机上传时，手动同步仍需发现 NAS 修改。
        // A manual sync must also discover NAS edits when there is no local upload.
        if (nasActive && !blocked && !pending) {
            NSString *snap = [store.cache stringByAppendingPathComponent:[NSString stringWithFormat:@"pending-%.0f-%@", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString]];
            if (clonefile(saveDir.fileSystemRepresentation, snap.fileSystemRepresentation, 0)) { doneMain(done, DMNASMessage([NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil])); return; }
            pending = snap; pendingGeneration = atomic_load(&saveGeneration);
            NSDictionary *manifest = rememberCandidate(snap, 0);
            NSDictionary *groups = DMNASGroups(manifest, committedGroups ?: @{}, nil);
            if (!pendingTimes) pendingTimes = [NSMutableDictionary dictionary];
            for (NSString *key in groups) pendingTimes[key] = @0;
            for (NSString *key in committedGroups) pendingTimes[key] = @0;
        }
        if (nasActive) { for (NSString *key in committedGroups) pendingTimes[key] = @0; store.refreshCurrentFiles = YES; flush(25, YES); store.refreshCurrentFiles = NO; }
        doneMain(done, nasActive ? dm_nas_status() : @(dm_ui("dmNasEnableRestart")));
    } });
}
void dm_nas_history(void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    initQueue(); NSDictionary *c = readConfig();
    dispatch_async(queue, ^{ @autoreleasepool {
        DMNASStore *s = makeStore(c, nil); s.deadline = NSDate.date.timeIntervalSince1970 + 60;
        withActivity(s, ^BOOL { NSError *e; NSArray *v = [s history:&e]; dispatch_async(dispatch_get_main_queue(), ^{ done(v, e ? DMNASMessage(e) : nil); }); return v != nil; });
    } });
}
void dm_nas_restore(NSString *revision, void (^done)(NSString *)) {
    initQueue(); NSDictionary *c = readConfig(); dispatch_async(queue, ^{ @autoreleasepool {
        DMNASStore *s = makeStore(c, nil); s.deadline = NSDate.date.timeIntervalSince1970 + 20;
        withActivity(s, ^BOOL { NSError *e; BOOL ok = [s scheduleRestore:revision error:&e]; if (ok && [s.cache isEqual:store.cache]) blocked = YES; doneMain(done, ok ? @(dm_ui("dmNasRestoreScheduled")) : DMNASMessage(e)); return ok; });
    } });
}
