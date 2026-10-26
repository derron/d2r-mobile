// 可选 WebDAV 配置桥；游戏线程只读已缓存的配置就绪标志。
// Optional WebDAV settings bridge; game threads only read cached readiness.
#ifndef DM_WEBDAV_SETTINGS_H
#define DM_WEBDAV_SETTINGS_H
#if DM_WEBDAV
int dm_webdav_config_ready(void);
int dm_webdav_test_mode(void);
void dm_webdav_load_configuration(void);
void dm_webdav_settings_open(void);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
BOOL dm_webdav_prepare(NSString *save, dispatch_queue_t queue, NSString **scratch, NSString **backup, NSString **state);
int dm_webdav_run(NSString *save, NSString *backup, NSString *state, int allowDownload);
#endif
#endif
#endif
