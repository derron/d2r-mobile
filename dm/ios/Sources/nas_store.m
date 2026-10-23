// 基于 Foundation/WebDAV 的原始存档传输；只消费提交快照，不依赖游戏地址。
// Foundation/WebDAV raw-save transport; consumes committed snapshots without game addresses.
#include "../../host/dm_i18n.h"
#import "nas_store.h"
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <sys/clonefile.h>

static const NSUInteger kFiles = 4096, kFileBytes = 64 * 1024 * 1024, kTotalBytes = 256 * 1024 * 1024;
static NSFileManager *FM(void) { return NSFileManager.defaultManager; }
static NSData *json(id obj) { return [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil]; }
static id readJSON(NSString *p) { NSData *d = [NSData dataWithContentsOfFile:p]; return d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil] : nil; }
static BOOL putJSON(id o, NSString *p, NSError **e) { NSData *d = json(o); return d && [d writeToFile:p options:NSDataWritingAtomic error:e]; }
static BOOL str(id x) { return [x isKindOfClass:NSString.class]; }
static BOOL number(id x) { return [x isKindOfClass:NSNumber.class] && isfinite([x doubleValue]); }
static BOOL hex(id s) { return str(s) && [s length] == 64 && [s rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound; }
static BOOL uuid(id s) { return str(s) && [[NSUUID alloc] initWithUUIDString:s] != nil; }
NSString *DMNASHash(NSData *d) { unsigned char h[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(d.bytes, (CC_LONG)d.length, h); NSMutableString *s = [NSMutableString string]; for (unsigned i = 0; i < sizeof h; i++) [s appendFormat:@"%02x", h[i]]; return s; }
BOOL DMNASValidPath(NSString *p) {
    if (!str(p) || !p.length || p.length > 1024 || [p hasPrefix:@"/"] || [p containsString:@"\\"] || [p rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) return NO;
    for (NSString *c in [p componentsSeparatedByString:@"/"]) if (!c.length || [c isEqual:@"."] || [c isEqual:@".."] || [c.lowercaseString isEqual:@"settings"]) return NO;
    return YES;
}
static NSString *digest(NSArray *files) {
    NSMutableArray *a = [NSMutableArray array]; for (NSDictionary *f in files) [a addObject:@[f[@"path"], f[@"sha256"], f[@"size"]]];
    return DMNASHash(json(a));
}
static BOOL validManifest(id m, NSError **e) {
    if (![m isKindOfClass:NSDictionary.class] || ![@[@1, @2] containsObject:m[@"format"]] || !uuid(m[@"id"]) || !str(m[@"parent"]) || ([m[@"parent"] length] && !uuid(m[@"parent"])) || !uuid(m[@"device"]) || !number(m[@"savedAt"]) || [m[@"savedAt"] doubleValue] < 0 || ![m[@"files"] isKindOfClass:NSArray.class] || [m[@"files"] count] > kFiles) return DMNASIssue(e, DMNASDataError, "ManifestInvalid", 0);
    NSMutableSet *seen = [NSMutableSet set]; NSString *last = nil;
    for (id f in m[@"files"]) {
        if (![f isKindOfClass:NSDictionary.class] || !DMNASValidPath(f[@"path"]) || !number(f[@"mtime"]) || [f[@"mtime"] doubleValue] < 0) return DMNASIssue(e, DMNASDataError, "FileInfoInvalid", 0);
        NSString *p = f[@"path"], *fold = p.precomposedStringWithCanonicalMapping.lowercaseString;
        if ([seen containsObject:fold] || (last && [last compare:p options:NSLiteralSearch] != NSOrderedAscending)) return DMNASIssue(e, DMNASDataError, "PathsUnsorted", 0);
        for (NSString *ancestor = p.stringByDeletingLastPathComponent; ancestor.length; ancestor = ancestor.stringByDeletingLastPathComponent) if ([seen containsObject:ancestor.precomposedStringWithCanonicalMapping.lowercaseString]) return DMNASIssue(e, DMNASDataError, "PathsConflict", 0);
        for (NSString *previous in seen) if ([previous hasPrefix:[fold stringByAppendingString:@"/"]]) return DMNASIssue(e, DMNASDataError, "PathsConflict", 0);
        [seen addObject:fold]; last = p;
    }
    return YES;
}

// 分组标识使用路径与名称，不使用内容 hash；主文件确定归属，删除后由已记住的描述保留归属。
// Group identities are paths/names, not content hashes. Primary files establish
// ownership; remembered descriptors retain it when a primary is removed.
NSDictionary *DMNASGroups(NSDictionary *snapshot, NSDictionary *known, NSError **e) {
    NSMutableDictionary *owners = [NSMutableDictionary dictionary];
    for (NSString *key in known) {
        NSDictionary *g = known[key];
        if (str(g[@"kind"]) && str(g[@"name"]) && str(g[@"root"])) owners[key] = g;
    }
    for (NSDictionary *f in snapshot[@"files"]) {
        NSString *p = f[@"path"], *ext = p.pathExtension.lowercaseString;
        if (![@[@"d2s", @"d2i", @"swvault"] containsObject:ext]) continue;
        BOOL character = [ext isEqual:@"d2s"];
        NSString *name = character && p.pathComponents.count > 1 ? p.pathComponents.firstObject : p.lastPathComponent.stringByDeletingPathExtension;
        NSString *key = [NSString stringWithFormat:@"%@:%@", character ? @"character" : @"stash", name];
        NSString *root = character && p.pathComponents.count > 1 ? [name stringByAppendingString:@"/"] : name;
        NSDictionary *old = owners[key];
        if (old && ![old[@"root"] isEqual:root]) { DMNASIssue(e, DMNASDataError, "OwnerConflict", 0); return nil; }
        owners[key] = @{@"kind":character ? @"character" : @"stash", @"name":name, @"root":root};
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSDictionary *f in snapshot[@"files"]) {
        NSString *p = f[@"path"], *owner = nil;
        for (NSString *key in owners) {
            NSDictionary *g = owners[key]; NSString *root = g[@"root"];
            if ([g[@"kind"] isEqual:@"auxiliary"]) continue;
            BOOL match;
            if ([g[@"kind"] isEqual:@"character"])
                match = [root hasSuffix:@"/"] ? [p hasPrefix:root] : (p.pathComponents.count == 1 && [p.stringByDeletingPathExtension isEqual:root]);
            else
                match = [p.lastPathComponent.stringByDeletingPathExtension isEqual:g[@"name"]] &&
                    ([@[@"d2i", @"swvault"] containsObject:p.pathExtension.lowercaseString] ||
                     (p.pathComponents.count > 1 && [p.pathComponents.firstObject isEqual:g[@"name"]]));
            // 仓库目录同时拥有其中的附属文件。
            // A stash directory also owns its ancillary files.
            if ([g[@"kind"] isEqual:@"stash"] && p.pathComponents.count > 1 && [p.pathComponents.firstObject isEqual:g[@"name"]]) match = YES;
            if (!match) continue;
            if (owner && ![owner isEqual:key]) { DMNASIssue(e, DMNASDataError, "MultipleOwners", 0); return nil; }
            owner = key;
        }
        owner = owner ?: @"auxiliary";
        if (!result[owner]) {
            NSMutableDictionary *g = [(owners[owner] ?: @{@"kind":@"auxiliary", @"name":@(dm_ui("dmNasOtherSaves")), @"root":@""}) mutableCopy];
            g[@"files"] = [NSMutableArray array]; result[owner] = g;
        }
        [result[owner][@"files"] addObject:f];
    }
    for (NSString *key in result) {
        NSMutableDictionary *g = result[key]; g[@"format"] = snapshot[@"format"] ?: @1;
        g[@"id"] = NSUUID.UUID.UUIDString; g[@"parent"] = @""; g[@"device"] = snapshot[@"device"];
        g[@"savedAt"] = snapshot[@"savedAt"];
        BOOL hashed = YES; for (NSDictionary *f in g[@"files"]) if (!hex(f[@"sha256"]) || !number(f[@"size"])) hashed = NO;
        if (hashed) g[@"digest"] = digest(g[@"files"]);
    }
    return result;
}

// hash 仅用于本机变化检测与缓存，不作为远端要求。
// Hashes remain local change-detection/cache keys, never remote requirements.
static id wireValue(id value) {
    if ([value isKindOfClass:NSArray.class]) { NSMutableArray *result = [NSMutableArray array]; for (id v in value) [result addObject:wireValue(v)]; return result; }
    if (![value isKindOfClass:NSDictionary.class]) return value;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    BOOL manifest = value[@"files"] && value[@"id"];
    for (NSString *key in value) {
        if (manifest && [key isEqual:@"digest"]) continue;
        if (manifest && [key isEqual:@"files"]) {
            NSMutableArray *files = [NSMutableArray array];
            for (NSDictionary *f in value[key]) [files addObject:@{@"path":f[@"path"], @"mtime":f[@"mtime"]}];
            result[key] = files;
        } else result[key] = wireValue(value[key]);
    }
    if (manifest) result[@"format"] = @2;
    return result;
}

// 携带凭据的会话拒绝重定向与超大或无界响应。
// Keep redirects and large/unbounded responses out of the credential-bearing session.
@interface DMNASHTTP : NSObject <NSURLSessionDataDelegate>
@property NSMutableData *data;
@property NSHTTPURLResponse *response;
@property NSError *error;
@property dispatch_semaphore_t done;
@end
@implementation DMNASHTTP
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)q completionHandler:(void (^)(NSURLRequest *))c { (void)s; (void)t; (void)r; (void)q; c(nil); }
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))c { (void)s; (void)t; self.response = (id)r; c(r.expectedContentLength > (long long)(kFileBytes + 1048576) ? NSURLSessionResponseCancel : NSURLSessionResponseAllow); }
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d { (void)s; if (self.data.length + d.length > kFileBytes + 1048576) { [t cancel]; return; } [self.data appendData:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e { (void)s; (void)t; self.error = e; dispatch_semaphore_signal(self.done); }
@end


// WebDAV 目录列表仅作为数据，使用路径前先验证。
// WebDAV directory listings are data only; paths are validated before use.
@interface DMNASListing : NSObject <NSXMLParserDelegate>
@property NSMutableArray *entries;
@property NSMutableDictionary *entry;
@property NSMutableString *text;
@property NSString *field;
@end
@implementation DMNASListing
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q attributes:(NSDictionary *)a {
    (void)q; (void)a; if (![ns isEqual:@"DAV:"]) return;
    if ([name isEqual:@"response"]) { if (self.entries.count >= 8192) { [parser abortParsing]; return; } self.entry = [@{@"directory":@NO} mutableCopy]; }
    if (!self.entry) return;
    if ([name isEqual:@"collection"]) self.entry[@"directory"] = @YES;
    if ([@[@"href", @"getlastmodified", @"status"] containsObject:name]) { self.field = name; self.text = [NSMutableString string]; }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)s { (void)parser; [self.text appendString:s]; }
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)ns qualifiedName:(NSString *)q {
    (void)parser; (void)q; if (![ns isEqual:@"DAV:"]) return;
    if ([name isEqual:self.field]) { self.entry[name] = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; self.text = nil; self.field = nil; }
    if ([name isEqual:@"response"]) { if (self.entry) [self.entries addObject:self.entry]; self.entry = nil; }
}
@end
static BOOL putOK(NSInteger status) { return status == 200 || status == 201 || status == 204; }
static NSString *escaped(NSString *path) {
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    NSMutableArray *parts = [NSMutableArray array]; for (NSString *p in path.pathComponents) [parts addObject:[p stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
    return [parts componentsJoinedByString:@"/"];
}
static NSString *const metadataPath = @".d2r-sync.json", *const transactionPath = @".d2r-transaction.json", *const uploadPath = @".d2r-upload/";
@interface DMNASStore ()
@property(nonatomic, copy) NSString *downloadRoot;
@property(nonatomic, copy) NSArray *currentListing;
@property(nonatomic) BOOL uploadingBatch;
@property(nonatomic, copy) NSSet *readPaths;
@property(nonatomic, copy) NSDictionary *activityGroups;
// 串行请求共用连接池；超时后丢弃整个会话，避免迟到回调污染下一次请求。
// Serial requests share a connection pool; discard timed-out sessions so late callbacks cannot affect the next request.
@property(nonatomic, strong) NSURLSession *httpSession;
@property(nonatomic, strong) DMNASHTTP *httpDelegate;
@property(nonatomic) NSUInteger requestCount;
// 下列观察只在一轮同步内有效；目录变动立即使对应观察失效。
// These observations live for one sync attempt; directory changes invalidate the affected observations.
@property(nonatomic, strong) NSMutableSet *knownDirectories;
@property(nonatomic) BOOL markerRead;
@property(nonatomic, copy) NSDictionary *observedMarker;
@property(nonatomic, copy) NSArray *publishedListing;
- (BOOL)validGroups:(NSDictionary *)metadata error:(NSError **)error;
- (BOOL)recoverGroup:(NSDictionary *)transaction error:(NSError **)error;
- (BOOL)recoverGroup:(NSDictionary *)transaction created:(NSMutableSet *)created fresh:(BOOL)fresh error:(NSError **)error;
- (BOOL)recoverDirectory:(NSDictionary *)transaction fresh:(BOOL)fresh error:(NSError **)error;
- (NSDictionary *)initializeGroups:(NSDictionary *)current backup:(NSDictionary *)backup error:(NSError **)error;
- (NSDictionary *)aggregate:(NSDictionary *)metadata slot:(NSString *)slot;
@end
@implementation DMNASStore
- (void)dealloc { [_httpSession invalidateAndCancel]; }
- (BOOL)within:(NSError **)e { return !self.deadline || NSDate.date.timeIntervalSince1970 < self.deadline ? YES : DMNASIssue(e, DMNASNetworkError, "TimeoutRetry", NSURLErrorTimedOut); }
- (NSString *)path:(NSString *)rel { return [self.cache stringByAppendingPathComponent:rel]; }
- (NSURL *)url:(NSString *)path {
    NSString *base = [self.root hasSuffix:@"/"] ? self.root : [self.root stringByAppendingString:@"/"];
    return [NSURL URLWithString:[base stringByAppendingString:path]];
}
- (NSData *)request:(NSString *)method path:(NSString *)path body:(NSData *)body headers:(NSDictionary *)headers response:(NSHTTPURLResponse **)out error:(NSError **)e {
    if (![self within:e]) return nil;
    NSURLComponents *base = [NSURLComponents componentsWithString:self.root]; BOOL local = self.testLoopback && [base.scheme isEqual:@"http"] && ([@[@"127.0.0.1", @"localhost", @"::1"] containsObject:base.host]);
    if ((!local && ![base.scheme isEqual:@"https"]) || !base.host.length || base.user || base.password || base.query || base.fragment) { DMNASIssue(e, DMNASConfigurationError, "RootRequired", 0); return nil; }
    NSString *u = [self.root hasSuffix:@"/"] ? self.root : [self.root stringByAppendingString:@"/"];
    NSURL *url = [NSURL URLWithString:[u stringByAppendingString:path]];
    if (!url) { DMNASIssue(e, DMNASConfigurationError, "URLInvalid", 0); return nil; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url]; r.HTTPMethod = method; r.HTTPBody = body; r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSString *auth = [[[NSString stringWithFormat:@"%@:%@", self.username ?: @"", self.password ?: @""] dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    [r setValue:[@"Basic " stringByAppendingString:auth] forHTTPHeaderField:@"Authorization"];
    [r setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    // 下载和续传比较使用原始字节，上传依赖服务器成功响应。
    // Downloads and resume comparisons use raw bytes; uploads trust successful server responses.
    [r setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    for (NSString *k in headers) [r setValue:headers[k] forHTTPHeaderField:k];
    NSTimeInterval timeout = self.deadline ? MIN(15, self.deadline - NSDate.date.timeIntervalSince1970) : 15;
    if (timeout <= 0) { DMNASIssue(e, DMNASNetworkError, "Timeout", NSURLErrorTimedOut); return nil; }
    r.timeoutInterval = timeout;
    if (self.activity) {
        BOOL download = [method isEqual:@"GET"] && ([path hasPrefix:@"save/"] || [path hasPrefix:@"backup/"]);
        self.activity(self.uploadingBatch ? DMNASActivityUploading : download ? DMNASActivityDownloading : DMNASActivityChecking);
    }
    if (!self.httpSession) {
        self.httpDelegate = [DMNASHTTP new];
        NSURLSessionConfiguration *c = NSURLSessionConfiguration.ephemeralSessionConfiguration; c.timeoutIntervalForResource = 15; c.URLCredentialStorage = nil; c.HTTPCookieStorage = nil; c.URLCache = nil;
        self.httpSession = [NSURLSession sessionWithConfiguration:c delegate:self.httpDelegate delegateQueue:nil];
    }
    DMNASHTTP *h = self.httpDelegate; h.data = [NSMutableData data]; h.response = nil; h.error = nil; h.done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.httpSession dataTaskWithRequest:r]; self.requestCount++; [task resume];
    if (dispatch_semaphore_wait(h.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)))) {
        [self.httpSession invalidateAndCancel]; self.httpSession = nil; self.httpDelegate = nil;
        DMNASIssue(e, DMNASNetworkError, "TimeoutKept", NSURLErrorTimedOut); return nil;
    }
    if (h.error) {
        if (h.error.code == NSURLErrorTimedOut) { [self.httpSession invalidateAndCancel]; self.httpSession = nil; self.httpDelegate = nil; }
        DMNASIssue(e, DMNASNetworkError, method.UTF8String, h.error.code); return nil;
    }
    if (out) *out = h.response;
    NSInteger code = h.response.statusCode;
    if (code == 401 || code == 403) { DMNASIssue(e, DMNASAuthenticationError, method.UTF8String, code); return nil; }
    if (code >= 300 && code < 400) { DMNASIssue(e, DMNASConfigurationError, "Redirect", code); return nil; }
    return h.data;
}

- (BOOL)prepare:(NSError **)e { return [FM() createDirectoryAtPath:self.cache withIntermediateDirectories:YES attributes:nil error:e]; }
- (BOOL)mkdir:(NSString *)p error:(NSError **)e {
    if ([self.knownDirectories containsObject:p]) return YES;
    NSHTTPURLResponse *r = nil; NSData *d = [self request:@"MKCOL" path:p body:nil headers:nil response:&r error:e];
    if (d && (r.statusCode == 201 || r.statusCode == 405)) { [self.knownDirectories addObject:p]; return YES; }
    return d ? DMNASIssue(e, DMNASServerError, "CreateFailed", r.statusCode) : NO;
}
- (void)forgetDirectory:(NSString *)p {
    if (![p hasSuffix:@"/"]) return;
    for (NSString *known in self.knownDirectories.allObjects) if ([known hasPrefix:p]) [self.knownDirectories removeObject:known];
}
- (BOOL)removeRemote:(NSString *)p error:(NSError **)e {
    NSHTTPURLResponse *r = nil; NSData *d = [self request:@"DELETE" path:p body:nil headers:nil response:&r error:e];
    if (d && (r.statusCode == 200 || r.statusCode == 204 || r.statusCode == 404)) {
        [self forgetDirectory:p];
        if ([p isEqual:@".d2r-upload.json"]) { self.markerRead = YES; self.observedMarker = nil; }
        return YES;
    }
    return d ? DMNASIssue(e, DMNASServerError, "CleanupFailed", r.statusCode) : NO;
}
- (BOOL)move:(NSString *)source to:(NSString *)target overwrite:(BOOL)overwrite error:(NSError **)e {
    NSHTTPURLResponse *r = nil; NSData *d = [self request:@"MOVE" path:source body:nil headers:@{@"Destination":[self url:target].absoluteString, @"Overwrite":overwrite ? @"T" : @"F"} response:&r error:e];
    if (d && (r.statusCode == 201 || r.statusCode == 204)) {
        [self forgetDirectory:source]; [self forgetDirectory:target];
        if ([target hasSuffix:@"/"]) [self.knownDirectories addObject:target];
        return YES;
    }
    return d ? DMNASIssue(e, DMNASServerError, "MoveFailed", r.statusCode) : NO;
}
- (BOOL)write:(NSData *)data path:(NSString *)path error:(NSError **)e {
    NSHTTPURLResponse *r = nil; NSData *d = [self request:@"PUT" path:path body:data headers:nil response:&r error:e];
    if (!d) return NO;
    return putOK(r.statusCode) ? YES : DMNASIssue(e, DMNASServerError, "UploadFailed", r.statusCode);
}
- (BOOL)writeJSON:(NSDictionary *)value path:(NSString *)path error:(NSError **)e {
    NSString *temp = [path stringByAppendingString:@".tmp"];
    return [self write:json(wireValue(value)) path:temp error:e] && [self move:temp to:path overwrite:YES error:e];
}
// 明确区分元数据缺失与无效。
// Missing and invalid metadata are deliberately distinct.
- (NSDictionary *)remoteJSON:(NSString *)path missing:(BOOL *)missing error:(NSError **)e {
    *missing = NO; NSHTTPURLResponse *r = nil; NSData *d = [self request:@"GET" path:path body:nil headers:nil response:&r error:e];
    if (!d) return nil;
    if (r.statusCode == 404) { *missing = YES; return nil; }
    if (r.statusCode != 200 || d.length > 32 * 1024 * 1024) { DMNASIssue(e, DMNASServerError, "MetadataReadFailed", r.statusCode); return nil; }
    id value = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class]) { DMNASIssue(e, DMNASDataError, "MetadataDamaged", 0); return nil; }
    return value;
}
- (NSArray *)listing:(NSString *)directory missing:(BOOL *)missing error:(NSError **)e {
    *missing = NO; NSHTTPURLResponse *r = nil;
    NSData *d = [self request:@"PROPFIND" path:directory body:[@"<d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/><d:getlastmodified/></d:prop></d:propfind>" dataUsingEncoding:NSUTF8StringEncoding] headers:@{@"Depth":@"1", @"Content-Type":@"application/xml"} response:&r error:e];
    if (!d) return nil;
    if (r.statusCode == 404) { *missing = YES; return nil; }
    if (r.statusCode != 207) { DMNASIssue(e, DMNASServerError, "ListingFailed", r.statusCode); return nil; }
    DMNASListing *delegate = [DMNASListing new]; delegate.entries = [NSMutableArray array];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:d]; parser.shouldProcessNamespaces = YES; parser.shouldResolveExternalEntities = NO; parser.delegate = delegate;
    if (![parser parse] || !delegate.entries.count) { DMNASIssue(e, DMNASDataError, "ListingInvalid", 0); return nil; }
    for (NSDictionary *entry in delegate.entries) if (![entry[@"href"] length] || ![entry[@"status"] containsString:@" 200 "]) { DMNASIssue(e, DMNASDataError, "ListingUnreadable", 0); return nil; }
    return delegate.entries;
}
- (BOOL)exists:(NSString *)directory present:(BOOL *)present error:(NSError **)e {
    BOOL missing; NSArray *entries = [self listing:directory missing:&missing error:e]; *present = !missing;
    return entries || missing;
}
- (NSArray *)filesIn:(NSString *)directory error:(NSError **)e { return [self filesIn:directory missing:nil error:e]; }
- (NSArray *)filesIn:(NSString *)directory missing:(BOOL *)absent error:(NSError **)e {
    if (absent) *absent = NO;
    NSMutableSet *directories = [NSMutableSet setWithObject:directory];
    NSMutableArray *queue = [NSMutableArray arrayWithObject:@""], *files = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < queue.count; i++) {
        NSString *relDir = queue[i], *parent = [directory stringByAppendingString:relDir]; BOOL missing;
        NSArray *entries = [self listing:parent missing:&missing error:e]; if (!entries) {
            if (missing && i == 0 && absent) { *absent = YES; return nil; }
            if (missing) DMNASIssue(e, DMNASDataError, "ListingIncomplete", 0); return nil;
        }
        NSString *parentPath = [self url:parent].path; while ([parentPath hasSuffix:@"/"]) parentPath = [parentPath substringToIndex:parentPath.length - 1];
        NSString *prefix = [parentPath stringByAppendingString:@"/"];
        for (NSDictionary *entry in entries) {
            NSURL *url = [NSURL URLWithString:entry[@"href"] relativeToURL:[self url:parent]].absoluteURL;
            NSString *path = url.path; while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
            if ([path isEqual:parentPath]) continue;
            if (![url.host isEqual:[self url:parent].host] || ![path hasPrefix:prefix]) { DMNASIssue(e, DMNASDataError, "PathOutside", 0); return nil; }
            NSString *name = [path substringFromIndex:prefix.length];
            NSString *relative = [[relDir stringByRemovingPercentEncoding] stringByAppendingString:name];
            if (!DMNASValidPath(relative) || [name containsString:@"/"] || [seen containsObject:relative.precomposedStringWithCanonicalMapping.lowercaseString] || seen.count >= kFiles * 2) { DMNASIssue(e, DMNASDataError, "PathsInvalid", 0); return nil; }
            [seen addObject:relative.precomposedStringWithCanonicalMapping.lowercaseString];
            if ([entry[@"directory"] boolValue]) {
                NSString *child = [escaped(relative) stringByAppendingString:@"/"];
                [queue addObject:child]; [directories addObject:[directory stringByAppendingString:child]];
            }
            else { [files addObject:@{@"path":relative, @"remote":[directory stringByAppendingString:escaped(relative)], @"modified":entry[@"getlastmodified"] ?: @""}]; if (files.count > kFiles) { DMNASIssue(e, DMNASDataError, "TooManyFiles", 0); return nil; } }
        }
    }
    [files sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch]; }];
    [self.knownDirectories unionSet:directories]; return files;
}
// 检查传输完成情况和路径，不比较远端文件大小或 hash。
// Check transfer completion and paths, without comparing file sizes or hashes.
- (BOOL)verify:(NSDictionary *)manifest directory:(NSString *)directory error:(NSError **)e {
    NSArray *files = [self filesIn:directory error:e]; if (!files) return NO;
    return [self verifyFiles:files manifest:manifest error:e];
}
- (BOOL)verifyFiles:(NSArray *)files manifest:(NSDictionary *)manifest error:(NSError **)e {
    if (files.count != [manifest[@"files"] count]) return DMNASIssue(e, DMNASDataError, "CountMismatch", 0);
    for (NSUInteger i = 0; i < files.count; i++) if (![files[i][@"path"] isEqual:manifest[@"files"][i][@"path"]]) return DMNASIssue(e, DMNASDataError, "ListingMismatch", 0);
    return YES;
}
- (BOOL)probe:(NSError **)e {
    if (![self prepare:e]) return NO;
    [FM() removeItemAtPath:[self path:@"capabilities.json"] error:nil];
    NSString *directory = [NSString stringWithFormat:@".d2r-probe-%@/", NSUUID.UUID.UUIDString];
    if (![self mkdir:directory error:e]) return NO;
    @try {
        NSString *nested = [directory stringByAppendingString:[escaped(@"raw save") stringByAppendingString:@"/"]], *target = [directory stringByAppendingString:@"moved/"];
        if (![self mkdir:nested error:e] || ![self write:[@"probe" dataUsingEncoding:NSUTF8StringEncoding] path:[nested stringByAppendingString:@"Hero.d2s"] error:e]) return NO;
        if (![self move:nested to:target overwrite:NO error:e]) return NO;
        NSArray *files = [self filesIn:target error:e]; if (files.count != 1 || ![files[0][@"path"] isEqual:@"Hero.d2s"]) return DMNASIssue(e, DMNASServerError, "ProbeMoveFailed", 0);
        NSHTTPURLResponse *r = nil; NSData *d = [self request:@"GET" path:[target stringByAppendingString:@"Hero.d2s"] body:nil headers:nil response:&r error:e];
        if (!d || r.statusCode != 200 || ![d isEqual:[@"probe" dataUsingEncoding:NSUTF8StringEncoding]]) return DMNASIssue(e, DMNASServerError, "ProbeContentFailed", r.statusCode);
        if (![self writeJSON:@{@"test":@1} path:[directory stringByAppendingString:@"metadata"] error:e] || ![self writeJSON:@{@"test":@2} path:[directory stringByAppendingString:@"metadata"] error:e]) return NO;
        if (![self removeRemote:target error:e]) return NO;
        self.message = @(dm_ui("dmNasProbeSuccess"));
        return putJSON(@{@"schema":@4, @"mode":@"single", @"root":self.root, @"username":self.username}, [self path:@"capabilities.json"], e);
    } @finally {
        NSTimeInterval deadline = self.deadline; self.deadline = MAX(deadline, NSDate.date.timeIntervalSince1970 + 2);
        [self removeRemote:directory error:nil]; self.deadline = deadline;
    }
}
- (NSDictionary *)snapshot:(NSString *)directory savedAt:(double)stamp error:(NSError **)e {
    char canonical[PATH_MAX];
    if (!realpath(directory.fileSystemRepresentation, canonical)) { DMNASIssue(e, DMNASLocalError, "LocalReadFailed", errno); return nil; }
    directory = @(canonical);
    NSMutableArray *files = [NSMutableArray array]; NSUInteger total = 0; double latest = 0;
    NSDictionary *root = [FM() attributesOfItemAtPath:directory error:e]; if (![root[NSFileType] isEqual:NSFileTypeDirectory]) { DMNASIssue(e, DMNASLocalError, "LocalMissing", 0); return nil; }
    __block BOOL enumerationFailed = NO;
    NSURL *rootURL = [NSURL fileURLWithPath:directory isDirectory:YES];
    NSDirectoryEnumerator *it = [FM() enumeratorAtURL:rootURL includingPropertiesForKeys:nil options:0 errorHandler:^BOOL(NSURL *url, NSError *error) { (void)url; (void)error; enumerationFailed = YES; return NO; }];
    for (NSURL *url in it) {
        if (![url.path hasPrefix:[directory stringByAppendingString:@"/"]]) { DMNASIssue(e, DMNASLocalError, "LocalPathOutside", 0); return nil; }
        NSString *p = [url.path substringFromIndex:directory.length + 1];
        if ([p.pathComponents.firstObject.lowercaseString isEqual:@"settings"]) { [it skipDescendants]; continue; }
        NSDictionary *a = [FM() attributesOfItemAtPath:[directory stringByAppendingPathComponent:p] error:e];
        if ([a[NSFileType] isEqual:NSFileTypeDirectory]) continue;
        if (![a[NSFileType] isEqual:NSFileTypeRegular] || !DMNASValidPath(p) || [a[NSFileSize] unsignedLongLongValue] > kFileBytes) { DMNASIssue(e, DMNASLocalError, "FileUnsupported", 0); return nil; }
        NSData *d = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:p] options:NSDataReadingMappedIfSafe error:e]; if (!d) return nil;
        total += d.length; if (files.count >= kFiles || total > kTotalBytes) { DMNASIssue(e, DMNASLocalError, "LocalLimit", 0); return nil; }
        double mt = [a[NSFileModificationDate] timeIntervalSince1970]; latest = MAX(latest, mt);
        [files addObject:@{@"path":p, @"sha256":DMNASHash(d), @"size":@(d.length), @"mtime":@(MAX(0, mt))}];
    }
    if (enumerationFailed || !it) { DMNASIssue(e, DMNASLocalError, "SnapshotIncomplete", 0); return nil; }
    [files sortUsingComparator:^NSComparisonResult(id a, id b) { return [a[@"path"] compare:b[@"path"] options:NSLiteralSearch]; }];
    NSDictionary *m = @{@"format":@1, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":@(stamp > 0 ? stamp : latest), @"files":files, @"digest":digest(files)};
    return validManifest(m, e) ? m : nil;
}
- (BOOL)backup:(NSString *)save error:(NSError **)e {
    NSString *dir = [self path:@"backups"]; if (![FM() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:e]) return NO;
    NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%.0f-%@", NSDate.date.timeIntervalSince1970 * 1000, NSUUID.UUID.UUIDString]];
    if (clonefile(save.fileSystemRepresentation, p.fileSystemRepresentation, 0)) return DMNASIssue(e, DMNASLocalError, "BackupFailed", errno);
    for (NSString *name in [FM() contentsOfDirectoryAtPath:dir error:nil]) if (![name isEqual:p.lastPathComponent]) [FM() removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    return YES;
}
- (BOOL)apply:(NSDictionary *)m save:(NSString *)save error:(NSError **)e {
    NSString *stage = [save stringByAppendingFormat:@".nas-%@", NSUUID.UUID.UUIDString]; BOOL ok = NO;
    if (![FM() createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:e]) return NO;
    @try {
        for (NSDictionary *f in m[@"files"]) {
            NSData *d = [self object:f error:e]; if (!d) return NO;
            NSString *p = [stage stringByAppendingPathComponent:f[@"path"]];
            if (![FM() createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:e] || ![d writeToFile:p options:NSDataWritingAtomic error:e] || ![FM() setAttributes:@{NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:[f[@"mtime"] doubleValue]], NSFilePosixPermissions:@0644} ofItemAtPath:p error:e]) return NO;
        }
        NSString *settings = [save stringByAppendingPathComponent:@"Settings"];
        if ([FM() fileExistsAtPath:settings] && ![FM() copyItemAtPath:settings toPath:[stage stringByAppendingPathComponent:@"Settings"] error:e]) return NO;
        if (![self within:e] || ![self backup:save error:e] || ![self within:e]) return NO;
        if (renamex_np(stage.fileSystemRepresentation, save.fileSystemRepresentation, RENAME_SWAP)) return DMNASIssue(e, DMNASLocalError, "ReplaceFailed", errno);
        ok = YES;
    } @finally { [FM() removeItemAtPath:stage error:nil]; }
    return ok;
}
- (BOOL)validMetadata:(id)m error:(NSError **)e {
    if (![m isKindOfClass:NSDictionary.class]) return DMNASIssue(e, DMNASDataError, "MetadataInvalid", 0);
    if ([m[@"format"] isEqual:@4]) return [self validGroups:m error:e];
    return DMNASIssue(e, DMNASUpgradeError, "UnsupportedMetadataFormat", 0);
}
- (NSData *)object:(NSDictionary *)f error:(NSError **)e {
    NSString *dir = [self path:@"objects"];
    NSString *key = str(f[@"sha256"]) ? f[@"sha256"] : DMNASHash([f[@"path"] dataUsingEncoding:NSUTF8StringEncoding]);
    // 该键定位刚扫描的内容或固定备份，不用于校验。
    // The key addresses freshly scanned bytes or a pinned restore, not a check.
    NSString *p = [dir stringByAppendingPathComponent:DMNASValidPath(key) ? key : DMNASHash([key dataUsingEncoding:NSUTF8StringEncoding])];
    NSData *d = [NSData dataWithContentsOfFile:p options:NSDataReadingMappedIfSafe error:nil]; if (d) return d;
    if (!self.downloadRoot) { DMNASIssue(e, DMNASBackupError, "RestoreCacheIncomplete", 0); return nil; }
    NSString *path = [self.downloadRoot stringByAppendingString:escaped(f[@"path"])];
    NSHTTPURLResponse *r = nil; d = [self request:@"GET" path:path body:nil headers:nil response:&r error:e];
    if (!d || r.statusCode != 200) { DMNASIssue(e, DMNASServerError, "DownloadFailed", r.statusCode); return nil; }
    if (![FM() createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:e] || ![d writeToFile:p options:NSDataWritingAtomic error:e]) return nil;
    return d;
}
- (BOOL)upload:(NSDictionary *)m source:(NSString *)source directory:(NSString *)directory error:(NSError **)e {
    // 建目录、续传检查和文件写入均属于上传阶段；仅随后事务与目录验证显示检查中。
    // Directory setup, resume checks and file writes are all one upload
    // phase. Only the subsequent journal/directory verification shows checking.
    BOOL previous = self.uploadingBatch; self.uploadingBatch = YES;
    fprintf(stderr, "NAS upload batch begin: %lu files\n", (unsigned long)[m[@"files"] count]);
    @try {
        NSString *marker = @".d2r-upload.json";
        BOOL missing = self.markerRead && !self.observedMarker;
        NSDictionary *staged = self.markerRead ? self.observedMarker : [self remoteJSON:marker missing:&missing error:e];
        if (!staged && !missing) return NO;
        BOOL present; if (![self exists:directory present:&present error:e]) return NO;
        BOOL resume = present && [staged[@"version"] isEqual:m[@"id"]];
        if (!resume && ((present && ![self removeRemote:directory error:e]) || ![self mkdir:directory error:e] || ![self writeJSON:@{@"version":m[@"id"]} path:marker error:e])) return NO;
        NSMutableSet *dirs = [NSMutableSet set];
        for (NSDictionary *f in m[@"files"]) {
            NSData *data = source ? [NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:f[@"path"]] options:NSDataReadingMappedIfSafe error:e] : [self object:f error:e];
            if (!data) return DMNASIssue(e, DMNASLocalError, "PendingReadFailed", 0);
            NSString *parent = [f[@"path"] stringByDeletingLastPathComponent], *path = @"";
            for (NSString *component in parent.pathComponents) {
                path = [path stringByAppendingFormat:@"%@/", escaped(component)];
                if (![dirs containsObject:path]) { if (![self mkdir:[directory stringByAppendingString:path] error:e]) return NO; [dirs addObject:path]; }
            }
            NSString *remotePath = [directory stringByAppendingString:escaped(f[@"path"])];
            if (resume) {
                NSHTTPURLResponse *r = nil; NSData *old = [self request:@"GET" path:remotePath body:nil headers:nil response:&r error:e];
                if (!old) return NO;
                if (r.statusCode == 200 && [old isEqual:data]) continue;
                if (r.statusCode != 404 && r.statusCode != 200) return DMNASIssue(e, DMNASServerError, "ResumeReadFailed", r.statusCode);
            }
            if (![self write:data path:remotePath error:e]) return NO;
        }
        return YES;
    } @finally { self.uploadingBatch = previous; }
}
// 小型事务日志支持超时、终止或 MOVE 成功但响应丢失后，在下次启动完成目录替换。
// A small journal lets a later launch finish a directory replacement after
// timeout, termination, or a successful MOVE whose response never arrived.
- (BOOL)recover:(NSError **)e {
    BOOL missing; NSDictionary *txn = [self remoteJSON:transactionPath missing:&missing error:e];
    if (missing) {
        BOOL noMarker; NSDictionary *marker = [self remoteJSON:@".d2r-upload.json" missing:&noMarker error:e];
        if (!noMarker && !marker) return NO;
        self.markerRead = YES; self.observedMarker = marker;
        if (noMarker) return YES;
        BOOL staged; if (![self exists:uploadPath present:&staged error:e]) return NO;
        return staged || [self removeRemote:@".d2r-upload.json" error:e];
    }
    if (!txn) return NO;
    if ([txn[@"format"] isEqual:@4]) return [self recoverDirectory:txn fresh:NO error:e];
    if (![txn[@"format"] isEqual:@3]) return DMNASIssue(e, DMNASUpgradeError, "UnsupportedTransactionFormat", 0);
    return [self recoverGroup:txn error:e];
}
// 仅缓存本机观察结果，远端无需 hash 或大小字段。
// Cache only local observations. Remote hash/size fields remain unnecessary.
- (BOOL)rememberCurrent:(NSDictionary *)manifest listing:(NSArray *)entries error:(NSError **)e {
    if (![[entries valueForKey:@"path"] isEqual:[manifest[@"files"] valueForKey:@"path"]]) return NO;
    NSMutableDictionary *times = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in entries) times[entry[@"path"]] = entry[@"modified"];
    return putJSON(@{@"version":manifest[@"id"], @"manifest":manifest, @"times":times}, [self path:@"current-files.json"], e);
}
- (NSDictionary *)adopt:(NSString *)directory version:(NSString *)version force:(BOOL)force error:(NSError **)e {
    NSArray *entries = [self filesIn:directory error:e]; if (!entries) return nil;
    BOOL current = [directory isEqual:@"save/"];
    if (current) self.currentListing = entries;
    id cached = current && !force ? readJSON([self path:@"current-files.json"]) : nil;
    BOOL reusable = [cached isKindOfClass:NSDictionary.class] && [cached[@"version"] isEqual:version]
        && validManifest(cached[@"manifest"], nil) && [cached[@"times"] isKindOfClass:NSDictionary.class];
    if (!reusable) cached = nil;
    NSMutableDictionary *previous = [NSMutableDictionary dictionary];
    if (reusable) for (NSDictionary *f in cached[@"manifest"][@"files"]) previous[f[@"path"]] = f;
    // 读取内容前先分类完整目录，使附属文件与平铺 .swvault 继承主存档类型。
    // Classify the complete listing before reading any bytes, so sidecars and
    // flat .swvault files inherit the same kind as their main save file.
    NSMutableArray *paths = [NSMutableArray array];
    for (NSDictionary *entry in entries) [paths addObject:@{@"path":entry[@"path"], @"mtime":@0}];
    NSMutableDictionary *known = [[self knownGroups] mutableCopy]; [known addEntriesFromDictionary:self.activityGroups ?: @{}];
    NSDictionary *groups = DMNASGroups(@{@"format":@2, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":@0, @"files":paths}, known, nil);
    // 类型归属仅影响显示；缓存归属不明确时用通用提示，不改变下载或清单验证。
    // Attribution is presentation only; ambiguous cached ownership uses the
    // generic caption without changing download or manifest validation.
    NSMutableDictionary *kinds = [NSMutableDictionary dictionary];
    for (NSDictionary *group in groups.allValues) for (NSDictionary *file in group[@"files"]) kinds[file[@"path"]] = group[@"kind"];
    NSMutableArray *files = [NSMutableArray array]; NSUInteger total = 0; double latest = 0;
    NSDateFormatter *format = [NSDateFormatter new]; format.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]; format.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; format.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
    NSString *cache = [self path:@"objects"]; if (![FM() createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:e]) return nil;
    for (NSDictionary *entry in entries) {
        if (self.readPaths && ![self.readPaths containsObject:entry[@"path"]]) continue;
        NSDate *date = [format dateFromString:entry[@"modified"]]; double stamp = MAX(0, date.timeIntervalSince1970); latest = MAX(latest, stamp);
        NSDictionary *old = previous[entry[@"path"]]; NSString *hash = old[@"sha256"]; NSNumber *size = old[@"size"];
        BOOL reuse = date && stamp > 0 && [entry[@"modified"] isEqual:cached[@"times"][entry[@"path"]]]
            && hex(hash) && number(size) && size.doubleValue >= 0 && size.doubleValue <= kFileBytes
            && [FM() isReadableFileAtPath:[cache stringByAppendingPathComponent:hash]];
        if (!reuse) {
            self.activityKind = kinds[entry[@"path"]];
            NSHTTPURLResponse *r = nil; NSData *data = [self request:@"GET" path:entry[@"remote"] body:nil headers:nil response:&r error:e];
            if (!data || r.statusCode != 200 || data.length > kFileBytes) { DMNASIssue(e, DMNASServerError, "RawReadFailed", r.statusCode); return nil; }
            hash = DMNASHash(data); size = @(data.length);
            if (![data writeToFile:[cache stringByAppendingPathComponent:hash] options:NSDataWritingAtomic error:e]) return nil;
        }
        total += size.unsignedIntegerValue; if (total > kTotalBytes) { DMNASIssue(e, DMNASDataError, "RemoteLimit", 0); return nil; }
        [files addObject:@{@"path":entry[@"path"], @"sha256":hash, @"size":size, @"mtime":@(stamp)}];
    }
    return @{@"format":@1, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":@(latest), @"files":files, @"digest":digest(files)};
}
- (NSDictionary *)adopt:(NSString *)directory error:(NSError **)e { return [self adopt:directory version:nil force:YES error:e]; }
// 启动时发现已有备份，但不下载其内容。
// Discover a preexisting backup without fetching its contents during startup.
- (NSDictionary *)describeBackup:(NSError **)e {
    NSArray *entries = [self filesIn:@"backup/" error:e]; if (!entries) return nil;
    NSMutableArray *files = [NSMutableArray array];
    for (NSDictionary *entry in entries) [files addObject:@{@"path":entry[@"path"], @"mtime":@0}];
    return @{@"format":@2, @"id":NSUUID.UUID.UUIDString, @"parent":@"", @"device":self.device, @"savedAt":@0, @"files":files};
}
- (NSDictionary *)storedMetadata:(BOOL *)missing error:(NSError **)e {
    NSDictionary *meta = [self remoteJSON:metadataPath missing:missing error:e];
    if (meta) return [self validMetadata:meta error:e] ? meta : nil;
    if (!*missing) return nil;
    BOOL current; if (![self exists:@"save/" present:&current error:e]) { *missing = NO; return nil; }
    if (current) {
        *missing = NO; NSDictionary *m = [self adopt:@"save/" error:e]; if (!m) return nil;
        BOOL present; if (![self exists:@"backup/" present:&present error:e]) return nil;
        NSDictionary *backup = present ? [self describeBackup:e] : nil; if (present && !backup) return nil;
        meta = [self initializeGroups:m backup:backup error:e];
        return meta && [self rememberCurrent:[self aggregate:meta slot:@"current"] listing:self.currentListing error:e] ? meta : nil;
    }
    return nil;
}
// 分组协议复用以上有界传输。
// Group protocol implementation shares the bounded transport above.
#include "nas_groups.inc"
@end
