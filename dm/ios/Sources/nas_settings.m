// 原生设置基于同步公开接口，不修改生成的 RomFS 界面资源，也不依赖游戏地址。
// Native settings use the public sync API without generated RomFS UI assets or game addresses.
#include "../../host/dm_i18n.h"
#import "nas_sync.h"
#import <TargetConditionals.h>
int dm_uiscreen_ingame(void);
static NSString *dateLabel(NSDictionary *v) { return [NSString stringWithFormat:@"%@ · %@ · %@", v[@"name"] ?: @(dm_ui("dmNasOtherSaves")), [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[v[@"savedAt"] doubleValue]] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle], [v[@"device"] substringToIndex:8]]; }
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
static UIViewController *top(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) if ([scene isKindOfClass:UIWindowScene.class]) {
        for (UIWindow *w in ((UIWindowScene *)scene).windows) if (w.isKeyWindow) { UIViewController *v = w.rootViewController; while (v.presentedViewController) v = v.presentedViewController; return v; }
    }
    return nil;
}
static void notice(NSString *text) { UIAlertController *a = [UIAlertController alertControllerWithTitle:@(dm_ui("dmNasTitle")) message:text preferredStyle:UIAlertControllerStyleAlert]; [a addAction:[UIAlertAction actionWithTitle:@(dm_ui("dmAppOK")) style:UIAlertActionStyleDefault handler:nil]]; [top() presentViewController:a animated:YES completion:nil]; }
@interface DMNASSettings : UITableViewController
@property UISegmentedControl *mode;
@property NSArray<UITextField *> *fields;
@property UILabel *statusLabel;
@end
@implementation DMNASSettings
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @(dm_ui("dmNasTitle"));
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@(dm_ui("dmNasSave")) style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@(dm_ui("dmTcCancel")) style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    NSDictionary *c = dm_nas_config(); self.mode = [[UISegmentedControl alloc] initWithItems:@[@(dm_ui("dmNasOff")), @(dm_ui("dmNasICloud")), @(dm_ui("dmNasWebDAV"))]]; self.mode.selectedSegmentIndex = [@[@"off", @"icloud", @"nas"] indexOfObject:c[@"mode"]];
    NSMutableArray *fields = [NSMutableArray array]; NSArray *values = @[c[@"url"] ?: @"", c[@"username"] ?: @"", @""];
    NSArray *hints = @[@(dm_ui("dmNasURLHint")), @(dm_ui("dmNasUsername")), @(dm_ui("dmNasPasswordShort"))];
    for (int i = 0; i < 3; i++) { UITextField *f = [UITextField new]; f.placeholder = hints[i]; f.text = values[i]; f.autocapitalizationType = UITextAutocapitalizationTypeNone; f.autocorrectionType = UITextAutocorrectionTypeNo; f.secureTextEntry = i == 2; f.clearButtonMode = UITextFieldViewModeWhileEditing; if (i == 0) f.keyboardType = UIKeyboardTypeURL; [fields addObject:f]; } self.fields = fields;
    self.statusLabel = [UILabel new]; self.statusLabel.numberOfLines = 0; self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; self.statusLabel.text = dm_nas_status();
}
- (NSDictionary *)config { NSInteger n = self.mode.selectedSegmentIndex; return @{@"mode":@[@"off", @"icloud", @"nas"][MAX(0, MIN(2, n))], @"url":self.fields[0].text ?: @"", @"username":self.fields[1].text ?: @""}; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)save { [self.view endEditing:YES]; NSError *e = nil; if (!dm_nas_configure(self.config, self.fields[2].text, &e)) { notice(DMNASMessage(e)); return; } self.fields[2].text = @""; notice(@(dm_ui("dmNasSavedRestart"))); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { (void)t; return 4; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { (void)t; return s == 0 ? 1 : s == 1 ? 3 : s == 2 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { (void)t; return @[@(dm_ui("dmNasMode")), @(dm_ui("dmNasConnection")), @(dm_ui("dmAndroidAction")), @(dm_ui("dmNasStatus"))][s]; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s { (void)t; return s == 1 ? @(dm_ui("dmNasConnectionHelp")) : s == 3 ? @(dm_ui("dmNasStatusHelp")) : nil; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)p {
    (void)t; UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; UIView *v;
    if (p.section == 0) v = self.mode; else if (p.section == 1) v = self.fields[p.row]; else if (p.section == 3) v = self.statusLabel;
    else { c.textLabel.text = @[@(dm_ui("dmNasTest")), @(dm_ui("dmNasNow")), @(dm_ui("dmNasRestore"))][p.row]; c.textLabel.textColor = self.view.tintColor; return c; }
    c.selectionStyle = UITableViewCellSelectionStyleNone; v.translatesAutoresizingMaskIntoConstraints = NO; [c.contentView addSubview:v];
    [NSLayoutConstraint activateConstraints:@[[v.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor], [v.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor], [v.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:12], [v.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-12], [v.heightAnchor constraintGreaterThanOrEqualToConstant:30]]]; return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)p {
    [t deselectRowAtIndexPath:p animated:YES]; if (p.section != 2) return;
    [self.view endEditing:YES]; self.statusLabel.text = @(dm_ui("dmSyncCheck"));
    __weak DMNASSettings *weak = self;
    void (^done)(NSString *) = ^(NSString *s) { weak.statusLabel.text = s; [weak.tableView beginUpdates]; [weak.tableView endUpdates]; notice(s); };
    if (p.row == 0) dm_nas_test(self.config, self.fields[2].text, done);
    else if (p.row == 1) dm_nas_now(done);
    else dm_nas_history(^(NSArray<NSDictionary *> *versions, NSString *error) {
        if (error || !versions.count) { done(error ?: @(dm_ui("dmNasNoBackup"))); return; }
        weak.statusLabel.text = @(dm_ui("dmNasRestore"));
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@(dm_ui("dmNasRestore")) message:@(dm_ui("dmNasRestoreHelp")) preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary *v in versions) [a addAction:[UIAlertAction actionWithTitle:dateLabel(v) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { (void)action; dm_nas_restore(v[@"id"], done); }]];
        [a addAction:[UIAlertAction actionWithTitle:@(dm_ui("dmTcCancel")) style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = weak.view; a.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(weak.view.bounds), CGRectGetMidY(weak.view.bounds), 1, 1); [weak presentViewController:a animated:YES completion:nil];
    });
}
@end
void dm_sync_settings_show(void) { UIViewController *v = top(); if (v.presentedViewController || [v isKindOfClass:DMNASSettings.class]) return; UINavigationController *n = [[UINavigationController alloc] initWithRootViewController:[[DMNASSettings alloc] initWithStyle:UITableViewStyleInsetGrouped]]; n.modalPresentationStyle = UIModalPresentationFormSheet; [v presentViewController:n animated:YES completion:nil]; }
void dm_sync_ui_install(void *view) {
    (void)view;
    // 设置入口使用构建文字，此处仅保留重启通知。
    // The game's build caption is now the settings entry; keep only restart notices here.
    static dispatch_once_t once; dispatch_once(&once, ^{ [NSNotificationCenter.defaultCenter addObserverForName:@"DMSaveSyncNeedsRestart" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { notice(n.object); }]; });
}
#else
#import <Cocoa/Cocoa.h>
static void notice(NSString *s) { NSAlert *a = [NSAlert new]; a.messageText = @(dm_ui("dmNasTitle")); a.informativeText = s ?: @(dm_ui("dmNasErrorLocal")); [a addButtonWithTitle:@(dm_ui("dmAppOK"))]; [a runModal]; }
void dm_sync_ui_install(void *view) { (void)view; }
void dm_sync_settings_show(void) {
    NSDictionary *c = dm_nas_config(); NSAlert *a = [NSAlert new]; a.messageText = @(dm_ui("dmNasTitle")); a.informativeText = dm_nas_status();
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 470, 156)];
    NSPopUpButton *mode = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 124, 470, 28) pullsDown:NO]; [mode addItemsWithTitles:@[@(dm_ui("dmNasOff")), @(dm_ui("dmNasICloud")), @(dm_ui("dmNasWebDAV"))]]; [mode selectItemAtIndex:[@[@"off", @"icloud", @"nas"] indexOfObject:c[@"mode"]]]; [v addSubview:mode];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array]; NSArray *values = @[c[@"url"] ?: @"", c[@"username"] ?: @"", @""];
    for (int i = 0; i < 3; i++) { NSTextField *f = i == 2 ? [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 86 - i * 36, 470, 26)] : [[NSTextField alloc] initWithFrame:NSMakeRect(0, 86 - i * 36, 470, 26)]; f.stringValue = values[i]; f.placeholderString = @[@(dm_ui("dmNasURLHint")), @(dm_ui("dmNasUsername")), @(dm_ui("dmNasPasswordShort"))][i]; [v addSubview:f]; [fields addObject:f]; } a.accessoryView = v;
    for (NSString *s in @[@(dm_ui("dmNasSave")), @(dm_ui("dmNasTest")), @(dm_ui("dmNasNow")), @(dm_ui("dmNasRestore")), @(dm_ui("dmTcCancel"))]) [a addButtonWithTitle:s];
    NSInteger chosen = [a runModal] - NSAlertFirstButtonReturn;
    NSDictionary *input = @{@"mode":@[@"off", @"icloud", @"nas"][mode.indexOfSelectedItem], @"url":fields[0].stringValue, @"username":fields[1].stringValue};
    if (chosen == 0) { NSError *e = nil; notice(dm_nas_configure(input, fields[2].stringValue, &e) ? @(dm_ui("dmNasSavedRestart")) : DMNASMessage(e)); }
    else if (chosen == 1) dm_nas_test(input, fields[2].stringValue, ^(NSString *s) { notice(s); });
    else if (chosen == 2) dm_nas_now(^(NSString *s) { notice(s); });
    else if (chosen == 3) dm_nas_history(^(NSArray<NSDictionary *> *versions, NSString *error) {
        if (error || !versions.count) { notice(error ?: @(dm_ui("dmNasNoBackup"))); return; }
        NSAlert *picker = [NSAlert new]; picker.messageText = @(dm_ui("dmNasRestore")); picker.informativeText = @(dm_ui("dmNasRestoreHelp"));
        NSPopUpButton *list = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 470, 28) pullsDown:NO]; for (NSDictionary *item in versions) [list addItemWithTitle:dateLabel(item)]; picker.accessoryView = list; [picker addButtonWithTitle:@(dm_ui("dmNasRestore"))]; [picker addButtonWithTitle:@(dm_ui("dmTcCancel"))];
        if ([picker runModal] == NSAlertFirstButtonReturn) dm_nas_restore(versions[list.indexOfSelectedItem][@"id"], ^(NSString *s) { notice(s); });
    });
}
#endif
