// 保存同步与设置接口，基于现有云存档生命周期，不直接使用游戏地址。
// Save sync/settings API based on the existing cloud lifecycle, without direct game addresses.
#import "nas_error.h"
#include "../../host/dm_build_sync.h"
// 完成回调均在主队列执行，配置下次启动生效。
// All completion blocks are delivered on the main queue. Settings take effect next launch.
NSDictionary *dm_nas_config(void);
BOOL dm_nas_configure(NSDictionary *config, NSString *password, NSError **error);
NSString *dm_nas_status(void);
// 线程安全的入口文字，包含当前传输阶段。
// Thread-safe entry-button title, including the active transfer phase.
NSString *dm_nas_button_title(void);
dm_sync_phase dm_nas_build_phase(void);
void dm_nas_test(NSDictionary *config, NSString *password, void (^done)(NSString *message));
void dm_nas_now(void (^done)(NSString *message));
void dm_nas_history(void (^done)(NSArray<NSDictionary *> *versions, NSString *error));
void dm_nas_restore(NSString *revision, void (^done)(NSString *message));
void dm_sync_settings_show(void);
void dm_sync_ui_install(void *view);
