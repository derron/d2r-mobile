// WebDAV 只传输共用核心的存档包，不判断存档冲突或分组。
// WebDAV transports shared-core save packs; it does not decide conflicts or grouping.
#import <Foundation/Foundation.h>
#include "../../host/dm_cloudsync.h"
#if DM_WEBDAV
@interface DMWebDAVStore : NSObject
@property NSString *root;
@property NSString *username;
@property NSString *password;
@property NSString *scratch;
@property NSTimeInterval deadline;
@property(readonly) NSError *error;
@property BOOL testLoopback; // 仅测试驱动可用，正式配置始终要求 HTTPS。 | Test drivers only; production configuration requires HTTPS.
- (dm_cloud_storage)storage;
- (BOOL)probe;
- (void)close;
@end
NSString *dm_webdav_error_message(NSError *error);
#endif
