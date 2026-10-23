// WebDAV 的九类用户提示与固定诊断码；基于 NSError，不依赖游戏地址。
// Nine WebDAV user-error categories and fixed diagnostics, based on NSError without game addresses.
#pragma once
#import <Foundation/Foundation.h>
#include "../../host/dm_i18n.h"
#include <stdio.h>

typedef NS_ENUM(NSInteger, DMNASError) {
    DMNASConfigurationError = 1, DMNASAuthenticationError, DMNASNetworkError,
    DMNASServerError, DMNASLocalError, DMNASDataError, DMNASUpgradeError,
    DMNASBackupError, DMNASKeychainError
};
static inline NSString *DMNASErrorText(DMNASError code) {
    const char *key;
    switch (code) {
        case DMNASConfigurationError: key = "dmNasErrorConfiguration"; break;
        case DMNASAuthenticationError: key = "dmNasErrorAuthentication"; break;
        case DMNASNetworkError: key = "dmNasErrorNetwork"; break;
        case DMNASServerError: key = "dmNasErrorServer"; break;
        case DMNASDataError: key = "dmNasErrorData"; break;
        case DMNASUpgradeError: key = "dmNasErrorUpgrade"; break;
        case DMNASBackupError: key = "dmNasErrorBackup"; break;
        case DMNASKeychainError: key = "dmNasErrorKeychain"; break;
        default: key = "dmNasErrorLocal"; break;
    }
    return @(dm_ui(key));
}
static inline BOOL DMNASClassified(NSError *error) {
    return [error.domain isEqual:@"D2R.SaveSync"] && error.code >= DMNASConfigurationError && error.code <= DMNASKeychainError;
}
// reason 只能传源码中的固定标识，detail 只传数值错误码；不记录 URL、路径、正文或凭据。
// Pass only source-defined reason identifiers and numeric detail codes, never URLs, paths, bodies or credentials.
static inline BOOL DMNASIssue(NSError **error, DMNASError code, const char *reason, NSInteger detail) {
    fprintf(stderr, "NAS error category=%ld operation=%s detail=%ld\n", (long)code, reason, (long)detail);
    // 保留内层已分类错误，避免外围校验掩盖认证或网络失败。
    // Preserve an inner classified error so outer validation cannot mask authentication or network failure.
    if (error && !DMNASClassified(*error)) *error = [NSError errorWithDomain:@"D2R.SaveSync" code:code userInfo:@{NSLocalizedDescriptionKey:DMNASErrorText(code), NSDebugDescriptionErrorKey:@(reason)}];
    return NO;
}
static inline NSError *DMNASNormalize(NSError *error, const char *operation) {
    if (DMNASClassified(error)) return error;
    DMNASError code = [error.domain isEqual:NSURLErrorDomain] ? DMNASNetworkError : DMNASLocalError;
    NSError *safe = nil; DMNASIssue(&safe, code, operation, error.code); return safe;
}
static inline NSString *DMNASMessage(NSError *error) {
    return DMNASNormalize(error, "system-error").localizedDescription;
}
