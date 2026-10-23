// 独立传输驱动：不链接游戏，不访问真实存档或配置。
// Standalone transport driver: never links the game or touches real save/config paths.
#import "../../ios/Sources/nas_store.h"
// 仅测试内部串行传输，不扩大应用公开接口。
// Exercise the internal serial transport without expanding the app's public interface.
@interface DMNASStore (TransportTest)
- (NSData *)request:(NSString *)method path:(NSString *)path body:(NSData *)body headers:(NSDictionary *)headers response:(NSHTTPURLResponse **)response error:(NSError **)error;
@end
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 6) return 2;
    DMNASStore *s = [DMNASStore new]; s.root = @(argv[2]); s.cache = @(argv[3]); s.device = @(argv[4]); s.username = @"test"; s.password = @"secret"; s.testLoopback = YES; s.deadline = NSDate.date.timeIntervalSince1970 + 12;
    s.refreshCurrentFiles = NSProcessInfo.processInfo.environment[@"DM_NAS_TEST_REFRESH"] != nil;
    NSString *config = NSProcessInfo.processInfo.environment[@"DM_NAS_TEST_CONFIG"];
    if (config) {
        NSData *data = [NSData dataWithContentsOfFile:config];
        NSDictionary *c = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![c[@"username"] isKindOfClass:NSString.class] || ![c[@"password"] isKindOfClass:NSString.class]) return 2;
        s.username = c[@"username"]; s.password = c[@"password"]; s.testLoopback = NO;
        s.deadline = NSDate.date.timeIntervalSince1970 + 90;
    }
    NSMutableArray *activity = [NSMutableArray array];
    if (NSProcessInfo.processInfo.environment[@"DM_NAS_TEST_ACTIVITY"]) {
        __weak DMNASStore *active = s;
        s.activity = ^(DMNASActivity phase) {
            if (phase == DMNASActivityUploading || phase == DMNASActivityDownloading) {
                NSString *event = [NSString stringWithFormat:@"%@:%@", phase == DMNASActivityUploading ? @"upload" : @"download", active.activityKind ?: @"generic"];
                if (![activity.lastObject isEqual:event]) [activity addObject:event];
            }
        };
    }
    NSError *e = nil; NSString *op = @(argv[1]), *save = @(argv[5]); BOOL ok = NO;
    [NSFileManager.defaultManager createDirectoryAtPath:s.cache withIntermediateDirectories:YES attributes:nil error:nil];
    if ([op isEqual:@"transport"] && !config && argc > 6) {
        NSArray *steps = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[6])] options:0 error:&e];
        if (![steps isKindOfClass:NSArray.class]) goto result;
        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *step in steps) {
            [NSThread sleepForTimeInterval:[step[@"pause"] doubleValue]];
            s.deadline = NSDate.date.timeIntervalSince1970 + [step[@"timeout"] doubleValue];
            NSError *failure = nil; NSHTTPURLResponse *response = nil;
            NSData *data = [s request:@"GET" path:step[@"path"] body:nil headers:nil response:&response error:&failure];
            [results addObject:@{@"code":@(failure.code), @"status":@(response.statusCode), @"digest":data ? DMNASHash(data) : @""}];
        }
        puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:results options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
        ok = YES;
    } else if ([op isEqual:@"probe"]) ok = [s probe:&e];
    else if ([op isEqual:@"sync"]) {
        if (argc > 7 && atof(argv[7]) > 0) { NSDictionary *m = [s snapshot:save savedAt:atof(argv[7]) error:&e]; if (!m) goto result; [[NSJSONSerialization dataWithJSONObject:m options:0 error:nil] writeToFile:[s.cache stringByAppendingPathComponent:@"candidate.json"] atomically:YES]; }
        NSString *groups = NSProcessInfo.processInfo.environment[@"DM_NAS_TEST_GROUPS"];
        NSSet *selected = groups ? [NSSet setWithArray:[groups componentsSeparatedByString:@";"]] : nil;
        ok = [s sync:save save:save groups:selected allowDownload:argc < 7 || atoi(argv[6]) error:&e];
    } else if ([op isEqual:@"history"]) { NSArray *v = [s history:&e]; ok = v != nil; if (v) puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:v options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String); }
    else if ([op isEqual:@"restore"] && argc > 6) ok = [s scheduleRestore:@(argv[6]) error:&e];
    else if ([op isEqual:@"groups"]) {
        NSDictionary *m = [s snapshot:save savedAt:0 error:&e];
        NSDictionary *groups = m ? DMNASGroups(m, [s knownGroups], &e) : nil;
        ok = groups != nil;
        if (groups) puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:groups options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    }
    else if ([op isEqual:@"snapshot"]) ok = [s snapshot:save savedAt:0 error:&e] != nil;
result:
    if (e) e = DMNASNormalize(e, "store-operation");
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@{@"ok":@(ok), @"errorCode":@(e.code), @"errorReason":e.userInfo[NSDebugDescriptionErrorKey] ?: @"", @"restart":@(s.needsRestart), @"activity":activity, @"message":e.localizedDescription ?: s.message ?: @""} options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
    return ok ? 0 : 1;
} }
