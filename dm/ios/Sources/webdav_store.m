// HTTPS 存档包传输：串行会话、暂存发布、远端长度与可用的服务器摘要校验。
// HTTPS pack transport: serial sessions, staged publication, remote length and available server digest checks.
#import "webdav_store.h"
#if DM_WEBDAV
#import <CommonCrypto/CommonDigest.h>
#include "../../host/dm_i18n.h"
static const NSUInteger packLimit = 64 * 1024 * 1024;
static NSError *issue(NSInteger code) { return [NSError errorWithDomain:@"DMWebDAV" code:code userInfo:nil]; }
NSString *dm_webdav_error_message(NSError *e) {
    return @(dm_ui(e.code == 2 ? "dmDavAuthError" : e.code == 3 ? "dmDavIntegrityError" : e.code == 4 ? "dmDavLocalError" : e.code == 5 ? "dmDavConfigError" : "dmDavNetworkError"));
}
static NSString *escaped(NSString *s) { return [s stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"]]; }
static BOOL unitName(NSString *s) {
    if (!s.length || [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding] >= 64 || [s hasPrefix:@"."] || ([s hasPrefix:@"_"] && ![s isEqual:@"_stash"])) return NO;
    return [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\\r\n\t"]].location == NSNotFound && [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
@interface DMDAVResponse : NSObject <NSURLSessionDataDelegate>
@property NSMutableData *bytes;
@property NSHTTPURLResponse *response;
@property NSError *error;
@property dispatch_semaphore_t finished;
@property NSUInteger limit;
@end
@implementation DMDAVResponse
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))done { (void)s; (void)t; (void)r; (void)q; self.error = issue(5); done(nil); }
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    (void)s; self.response = (id)r;
    BOOL tooBig = ![t.originalRequest.HTTPMethod isEqual:@"HEAD"] && r.expectedContentLength > (int64_t)self.limit;
    if (tooBig) self.error = issue(3); done(tooBig ? NSURLSessionResponseCancel : NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d { (void)s; if (d.length > self.limit - MIN(self.limit, self.bytes.length)) { self.error = issue(3); [t cancel]; } else [self.bytes appendData:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e { (void)s; (void)t; if (!self.error) self.error = e; dispatch_semaphore_signal(self.finished); }
@end

// 只接受根目录的单层资源；失败的属性不视为资源不存在。
// Accept only direct children of the root; failed properties do not mean absent resources.
@interface DMDAVXML : NSObject <NSXMLParserDelegate>
@property NSMutableArray *entries;
@property NSMutableDictionary *entry;
@property NSMutableDictionary *properties;
@property NSMutableString *text;
@property NSString *field;
@property NSString *propertyStatus;
@property BOOL inProperties;
@property BOOL invalid;
@end
@implementation DMDAVXML
- (instancetype)init { if ((self = [super init])) _entries = [NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    (void)q; (void)a; if (![ns isEqual:@"DAV:"]) return;
    if ([name isEqual:@"response"]) { if (self.entries.count >= 512) { self.invalid = YES; [parser abortParsing]; return; } self.entry = [NSMutableDictionary dictionary]; }
    if (!self.entry) return;
    if ([name isEqual:@"propstat"]) { self.inProperties = YES; self.properties = [NSMutableDictionary dictionary]; self.propertyStatus = nil; }
    if ([name isEqual:@"collection"]) self.properties[@"directory"] = @YES;
    if ([@[@"href", @"status", @"getcontentlength"] containsObject:name]) { self.field = name; self.text = [NSMutableString string]; }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)s { if (self.text.length + s.length > 8192) { self.invalid = YES; [parser abortParsing]; } else [self.text appendString:s]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    (void)parser; (void)q; if (![ns isEqual:@"DAV:"]) return;
    if ([name isEqual:self.field]) {
        NSString *value = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([name isEqual:@"status"] && self.inProperties) self.propertyStatus = value;
        else (self.inProperties ? self.properties : self.entry)[name] = value;
        self.text = nil; self.field = nil;
    }
    if ([name isEqual:@"propstat"]) { if ([self.propertyStatus containsString:@" 200 "]) [self.entry addEntriesFromDictionary:self.properties]; self.inProperties = NO; }
    if ([name isEqual:@"response"]) { [self.entries addObject:self.entry]; self.entry = nil; }
}
- (NSData *)parser:(NSXMLParser *)p resolveExternalEntityName:(NSString *)n systemID:(NSString *)s { (void)p; (void)n; (void)s; self.invalid = YES; return nil; }
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSData *checksum(NSData *data, NSString *algorithm) {
    unsigned char bytes[CC_SHA512_DIGEST_LENGTH]; unsigned count = 0;
    if ([algorithm isEqual:@"sha-512"]) { CC_SHA512(data.bytes, (CC_LONG)data.length, bytes); count = CC_SHA512_DIGEST_LENGTH; }
    else if ([algorithm isEqual:@"sha-256"]) { CC_SHA256(data.bytes, (CC_LONG)data.length, bytes); count = CC_SHA256_DIGEST_LENGTH; }
    else if ([algorithm isEqual:@"sha-1"]) { CC_SHA1(data.bytes, (CC_LONG)data.length, bytes); count = CC_SHA1_DIGEST_LENGTH; }
    else if ([algorithm isEqual:@"md5"]) { CC_MD5(data.bytes, (CC_LONG)data.length, bytes); count = CC_MD5_DIGEST_LENGTH; }
    return count ? [NSData dataWithBytes:bytes length:count] : nil;
}
#pragma clang diagnostic pop
static NSString *hexData(NSData *data) { NSMutableString *s = [NSMutableString string]; for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02x", ((const unsigned char *)data.bytes)[i]]; return s; }
@interface DMWebDAVStore ()
@property(readwrite) NSError *error;
@property NSURLSession *session;
@property DMDAVResponse *receiver;
@property NSMutableDictionary *listing;
@property NSUInteger roundBytes;
@end
@implementation DMWebDAVStore
- (BOOL)fail:(NSInteger)code operation:(const char *)operation status:(NSInteger)status {
    self.error = issue(code); fprintf(stderr, "WebDAV operation=%s error=%ld status=%ld\n", operation, (long)code, (long)status); return NO;
}
- (NSURL *)URL:(NSString *)path { return [NSURL URLWithString:[[[self.root stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] stringByAppendingString:@"/"] stringByAppendingString:path]]; }
- (void)close { [self.session invalidateAndCancel]; self.session = nil; self.receiver = nil; }
- (void)dealloc { [self.session invalidateAndCancel]; }
- (NSData *)request:(NSString *)method path:(NSString *)path data:(NSData *)data headers:(NSDictionary *)headers response:(NSHTTPURLResponse **)response {
    NSURLComponents *root = [NSURLComponents componentsWithString:self.root];
    BOOL loopback = self.testLoopback && [root.scheme isEqual:@"http"] && [@[@"127.0.0.1", @"localhost", @"::1"] containsObject:root.host];
    if ((!loopback && ![root.scheme isEqual:@"https"]) || !root.host.length || root.user || root.password || root.query || root.fragment || !self.username.length || !self.password.length || [self.username containsString:@":"]) { [self fail:5 operation:"config" status:0]; return nil; }
    NSTimeInterval remaining = self.deadline ? MIN(15, self.deadline - NSProcessInfo.processInfo.systemUptime) : 15;
    if (remaining <= 0) { [self fail:1 operation:"deadline" status:0]; return nil; }
    NSMutableURLRequest *q = [NSMutableURLRequest requestWithURL:[self URL:path]]; q.HTTPMethod = method; q.HTTPBody = data; q.timeoutInterval = remaining; q.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSString *authorization = [[[NSString stringWithFormat:@"%@:%@", self.username, self.password ?: @""] dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [q setValue:[@"Basic " stringByAppendingString:authorization] forHTTPHeaderField:@"Authorization"];
    [q setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"]; [q setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [q setValue:@"sha-512=10, sha-256=10, sha-1=1, md5=1" forHTTPHeaderField:@"Want-Repr-Digest"];
    for (NSString *key in headers) [q setValue:headers[key] forHTTPHeaderField:key];
    if (!self.session) { NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration; c.URLCache = nil; c.URLCredentialStorage = nil; c.HTTPCookieStorage = nil; c.timeoutIntervalForResource = 15; self.receiver = [DMDAVResponse new]; self.session = [NSURLSession sessionWithConfiguration:c delegate:self.receiver delegateQueue:nil]; }
    DMDAVResponse *r = self.receiver; r.bytes = [NSMutableData data]; r.error = nil; r.response = nil; r.limit = [method isEqual:@"GET"] ? packLimit : 1024 * 1024; r.finished = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:q]; [task resume];
    if (dispatch_semaphore_wait(r.finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)))) { [self close]; [self fail:1 operation:"timeout" status:NSURLErrorTimedOut]; return nil; }
    NSInteger status = r.response.statusCode;
    if (r.error) { NSInteger code = [r.error.domain isEqual:@"DMWebDAV"] ? r.error.code : ((status == 401 || status == 403 || r.error.code == NSURLErrorUserAuthenticationRequired) ? 2 : 1); [self close]; [self fail:code operation:method.UTF8String status:status ?: r.error.code]; return nil; }
    if (status == 401 || status == 403 || (status >= 300 && status < 400)) { [self fail:status < 400 ? 5 : 2 operation:method.UTF8String status:status]; return nil; }
    if (response) *response = r.response; return r.bytes;
}
- (NSArray *)properties:(NSString *)path depth:(NSString *)depth {
    NSData *body = [@"<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *r; NSData *data = [self request:@"PROPFIND" path:path data:body headers:@{@"Depth":depth, @"Content-Type":@"application/xml; charset=utf-8"} response:&r];
    if (!data) return nil; if (r.statusCode != 207) { [self fail:1 operation:"listing" status:r.statusCode]; return nil; }
    DMDAVXML *xml = [DMDAVXML new]; NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data]; parser.shouldProcessNamespaces = YES; parser.shouldResolveExternalEntities = NO; parser.delegate = xml;
    if (![parser parse] || xml.invalid || !xml.entries.count) { [self fail:3 operation:"xml" status:0]; return nil; } return xml.entries;
}
- (BOOL)digests:(NSHTTPURLResponse *)response data:(NSData *)data content:(NSInteger)content {
    BOOL checked = NO;
    for (NSString *header in content == 2 ? @[] : content == 1 ? @[@"Repr-Digest", @"Content-Digest"] : @[@"Repr-Digest"]) {
        NSString *field = [response valueForHTTPHeaderField:header];
        for (NSString *item in [field componentsSeparatedByString:@","]) {
            NSRange equal = [item rangeOfString:@"="]; if (equal.location == NSNotFound) { if (item.length) return [self fail:3 operation:"digest-format" status:0]; continue; }
            NSString *algorithm = [[item substringToIndex:equal.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
            NSData *actual = checksum(data, algorithm); if (!actual) continue;
            NSString *value = [[[[item substringFromIndex:equal.location + 1] componentsSeparatedByString:@";"] firstObject] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (value.length < 2 || ![value hasPrefix:@":"] || ![value hasSuffix:@":"]) return [self fail:3 operation:"digest-format" status:0];
            NSData *expected = [[NSData alloc] initWithBase64EncodedString:[value substringWithRange:NSMakeRange(1, value.length - 2)] options:0];
            if (![actual isEqual:expected]) return [self fail:3 operation:"digest" status:0]; checked = YES;
        }
    }
    for (NSArray *pair in @[@[@"X-Hash-SHA256", @"sha-256"], @[@"X-Hash-SHA1", @"sha-1"], @[@"X-Hash-MD5", @"md5"]]) {
        NSString *expected = [response valueForHTTPHeaderField:pair[0]]; if (!expected) continue;
        if (![hexData(checksum(data, pair[1])) isEqual:expected.lowercaseString]) return [self fail:3 operation:"server-hash" status:0]; checked = YES;
    }
    fprintf(stderr, "WebDAV integrity=%s bytes=%lu\n", checked ? "server-hash" : "size-only", (unsigned long)data.length); return YES;
}
- (NSNumber *)length:(NSString *)s {
    if (!s.length || [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return nil;
    unsigned long long n = strtoull(s.UTF8String, NULL, 10); return n <= packLimit ? @(n) : nil;
}
- (BOOL)verify:(NSString *)path data:(NSData *)data {
    NSHTTPURLResponse *r; NSData *head = [self request:@"HEAD" path:path data:nil headers:nil response:&r]; if (!head) return NO;
    NSNumber *size = r.statusCode == 200 ? [self length:[r valueForHTTPHeaderField:@"Content-Length"]] : nil;
    if (!size && (r.statusCode == 200 || r.statusCode == 405 || r.statusCode == 501)) {
        NSArray *entries = [self properties:path depth:@"0"]; if (!entries || entries.count != 1) return [self fail:3 operation:"stat" status:0]; size = [self length:entries[0][@"getcontentlength"]];
    }
    if (!size || size.unsignedLongLongValue != data.length) return [self fail:3 operation:"size" status:r.statusCode];
    return [self digests:r data:data content:NO];
}
- (BOOL)list:(int (*)(void *, const char *))emit context:(void *)context {
    self.error = nil; self.roundBytes = 0; self.listing = [NSMutableDictionary dictionary];
    NSArray *entries = [self properties:@"" depth:@"1"]; if (!entries) return NO;
    NSURLComponents *base = [NSURLComponents componentsWithURL:[self URL:@""] resolvingAgainstBaseURL:YES]; BOOL rootSeen = NO; NSMutableArray *orphans = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        if (entry[@"status"] && ![entry[@"status"] containsString:@" 200 "]) return [self fail:3 operation:"resource-status" status:0];
        NSURL *url = [NSURL URLWithString:entry[@"href"] relativeToURL:[self URL:@""]]; NSURLComponents *u = url ? [NSURLComponents componentsWithURL:url.absoluteURL resolvingAgainstBaseURL:YES] : nil;
        if (!u || ![u.scheme isEqual:base.scheme] || ![u.host isEqual:base.host] || ![(u.port ?: @0) isEqual:(base.port ?: @0)] || u.query || u.fragment) return [self fail:3 operation:"href-origin" status:0];
        NSString *path = u.percentEncodedPath, *prefix = base.percentEncodedPath;
        if ([path isEqual:prefix] || [[path stringByAppendingString:@"/"] isEqual:prefix]) { rootSeen = [entry[@"directory"] boolValue]; continue; }
        if (![path hasPrefix:prefix]) return [self fail:3 operation:"href-root" status:0];
        NSString *name = [[path substringFromIndex:prefix.length] stringByRemovingPercentEncoding];
        if ([name hasSuffix:@"/"] && [entry[@"directory"] boolValue]) name = [name substringToIndex:name.length - 1];
        if (!name || [name containsString:@"/"] || [name containsString:@"\\"]) return [self fail:3 operation:"href-child" status:0];
        if (![entry[@"directory"] boolValue] && [name hasPrefix:@".d2r-upload-"]) {
            NSString *suffix = [name substringFromIndex:12]; if ([[NSUUID alloc] initWithUUIDString:suffix]) [orphans addObject:escaped(name)];
        }
        if ([entry[@"directory"] boolValue] || ![name hasSuffix:@".pack"]) continue;
        NSString *unit = name.stringByDeletingPathExtension;
        if (!unitName(unit) || self.listing[unit] || emit(context, unit.UTF8String)) return [self fail:3 operation:"unit" status:0];
        self.listing[unit] = entry;
    }
    if (!rootSeen) return [self fail:3 operation:"root-missing" status:0];
    for (NSString *path in orphans) { NSHTTPURLResponse *r; if (![self request:@"DELETE" path:path data:nil headers:nil response:&r]) return NO; if (![@[@200,@204,@404] containsObject:@(r.statusCode)]) return [self fail:1 operation:"staging-cleanup" status:r.statusCode]; }
    return YES;
}
- (int)read:(NSString *)unit local:(NSString *)local {
    if (!unitName(unit)) { [self fail:3 operation:"unit" status:0]; return -1; }
    NSDictionary *entry = self.listing[unit]; if (!entry) return 0;
    NSString *path = [escaped(unit) stringByAppendingString:@".pack"]; NSNumber *length = [self length:entry[@"getcontentlength"]];
    if (!length) { NSHTTPURLResponse *r; if (![self request:@"HEAD" path:path data:nil headers:nil response:&r] || r.statusCode != 200 || !(length = [self length:[r valueForHTTPHeaderField:@"Content-Length"]])) { [self fail:3 operation:"download-size" status:0]; return -1; } }
    NSHTTPURLResponse *r; NSData *bytes = [self request:@"GET" path:path data:nil headers:nil response:&r]; if (!bytes) return -1;
    NSNumber *headerSize = [self length:[r valueForHTTPHeaderField:@"Content-Length"]];
    if (r.statusCode != 200 || bytes.length != length.unsignedLongLongValue || (headerSize && headerSize.unsignedLongLongValue != bytes.length) || self.roundBytes + bytes.length > 256 * 1024 * 1024) { [self fail:3 operation:"download" status:r.statusCode]; return -1; }
    if (![self digests:r data:bytes content:YES]) return -1; self.roundBytes += bytes.length;
    if (![bytes writeToFile:local options:NSDataWritingAtomic error:nil]) { [self fail:4 operation:"local-write" status:0]; return -1; } return 1;
}
- (BOOL)publish:(NSString *)unit local:(NSString *)local {
    NSData *bytes = [NSData dataWithContentsOfFile:local options:NSDataReadingMappedIfSafe error:nil];
    if (!unitName(unit) || !bytes || bytes.length > packLimit) return [self fail:4 operation:"local-pack" status:0];
    NSString *temp = [@".d2r-upload-" stringByAppendingString:NSUUID.UUID.UUIDString], *path = [escaped(unit) stringByAppendingString:@".pack"];
    NSHTTPURLResponse *r; NSData *result = [self request:@"PUT" path:temp data:bytes headers:@{@"Content-Type":@"application/octet-stream", @"X-Hash":@"sha256"} response:&r];
    if (!result) return NO;
    if (![@[@200,@201,@204] containsObject:@(r.statusCode)]) return [self fail:1 operation:"put" status:r.statusCode];
    if (![self digests:r data:bytes content:2] || ![self verify:temp data:bytes]) return NO;
    result = [self request:@"MOVE" path:temp data:nil headers:@{@"Destination":[self URL:path].absoluteString, @"Overwrite":@"T"} response:&r];
    if (!result) return NO; if (r.statusCode != 201 && r.statusCode != 204) return [self fail:1 operation:"move" status:r.statusCode];
    return [self verify:path data:bytes];
}
static int davList(void *ctx, int (*emit)(void *, const char *), void *arg) { return [(__bridge DMWebDAVStore *)ctx list:emit context:arg] ? 0 : -1; }
static int davRead(void *ctx, const char *unit, const char *local) { return [(__bridge DMWebDAVStore *)ctx read:@(unit) local:@(local)]; }
static int davPublish(void *ctx, const char *unit, const char *local) { return [(__bridge DMWebDAVStore *)ctx publish:@(unit) local:@(local)] ? 0 : -1; }
- (dm_cloud_storage)storage { return (dm_cloud_storage){(__bridge void *)self, davList, davRead, davPublish}; }
- (BOOL)probe {
    self.error = nil; NSString *directory = [NSString stringWithFormat:@".d2r-probe-%@/", NSUUID.UUID.UUIDString]; NSHTTPURLResponse *r;
    NSData *d = [self request:@"MKCOL" path:directory data:nil headers:nil response:&r];
    if (!d || r.statusCode != 201) return d ? [self fail:1 operation:"probe-mkdir" status:r.statusCode] : NO;
    BOOL ok = NO;
    @try {
        NSData *bytes = [@"D2R WebDAV probe\n" dataUsingEncoding:NSUTF8StringEncoding]; NSString *a = [directory stringByAppendingString:@"test"], *b = [directory stringByAppendingString:@"moved"];
        d = [self request:@"PUT" path:a data:bytes headers:@{@"X-Hash":@"sha256"} response:&r];
        if (!d) return NO;
        if (![@[@200,@201,@204] containsObject:@(r.statusCode)]) return [self fail:1 operation:"probe-put" status:r.statusCode];
        if (![self digests:r data:bytes content:2] || ![self verify:a data:bytes]) return NO;
        d = [self request:@"MOVE" path:a data:nil headers:@{@"Destination":[self URL:b].absoluteString, @"Overwrite":@"T"} response:&r];
        if (!d) return NO;
        if (r.statusCode != 201 && r.statusCode != 204) return [self fail:1 operation:"probe-move" status:r.statusCode];
        if (![self verify:b data:bytes]) return NO;
        d = [self request:@"GET" path:b data:nil headers:nil response:&r]; ok = d && r.statusCode == 200 && [d isEqual:bytes] && [self digests:r data:d content:YES];
        if (!ok && !self.error) [self fail:3 operation:"probe-read" status:0];
    } @finally {
        // 失败后不追加认证请求；成功时删除整个测试目录。
        // Do not add authenticated requests after failure; clean the probe directory on success.
        if (ok) { d = [self request:@"DELETE" path:directory data:nil headers:nil response:&r]; ok = d && (r.statusCode == 200 || r.statusCode == 204); if (!ok && !self.error) [self fail:1 operation:"probe-cleanup" status:r.statusCode]; }
    }
    return ok;
}
@end
#endif
