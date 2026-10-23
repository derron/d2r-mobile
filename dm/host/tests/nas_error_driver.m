// 用合成 NSError 验证提示分类、日志诊断与隐私边界，不访问文件系统或网络。
// Verify categories, diagnostic logging and privacy with synthetic NSError values, without filesystem or network access.
#import "../../ios/Sources/nas_error.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSMutableArray *messages = [NSMutableArray array];
    for (DMNASError code = DMNASConfigurationError; code <= DMNASKeychainError; code++) {
        NSError *e = nil; assert(!DMNASIssue(&e, code, "category-test", 401));
        assert(DMNASClassified(e) && e.code == code);
        assert([e.localizedDescription isEqual:DMNASErrorText(code)]);
        [messages addObject:e.localizedDescription];
    }
    NSString *private = @"https://private-user:private-password@private.invalid/private-save-path";
    NSError *system = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:@{NSLocalizedDescriptionKey:private, NSURLErrorFailingURLErrorKey:[NSURL URLWithString:private]}];
    NSError *network = DMNASNormalize(system, "network-test");
    assert(network.code == DMNASNetworkError && ![network.description containsString:private]);
    NSError *local = DMNASNormalize([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteNoPermissionError userInfo:@{NSFilePathErrorKey:private, NSLocalizedDescriptionKey:private}], "local-test");
    assert(local.code == DMNASLocalError && ![local.description containsString:private]);
    NSError *inner = nil; DMNASIssue(&inner, DMNASAuthenticationError, "GET", 403);
    DMNASIssue(&inner, DMNASServerError, "readback", 0);
    assert(inner.code == DMNASAuthenticationError && [inner.userInfo[NSDebugDescriptionErrorKey] isEqual:@"GET"]);
    puts([[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:messages options:0 error:nil] encoding:NSUTF8StringEncoding].UTF8String);
} }
