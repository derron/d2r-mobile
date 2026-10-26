// 用临时假存档调用真实共用核心与 HTTP 后端，不访问玩家目录。
// Exercise the real shared core and HTTP backend with temporary fake saves only.
#import "../../ios/Sources/webdav_store.h"
#include <stdio.h>
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 4) return 2;
    NSString *base = @(argv[2]); NSFileManager *fm = NSFileManager.defaultManager;
    NSString *save = [base stringByAppendingPathComponent:@"save"], *scratch = [base stringByAppendingPathComponent:@"scratch"], *state = [base stringByAppendingPathComponent:@"state"], *backup = [base stringByAppendingPathComponent:@"backups"];
    [fm createDirectoryAtPath:save withIntermediateDirectories:YES attributes:nil error:nil]; [fm createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:nil];
    DMWebDAVStore *s = [DMWebDAVStore new]; s.root = @(argv[1]); s.username = @"test"; s.password = @"test"; s.testLoopback = YES; s.deadline = NSProcessInfo.processInfo.systemUptime + 8;
    if (argc > 4) s.deadline = NSProcessInfo.processInfo.systemUptime + atof(argv[4]);
    int result;
    if (!strcmp(argv[3], "probe")) result = [s probe] ? 0 : -1;
    else { dm_cloud_storage ops = s.storage; result = dm_cloud_sync_backend(save.fileSystemRepresentation,scratch.fileSystemRepresentation,backup.fileSystemRepresentation,state.fileSystemRepresentation,atoi(argv[3]),9000000,NULL,&ops); }
    if (!strcmp(argv[3], "reuse-timeout")) {
        printf("first=%d\n",result); s.deadline = NSProcessInfo.processInfo.systemUptime + 8;
        dm_cloud_storage ops = s.storage;
        result = dm_cloud_sync_backend(save.fileSystemRepresentation,scratch.fileSystemRepresentation,backup.fileSystemRepresentation,state.fileSystemRepresentation,0,9000000,NULL,&ops);
    }
    printf("result=%d error=%ld\n",result,(long)s.error.code); [s close]; return 0;
} }
