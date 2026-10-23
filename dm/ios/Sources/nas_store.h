// 单人 WebDAV 原始存档传输，基于 Foundation 与 WebDAV；调用方串行访问，不依赖游戏地址。
// Single-user WebDAV raw save transport. Callers serialize local access.
#import "nas_error.h"

FOUNDATION_EXPORT NSString *DMNASHash(NSData *data);
FOUNDATION_EXPORT BOOL DMNASValidPath(NSString *path);

typedef NS_ENUM(NSInteger, DMNASActivity) {
    DMNASActivityChecking, DMNASActivityDownloading, DMNASActivityUploading, DMNASActivityVerifying
};

// 纯本机分组；主文件删除后仍记住附属文件归属。
// Pure local grouping, including ownership remembered after a primary file is deleted.
FOUNDATION_EXPORT NSDictionary *DMNASGroups(NSDictionary *snapshot, NSDictionary *known, NSError **error);

@interface DMNASStore : NSObject
@property(nonatomic, copy) NSString *root;
@property(nonatomic, copy) NSString *username;
@property(nonatomic, copy) NSString *password;
@property(nonatomic, copy) NSString *cache;
@property(nonatomic, copy) NSString *device;
@property(nonatomic) NSTimeInterval deadline;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) BOOL needsRestart;
@property(nonatomic, copy) NSSet<NSString *> *restartGroups;
// 串行队列回调：类型为 character、stash 或 auxiliary。
// Serial-queue callbacks: kind is character, stash or auxiliary.
@property(nonatomic, copy) void (^groupFinished)(NSString *group, NSString *kind);
// 手动同步仅对当前存档绕过修改时间缓存。
// Manual sync bypasses modification-time reuse for the current save only.
@property(nonatomic) BOOL refreshCurrentFiles;
// 当前传输类型：character、stash、auxiliary，通用操作为 nil。
// Kind of the current transfer: character, stash, auxiliary, or nil for generic work.
@property(nonatomic, copy) NSString *activityKind;
// 在调用方串行队列回调，不暴露凭据或路径。
// Called on the caller's serial queue; no credentials or paths are exposed.
@property(nonatomic, copy) void (^activity)(DMNASActivity phase);
// 仅回环测试服务允许 HTTP，应用设置始终要求 HTTPS。
// HTTP is permitted only for the loopback test server, never by the app settings.
@property(nonatomic) BOOL testLoopback;
- (BOOL)probe:(NSError **)error;
- (NSDictionary *)snapshot:(NSString *)directory savedAt:(double)stamp error:(NSError **)error;
- (BOOL)sync:(NSString *)snapshot save:(NSString *)save allowDownload:(BOOL)allow error:(NSError **)error;
- (BOOL)sync:(NSString *)snapshot save:(NSString *)save groups:(NSSet<NSString *> *)groups allowDownload:(BOOL)allow error:(NSError **)error;
- (NSDictionary *)knownGroups;
- (NSArray<NSDictionary *> *)history:(NSError **)error;
- (BOOL)scheduleRestore:(NSString *)revision error:(NSError **)error;
@end
