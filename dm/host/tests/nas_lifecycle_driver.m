// 使用假传输和临时存档验证真实生命周期调度；直接包含实现以驱动私有钩子，不增加测试专用接口。
// Exercise real lifecycle scheduling with fake transport and disposable saves.
// Include the implementation to drive its private hooks without test-only APIs.
#import "../../ios/Sources/nas_sync.m"

void (*g_dm_save_commit_hook)(const char *);
void (*g_dm_ingame_hook)(int);
void (*g_dm_charsel_hook)(void);
void dm_icloud_boot(void) {}
void dm_icloud_flush(int bg) { (void)bg; }
void dm_icloud_foreground(void) {}
int dm_icloud_flush_wait(double seconds) { (void)seconds; return 1; }
NSString *DMNASHash(NSData *data) { return [data base64EncodedStringWithOptions:0]; }
NSDictionary *DMNASGroups(NSDictionary *snapshot, NSDictionary *known, NSError **error) {
    (void)known; (void)error; return snapshot[@"groups"];
}
BOOL DMNASValidPath(NSString *path) { return path.length > 0; }

static dispatch_semaphore_t attempted;
static dispatch_semaphore_t uploadStarted, releaseUpload;
static _Atomic int pauseFirstUpload;
static NSMutableArray<NSString *> *uploads;
static NSMutableArray<NSNumber *> *uploadTimes;
static BOOL failNext;
@implementation DMNASStore
- (NSDictionary *)knownGroups { return @{}; }
- (BOOL)probe:(NSError **)error { (void)error; return YES; }
- (NSDictionary *)snapshot:(NSString *)directory savedAt:(double)stamp error:(NSError **)error {
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSMutableData *combined = [NSMutableData data];
    for (NSString *key in @[@"character:Hero", @"stash:SharedStashSoftCoreV2"]) {
        NSString *file = [key hasPrefix:@"character:"] ? @"Hero.d2s" : @"SharedStashSoftCoreV2.d2i";
        NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:file]];
        if (data) { groups[key] = @{@"digest":DMNASHash(data), @"files":@[file]}; [combined appendData:data]; }
    }
    (void)error; return @{@"digest":DMNASHash(combined), @"savedAt":@(stamp), @"groups":groups};
}
- (BOOL)sync:(NSString *)snapshot save:(NSString *)save allowDownload:(BOOL)allow error:(NSError **)error { return [self sync:snapshot save:save groups:nil allowDownload:allow error:error]; }
- (BOOL)sync:(NSString *)snapshot save:(NSString *)save groups:(NSSet *)groups allowDownload:(BOOL)allow error:(NSError **)error {
    (void)save; (void)allow;
    if (self.activity) self.activity(DMNASActivityUploading);
    BOOL ok = !failNext; failNext = NO;
    if (ok) {
        NSDictionary *snap = [self snapshot:snapshot savedAt:0 error:error];
        for (NSString *key in [[snap[@"groups"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            if (groups && ![groups containsObject:key]) continue;
            NSString *file = [snap[@"groups"][key][@"files"] firstObject];
            NSString *text = [NSString stringWithContentsOfFile:[snapshot stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:error];
            if (!text) return NO;
            if (atomic_exchange(&pauseFirstUpload, 0)) {
                dispatch_semaphore_signal(uploadStarted);
                dispatch_semaphore_wait(releaseUpload, DISPATCH_TIME_FOREVER);
            }
            [uploads addObject:text]; [uploadTimes addObject:@(syncClock())]; self.message = @"test sync";
        }
    } else if (error) *error = [NSError errorWithDomain:@"Test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"offline"}];
    if (self.activity) self.activity(DMNASActivityChecking);
    dispatch_semaphore_signal(attempted); return ok;
}
- (NSArray<NSDictionary *> *)history:(NSError **)error { (void)error; return @[]; }
- (BOOL)scheduleRestore:(NSString *)revision error:(NSError **)error { (void)revision; (void)error; return NO; }
@end

static void drain(void) { dispatch_sync(queue, ^{}); }
static void saveText(NSString *text) {
    [text writeToFile:[saveDir stringByAppendingPathComponent:@"Hero.d2s"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    commit(saveDir.fileSystemRepresentation);
}
static BOOL waitAttempt(double seconds) {
    if (dispatch_semaphore_wait(attempted, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)))) return NO;
    drain(); return YES;
}
#define REQUIRE(condition) do { if (!(condition)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #condition); return 1; } } while (0)

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"nas-lifecycle-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    initQueue(); store = [DMNASStore new]; store.root = @"https://invalid.example/unused"; store.username = @"test";
    store.cache = [root stringByAppendingPathComponent:@"cache"]; saveDir = [root stringByAppendingPathComponent:@"save"];
    for (NSString *path in @[store.cache, saveDir]) [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    nasActive = YES; uploads = [NSMutableArray array]; uploadTimes = [NSMutableArray array]; attempted = dispatch_semaphore_create(0);
    uploadStarted = dispatch_semaphore_create(0); releaseUpload = dispatch_semaphore_create(0);
    @try {
        NSString *scenario = @(argv[1]);
        if ([scenario isEqual:@"presentation"]) {
            __block BOOL correct = YES;
            withActivity(store, ^BOOL {
                correct &= dm_nas_build_phase() == DM_SYNC_BUILD;
                store.activity(DMNASActivityChecking); correct &= dm_nas_build_phase() == DM_SYNC_BUILD;
                store.activity(DMNASActivityUploading); correct &= dm_nas_build_phase() == DM_SYNC_UPLOAD;
                store.activity(DMNASActivityChecking); correct &= dm_nas_build_phase() == DM_SYNC_UPLOAD;
                store.activity(DMNASActivityDownloading); correct &= dm_nas_build_phase() == DM_SYNC_DOWNLOAD;
                store.activity(DMNASActivityChecking); correct &= dm_nas_build_phase() == DM_SYNC_DOWNLOAD;
                return YES;
            });
            REQUIRE(correct && dm_nas_build_phase() == DM_SYNC_COMPLETE);
            @synchronized(DMNASStore.class) { buildBadge.complete_until = syncClock() - 1; }
            REQUIRE(dm_nas_build_phase() == DM_SYNC_BUILD);
            withActivity(store, ^BOOL { store.activity(DMNASActivityUploading); return YES; });
            REQUIRE(dm_nas_build_phase() == DM_SYNC_COMPLETE);
            withActivity(store, ^BOOL {
                correct &= dm_nas_build_phase() == DM_SYNC_BUILD;
                store.activity(DMNASActivityDownloading); return NO;
            });
            REQUIRE(correct && dm_nas_build_phase() == DM_SYNC_BUILD);
            withActivity(store, ^BOOL { store.activity(DMNASActivityChecking); return YES; });
            REQUIRE(dm_nas_build_phase() == DM_SYNC_BUILD);
            @try {
                withActivity(store, ^BOOL { store.activity(DMNASActivityUploading); @throw [NSException exceptionWithName:@"test" reason:@"interrupted" userInfo:nil]; });
            } @catch (NSException *exception) { (void)exception; }
            REQUIRE(dm_nas_build_phase() == DM_SYNC_BUILD && !store.activity);
        } else if ([scenario isEqual:@"exit-late-save"]) {
            uint64_t exitTime = syncClock();
            saveText(@"first"); drain(); nasCharsel(); drain();
            REQUIRE(waitAttempt(2));
            REQUIRE(uploads.count == 1 && [uploads[0] isEqual:@"first"]);
            REQUIRE(uploadTimes[0].unsignedLongLongValue - exitTime < 2 * NSEC_PER_SEC);
            usleep(5 * 1000000); // 较晚的成功提交也必须绕过 30 秒限流。 | A later successful commit must bypass the 30-second throttle too.
            [@"late-stash" writeToFile:[saveDir stringByAppendingPathComponent:@"SharedStashSoftCoreV2.d2i"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            uint64_t stashTime = syncClock(); commit(saveDir.fileSystemRepresentation); drain();
            REQUIRE(waitAttempt(8));
            REQUIRE(uploads.count == 2 && [uploads[1] isEqual:@"late-stash"]);
            REQUIRE(uploadTimes[1].unsignedLongLongValue - exitTime < 8 * NSEC_PER_SEC);
            REQUIRE(uploadTimes[1].unsignedLongLongValue - stashTime >= saveQuietTime);
        } else if ([scenario isEqual:@"transfer-kind"]) {
            __block BOOL correct = YES;
            withActivity(store, ^BOOL {
                store.activityKind = @"character"; store.activity(DMNASActivityUploading);
                correct &= dm_nas_build_phase() == DM_SYNC_CHARACTER_UPLOAD && [dm_nas_button_title() isEqual:@"角色上传中…"];
                store.activity(DMNASActivityChecking); correct &= dm_nas_build_phase() == DM_SYNC_CHARACTER_UPLOAD;
                store.activityKind = @"stash"; store.activity(DMNASActivityUploading);
                correct &= dm_nas_build_phase() == DM_SYNC_STASH_UPLOAD && [dm_nas_button_title() isEqual:@"仓库上传中…"];
                store.activity(DMNASActivityVerifying); correct &= dm_nas_build_phase() == DM_SYNC_VERIFY;
                store.groupFinished(@"stash:test", @"stash"); return YES;
            });
            REQUIRE(correct && dm_nas_build_phase() == DM_SYNC_STASH_COMPLETE);
            withActivity(store, ^BOOL {
                correct &= store.activityKind == nil;
                store.activityKind = @"character"; store.activity(DMNASActivityDownloading);
                correct &= dm_nas_build_phase() == DM_SYNC_CHARACTER_DOWNLOAD && [dm_nas_button_title() isEqual:@"角色下载中…"];
                store.activityKind = @"stash"; store.activity(DMNASActivityDownloading);
                correct &= dm_nas_build_phase() == DM_SYNC_STASH_DOWNLOAD && [dm_nas_button_title() isEqual:@"仓库下载中…"];
                store.activityKind = @"auxiliary"; store.activity(DMNASActivityDownloading);
                correct &= dm_nas_build_phase() == DM_SYNC_DOWNLOAD && [dm_nas_button_title() isEqual:@"下载中…"];
                return YES;
            });
            REQUIRE(correct && dm_nas_build_phase() == DM_SYNC_COMPLETE);
        } else if ([scenario isEqual:@"group-presentation"]) {
            __block BOOL verifying = NO;
            withActivity(store, ^BOOL {
                store.activity(DMNASActivityUploading); store.activity(DMNASActivityVerifying);
                verifying = dm_nas_build_phase() == DM_SYNC_VERIFY;
                store.groupFinished(@"character:Hero", @"character"); return YES;
            });
            REQUIRE(verifying && dm_nas_build_phase() == DM_SYNC_CHARACTER_COMPLETE);
            withActivity(store, ^BOOL { store.activity(DMNASActivityUploading); store.groupFinished(@"stash:SharedStashSoftCoreV2", @"stash"); return YES; });
            REQUIRE(dm_nas_build_phase() == DM_SYNC_STASH_COMPLETE);
        } else if ([scenario isEqual:@"no-change"]) {
            saveText(@"same"); drain(); nasCharsel(); REQUIRE(waitAttempt(2));
            saveText(@"same"); drain();
            REQUIRE(pending == nil && pendingTimes.count == 0 && uploads.count == 1);
        } else if ([scenario isEqual:@"failed-backoff"]) {
            saveText(@"offline"); drain(); nasCharsel(); failNext = YES;
            REQUIRE(waitAttempt(2));
            saveText(@"new-save-after-failure"); drain();
            REQUIRE(!waitAttempt(.5) && uploads.count == 0 && pending != nil);
            dispatch_async(queue, ^{ flush(25, YES); }); REQUIRE(waitAttempt(2));
            REQUIRE(uploads.count == 1 && [uploads[0] isEqual:@"new-save-after-failure"]);
        } else if ([scenario isEqual:@"empty-offline-start"]) {
            [NSFileManager.defaultManager createDirectoryAtPath:[store.cache stringByAppendingPathComponent:@"empty"] withIntermediateDirectories:YES attributes:nil error:nil];
            pending = [store.cache stringByAppendingPathComponent:@"empty"]; pendingAll = YES;
            dispatch_async(queue, ^{ flush(25, NO); }); REQUIRE(waitAttempt(2));
            REQUIRE(pending == nil && !pendingAll);
        } else if ([scenario isEqual:@"group-quiet-times"]) {
            dispatch_semaphore_t occupied = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
            dispatch_async(queue, ^{ dispatch_semaphore_signal(occupied); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
            REQUIRE(!dispatch_semaphore_wait(occupied, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
            saveText(@"character-ready"); usleep(300000);
            [@"stash-just-committed" writeToFile:[saveDir stringByAppendingPathComponent:@"SharedStashSoftCoreV2.d2i"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            uint64_t stashTime = syncClock(); commit(saveDir.fileSystemRepresentation); atomic_store(&exitMode, 1);
            dispatch_semaphore_signal(release);
            REQUIRE(waitAttempt(2)); REQUIRE(waitAttempt(2));
            REQUIRE(([uploads isEqual:@[@"character-ready", @"stash-just-committed"]]));
            REQUIRE(uploadTimes[0].unsignedLongLongValue - stashTime < saveQuietTime);
            REQUIRE(uploadTimes[1].unsignedLongLongValue - stashTime >= saveQuietTime);
        } else if ([scenario isEqual:@"queued-new-save"]) {
            saveText(@"old"); drain();
            dispatch_semaphore_t occupied = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
            dispatch_async(queue, ^{ dispatch_semaphore_signal(occupied); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); });
            REQUIRE(!dispatch_semaphore_wait(occupied, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)));
            atomic_store(&latestSaveClock, syncClock() - 10 * NSEC_PER_SEC);
            dispatch_async(queue, ^{ flush(25, NO); }); // 定时器先于快照派发进入队列。 | Timer queued before snapshot delivery.
            uint64_t saved = syncClock(); saveText(@"latest-while-queue-busy");
            dispatch_semaphore_signal(release);
            REQUIRE(waitAttempt(6));
            REQUIRE(uploads.count == 1 && [uploads[0] isEqual:@"latest-while-queue-busy"]);
            REQUIRE(uploadTimes[0].unsignedLongLongValue - saved >= saveQuietTime);
        } else if ([scenario isEqual:@"manual"] || [scenario isEqual:@"background"]) {
            saveText(@"immediate"); drain(); nasCharsel(); drain();
            uint64_t start = syncClock();
            if ([scenario isEqual:@"manual"]) dm_nas_now(^(NSString *message) { (void)message; });
            else dm_cloud_flush(1);
            REQUIRE(waitAttempt(2));
            REQUIRE(uploads.count == 1 && [uploads[0] isEqual:@"immediate"]);
            REQUIRE(uploadTimes[0].unsignedLongLongValue - start < 2 * NSEC_PER_SEC);
        } else if ([scenario isEqual:@"save-during-upload"]) {
            saveText(@"already-uploading"); drain(); atomic_store(&pauseFirstUpload, 1);
            atomic_store(&background, 1); dispatch_async(queue, ^{ flush(25, YES); });
            REQUIRE(!dispatch_semaphore_wait(uploadStarted, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)));
            REQUIRE(dm_nas_build_phase() == DM_SYNC_UPLOAD);
            saveText(@"new-progress-during-upload"); dispatch_semaphore_signal(releaseUpload);
            REQUIRE(waitAttempt(2)); REQUIRE(waitAttempt(2));
            REQUIRE(([uploads isEqual:@[@"already-uploading", @"new-progress-during-upload"]]));
            REQUIRE(pending == nil && pendingGeneration == atomic_load(&saveGeneration));
        } else if ([scenario isEqual:@"failed-retry"]) {
            saveText(@"retained"); drain(); failNext = YES;
            dispatch_async(queue, ^{ flush(25, YES); });
            REQUIRE(waitAttempt(2)); REQUIRE(pending != nil && uploads.count == 0);
            REQUIRE(dm_nas_build_phase() == DM_SYNC_BUILD);
            REQUIRE([dm_nas_button_title() isEqual:@"存档同步"]);
            dispatch_async(queue, ^{ flush(25, YES); });
            REQUIRE(waitAttempt(2)); REQUIRE(pending == nil && uploads.count == 1);
            REQUIRE([uploads[0] isEqual:@"retained"]);
            REQUIRE(dm_nas_build_phase() == DM_SYNC_COMPLETE);
        } else return 2;
        REQUIRE([dm_nas_button_title() isEqual:@"存档同步"]);
        puts("PASS"); return 0;
    } @finally {
        dispatch_sync(queue, ^{ nasActive = NO; ++flushTicket; });
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    }
} }
