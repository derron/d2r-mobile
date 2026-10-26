// 全新包后端的本机配置与设置界面；不读取其他 WebDAV 协议的配置或缓存。
// Local configuration and settings for the new pack backend; no other WebDAV configuration or cache is imported.
#import "webdav_settings.h"
#if DM_WEBDAV
#import "webdav_store.h"
#import <Security/Security.h>
#import <TargetConditionals.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#include "../../host/dm_i18n.h"
static dispatch_queue_t work;
static NSDictionary *activeConfig;
static NSString *activePassword, *profile, *backupDirectory;
static _Atomic int ready;
static NSString *ui(const char *key) { return @(dm_ui(key)); }
static NSString *base(void) { const char *s = getenv("DM_SAVE"); return s ? @(s).stringByDeletingLastPathComponent : NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject; }
static NSString *configFile(void) { return [base() stringByAppendingPathComponent:@"webdav-packs.json"]; }
// 测试只允许显式隔离存档和本机回环假服务器，不读取真实密码。
// Tests require isolated saves and an explicit loopback fake server; no real password is read.
int dm_webdav_test_mode(void) {
    const char *url = getenv("DM_TEST_WEBDAV_URL"); if (!url || (!getenv("DM_APP_SUPPORT") && !getenv("DM_SAVE_TEST"))) return 0;
    NSURLComponents *u = [NSURLComponents componentsWithString:@(url)];
    return [u.scheme isEqual:@"http"] && [@[@"127.0.0.1", @"localhost", @"::1"] containsObject:u.host] && !u.user && !u.password && !u.query && !u.fragment;
}
static NSDictionary *configuration(void) { if (dm_webdav_test_mode()) return @{@"url":@(getenv("DM_TEST_WEBDAV_URL")), @"username":@"test"}; NSData *d = [NSData dataWithContentsOfFile:configFile()]; id c = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil; return [c isKindOfClass:NSDictionary.class] ? c : @{}; }
static NSDictionary *normalized(NSDictionary *input) {
    if (![input[@"url"] isKindOfClass:NSString.class] || ![input[@"username"] isKindOfClass:NSString.class]) return nil;
    NSString *url = [input[@"url"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], *user = input[@"username"];
    while ([url hasSuffix:@"/"]) url = [url substringToIndex:url.length - 1];
    NSURLComponents *u = [NSURLComponents componentsWithString:url];
    BOOL loopback = dm_webdav_test_mode() && [u.scheme isEqual:@"http"] && [@[@"127.0.0.1", @"localhost", @"::1"] containsObject:u.host];
    if ((!loopback && ![u.scheme isEqual:@"https"]) || !u.host.length || u.user || u.password || u.query || u.fragment || !user.length || user.length > 256 || url.length > 4096 || [user containsString:@":"]) return nil;
    return @{@"url":url, @"username":user};
}
static NSString *identifier(NSDictionary *c) { NSData *d = [[NSString stringWithFormat:@"%@\n%@", c[@"url"], c[@"username"]] dataUsingEncoding:NSUTF8StringEncoding]; unsigned char bytes[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, bytes); NSMutableString *s = [NSMutableString string]; for (unsigned i = 0; i < sizeof bytes; i++) [s appendFormat:@"%02x", bytes[i]]; return s; }
static NSDictionary *key(NSDictionary *c) { return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:@"D2RMobile.WebDAVPacks", (__bridge id)kSecAttrAccount:identifier(c)}; }
static NSString *password(NSDictionary *c) { if (dm_webdav_test_mode()) return @"test"; if (!c) return @""; NSMutableDictionary *q = [key(c) mutableCopy]; q[(__bridge id)kSecReturnData] = @YES; CFTypeRef result = NULL; if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) != errSecSuccess) return @""; return [[NSString alloc] initWithData:CFBridgingRelease(result) encoding:NSUTF8StringEncoding] ?: @""; }
static BOOL saveConfig(NSDictionary *input, NSString *secret) {
    NSDictionary *c = normalized(input); if (!c || (!secret.length && !password(c).length)) return NO;
    if (secret.length) { NSMutableDictionary *q = [key(c) mutableCopy]; NSData *data = [secret dataUsingEncoding:NSUTF8StringEncoding]; OSStatus result = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});
        if (result == errSecItemNotFound) { q[(__bridge id)kSecValueData] = data; q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; result = SecItemAdd((__bridge CFDictionaryRef)q, NULL); } if (result != errSecSuccess) return NO; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:c options:0 error:nil]; BOOL ok = data && [data writeToFile:configFile() options:NSDataWritingAtomic error:nil]; if (ok) atomic_store(&ready, 1); return ok;
}
void dm_webdav_load_configuration(void) { NSDictionary *c = normalized(configuration()); atomic_store(&ready, c && password(c).length > 0); }
int dm_webdav_config_ready(void) { return atomic_load(&ready); }
static dispatch_queue_t queue(void) { if (!work) work = dispatch_queue_create("dm.webdav.settings", DISPATCH_QUEUE_SERIAL); return work; }
static NSString *temporaryRoot(void) { return [NSTemporaryDirectory() stringByAppendingPathComponent:@"D2RWebDAVPacks"]; }
static DMWebDAVStore *store(NSDictionary *c, NSString *secret, NSTimeInterval seconds) { DMWebDAVStore *s = [DMWebDAVStore new]; s.root = c[@"url"]; s.username = c[@"username"]; s.password = secret.length ? secret : password(c); s.deadline = NSProcessInfo.processInfo.systemUptime + seconds; s.testLoopback = dm_webdav_test_mode(); return s; }
BOOL dm_webdav_prepare(NSString *save, dispatch_queue_t q, NSString **scratch, NSString **backup, NSString **state) {
    work = q; NSDictionary *c = normalized(configuration()); atomic_store(&ready, c && password(c).length > 0);
    if (!dm_webdav_config_ready()) { fprintf(stderr, "WebDAV configuration unavailable\n"); return NO; }
    activeConfig = c; activePassword = password(c); profile = [[save.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"WebDAVPacks"] stringByAppendingPathComponent:identifier(c)];
    backupDirectory = [profile stringByAppendingPathComponent:@"backups"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    // 临时轮次可重建；基线、备份与收件箱不在这里清理。
    // Transfer rounds can be recreated; baselines, backups and inboxes are not cleaned here.
    [NSFileManager.defaultManager removeItemAtPath:temporaryRoot() error:nil];
    *scratch = profile; *backup = backupDirectory; *state = [profile stringByAppendingPathComponent:@"state"]; return YES;
}
int dm_webdav_run(NSString *save, NSString *backup, NSString *state, int allowDownload) {
    NSString *scratch = [temporaryRoot() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![NSFileManager.defaultManager createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:nil]) return -1;
    DMWebDAVStore *s = store(activeConfig, activePassword, allowDownload ? 5 : 25); dm_cloud_storage ops = s.storage; int result = -1;
    @try { result = dm_cloud_sync_backend(save.fileSystemRepresentation, scratch.fileSystemRepresentation, backup.fileSystemRepresentation, state.fileSystemRepresentation, allowDownload, (uint64_t)(NSDate.date.timeIntervalSince1970 * 1000), NULL, &ops); }
    @finally { [s close]; [NSFileManager.defaultManager removeItemAtPath:scratch error:nil]; }
    if (result < 0) fprintf(stderr, "WebDAV sync failed code=%ld\n", (long)s.error.code); return result;
}
static NSArray<NSDictionary *> *backups(void) {
    NSDictionary *c = normalized(configuration()); if (!c) return @[];
    NSString *dir = [[[base() stringByAppendingPathComponent:@"WebDAVPacks"] stringByAppendingPathComponent:identifier(c)] stringByAppendingPathComponent:@"backups"];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        NSRange dash = [name rangeOfString:@"-" options:NSBackwardsSearch]; if (dash.location == NSNotFound || !dash.location) continue;
        NSString *stamp = [name substringFromIndex:dash.location + 1], *path = [dir stringByAppendingPathComponent:name];
        if (!stamp.length || [stamp rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound || ![[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) continue;
        [items addObject:@{@"name":[name substringToIndex:dash.location], @"date":[NSDate dateWithTimeIntervalSince1970:stamp.doubleValue / 1000], @"path":path}];
    }
    [items sortUsingComparator:^NSComparisonResult(id a,id b) { return [b[@"date"] compare:a[@"date"]]; }]; return items;
}
static NSString *backupLabel(NSDictionary *item) { return [NSString stringWithFormat:@"%@ · %@", item[@"name"], [NSDateFormatter localizedStringFromDate:item[@"date"] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle]]; }
static NSURL *exportBackup(NSDictionary *item) {
    NSString *path = item[@"path"], *target = [[temporaryRoot() stringByAppendingPathComponent:@"exports"] stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".zip"]];
    NSFileManager *fm = NSFileManager.defaultManager; NSDirectoryEnumerator *it = [fm enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:nil options:0 errorHandler:nil];
    if (!it) return nil;
    for (NSURL *url in it) { NSString *type = [fm attributesOfItemAtPath:url.path error:nil][NSFileType]; if (!([type isEqual:NSFileTypeDirectory] || [type isEqual:NSFileTypeRegular])) return nil; }
    if (![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]) return nil;
    __block BOOL ok = NO; NSError *error = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:[NSURL fileURLWithPath:path] options:NSFileCoordinatorReadingForUploading error:&error byAccessor:^(NSURL *url) { ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:target] error:nil]; }];
    return ok && !error ? [NSURL fileURLWithPath:target] : nil;
}
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
static UIViewController *presenter(void) { for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { UIViewController *v = w.rootViewController; while (v.presentedViewController) v = v.presentedViewController; return v; } return nil; }
static void notice(NSString *text) { UIAlertController *a = [UIAlertController alertControllerWithTitle:ui("dmCustomWebdav") message:text preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:ui("dmAppOK") style:UIAlertActionStyleDefault handler:nil]]; [presenter() presentViewController:a animated:YES completion:nil]; }
@interface DMWebDAVSettings : UITableViewController
@property NSArray<UITextField *> *fields;
@property BOOL busy;
@end
@implementation DMWebDAVSettings
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 54; self.title = ui("dmCustomWebdav"); self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:ui("dmAppOK") style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    NSDictionary *c = configuration(); NSMutableArray *fields = [NSMutableArray array]; NSArray *hints = @[ui("dmDavURL"),ui("dmDavUsername"),ui("dmDavPassword")]; NSArray *values = @[c[@"url"] ?: @"",c[@"username"] ?: @"",@""];
    for (int i = 0; i < 3; i++) { UITextField *f = [UITextField new]; f.placeholder = hints[i]; f.text = values[i]; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo; f.secureTextEntry = i == 2; f.keyboardType = i ? UIKeyboardTypeDefault : UIKeyboardTypeURL; [fields addObject:f]; } self.fields = fields;
}
- (void)close { if (!self.busy) [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSDictionary *)config { return @{@"url":self.fields[0].text ?: @"", @"username":self.fields[1].text ?: @""}; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table { (void)table; return 2; }
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section { (void)table; (void)section; return 3; }
- (NSString *)tableView:(UITableView *)table titleForFooterInSection:(NSInteger)section { (void)table; return section == 0 ? ui("dmDavHelp") : ui("dmDavBackupHelp"); }
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)p {
    (void)table; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (p.section == 1) { cell.textLabel.text = @[ui("dmDavSave"),ui("dmDavTest"),ui("dmDavBackups")][p.row]; cell.textLabel.textColor = self.view.tintColor; return cell; }
    UITextField *f = self.fields[p.row]; f.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:f];
    [NSLayoutConstraint activateConstraints:@[[f.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],[f.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],[f.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],[f.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12],[f.heightAnchor constraintGreaterThanOrEqualToConstant:30]]]; return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)p {
    [table deselectRowAtIndexPath:p animated:YES]; if (p.section != 1 || self.busy) return; [self.view endEditing:YES];
    NSDictionary *input = self.config; NSString *secret = self.fields[2].text ?: @""; self.busy = YES; self.view.userInteractionEnabled = NO;
    dispatch_async(queue(), ^{ @autoreleasepool {
        NSString *message; NSArray *items = nil;
        if (p.row == 0) message = ui(saveConfig(input,secret) ? "dmDavSaved" : "dmDavConfigError");
        else if (p.row == 1) { NSDictionary *c = normalized(input); DMWebDAVStore *s = c ? store(c,secret,30) : nil; message = s && [s probe] ? ui("dmDavConnected") : s ? dm_webdav_error_message(s.error) : ui("dmDavConfigError"); [s close]; }
        else { items = backups(); message = items.count ? nil : ui("dmDavNoBackups"); }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO; self.view.userInteractionEnabled = YES;
            if (p.row == 0 && dm_webdav_config_ready()) self.fields[2].text = @"";
            if (message) { notice(message); return; }
            UIAlertController *picker = [UIAlertController alertControllerWithTitle:ui("dmDavBackups") message:ui("dmDavBackupHelp") preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *item in items) [picker addAction:[UIAlertAction actionWithTitle:backupLabel(item) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; dispatch_async(queue(), ^{ NSURL *url = exportBackup(item); dispatch_async(dispatch_get_main_queue(), ^{ if (!url) { notice(ui("dmDavLocalError")); return; } UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil]; share.popoverPresentationController.sourceView = self.view; share.popoverPresentationController.sourceRect = self.view.bounds; [self presentViewController:share animated:YES completion:nil]; }); }); }]];
            [picker addAction:[UIAlertAction actionWithTitle:ui("dmTcCancel") style:UIAlertActionStyleCancel handler:nil]]; picker.popoverPresentationController.sourceView = self.view; picker.popoverPresentationController.sourceRect = self.view.bounds; [self presentViewController:picker animated:YES completion:nil];
        });
    } });
}
@end
void dm_webdav_settings_open(void) { dispatch_async(dispatch_get_main_queue(), ^{ UIViewController *v = presenter(); if (!v || [v isKindOfClass:DMWebDAVSettings.class]) return; UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[[DMWebDAVSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]]; n.modalPresentationStyle = UIModalPresentationFormSheet; [v presentViewController:n animated:YES completion:nil]; }); }
#else
#import <Cocoa/Cocoa.h>
static void notice(NSString *s) { NSAlert *a = [NSAlert new]; a.messageText = ui("dmCustomWebdav"); a.informativeText = s; [a addButtonWithTitle:ui("dmAppOK")]; [a runModal]; }
void dm_webdav_settings_open(void) { dispatch_async(dispatch_get_main_queue(), ^{
    NSDictionary *c = configuration(); NSAlert *a = [NSAlert new]; a.messageText = ui("dmCustomWebdav"); a.informativeText = ui("dmDavHelp"); NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,480,110)]; NSMutableArray *fields = [NSMutableArray array];
    for (int i = 0; i < 3; i++) { NSTextField *f = i == 2 ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0,80-i*36,480,28)] : [[NSTextField alloc] initWithFrame:NSMakeRect(0,80-i*36,480,28)]; f.placeholderString = @[ui("dmDavURL"),ui("dmDavUsername"),ui("dmDavPassword")][i]; f.stringValue = @[c[@"url"] ?: @"",c[@"username"] ?: @"",@""][i]; [view addSubview:f]; [fields addObject:f]; } a.accessoryView = view;
    for (NSString *button in @[ui("dmDavSave"),ui("dmDavTest"),ui("dmDavBackups"),ui("dmTcCancel")]) [a addButtonWithTitle:button]; NSInteger result = [a runModal] - NSAlertFirstButtonReturn;
    NSDictionary *input = @{@"url":((NSTextField *)fields[0]).stringValue, @"username":((NSTextField *)fields[1]).stringValue}; NSString *secret = ((NSTextField *)fields[2]).stringValue;
    if (result == 3) return;
    dispatch_async(queue(), ^{ @autoreleasepool {
        NSString *message = nil; NSArray *items = nil;
        if (result == 0) message = ui(saveConfig(input,secret) ? "dmDavSaved" : "dmDavConfigError");
        else if (result == 1) { NSDictionary *normalizedInput = normalized(input); DMWebDAVStore *s = normalizedInput ? store(normalizedInput,secret,30) : nil; message = s && [s probe] ? ui("dmDavConnected") : s ? dm_webdav_error_message(s.error) : ui("dmDavConfigError"); [s close]; }
        else { items = backups(); if (!items.count) message = ui("dmDavNoBackups"); }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (message) { notice(message); return; }
            NSAlert *picker = [NSAlert new]; picker.messageText = ui("dmDavBackups"); picker.informativeText = ui("dmDavBackupHelp"); NSPopUpButton *list = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,480,28)]; for (NSDictionary *item in items) [list addItemWithTitle:backupLabel(item)]; picker.accessoryView = list; [picker addButtonWithTitle:ui("dmDavExport")]; [picker addButtonWithTitle:ui("dmTcCancel")];
            if ([picker runModal] != NSAlertFirstButtonReturn) return; NSDictionary *item = items[list.indexOfSelectedItem]; dispatch_async(queue(), ^{ NSURL *url = exportBackup(item); dispatch_async(dispatch_get_main_queue(), ^{ if (!url) { notice(ui("dmDavLocalError")); return; } NSSavePanel *panel = [NSSavePanel savePanel]; panel.nameFieldStringValue = [NSString stringWithFormat:@"%@.zip",item[@"name"]]; if ([panel runModal] == NSModalResponseOK && ![NSFileManager.defaultManager copyItemAtURL:url toURL:panel.URL error:nil]) notice(ui("dmDavLocalError")); }); });
        });
    } });
}); }
#endif
#endif
