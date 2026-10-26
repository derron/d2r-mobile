// 直接调用共用生命周期与提交钩子，传输用可控假后端。
// Call the shared lifecycle and commit hook directly with a controllable fake transport.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdatomic.h>
#include "../../ios/Sources/cloud_ios.m"
void (*g_dm_save_commit_hook)(const char *);
void (*g_dm_ingame_hook)(int);
void (*g_dm_charsel_hook)(void);
static int calls, failNext;
static NSString *uploaded;
int dm_custom_get(const char *key) { return !strcmp(key,"webdav"); }
void dm_webdav_load_configuration(void) {}
int dm_webdav_config_ready(void) { return 1; }
int dm_webdav_test_mode(void) { return 0; }
BOOL dm_webdav_prepare(NSString *s,dispatch_queue_t q,NSString **a,NSString **b,NSString **c) { (void)s;(void)q;(void)a;(void)b;(void)c;return NO; }
int dm_webdav_run(NSString *s,NSString *b,NSString *c,int down) { (void)b;(void)c;assert(!down);calls++;uploaded=[NSString stringWithContentsOfFile:[s stringByAppendingPathComponent:@"data"] encoding:NSUTF8StringEncoding error:nil];if(failNext){failNext=0;return -1;}return 1; }
int dm_cloud_sync(const char *s,const char *c,const char *b,const char *t,int a,uint64_t n,int (*r)(const char *)) { (void)s;(void)c;(void)b;(void)t;(void)a;(void)n;(void)r;return 0; }
int dm_cloud_inbox_add(const char *s,const char *t,const char *p) { (void)s;(void)t;(void)p;return 0; }
uint64_t dm_cloud_pack_stamp(const char *p) { (void)p;return 0; }
int dm_cloud_bak_pack(const char *b,const char *u,const char *p,const char *w) { (void)b;(void)u;(void)p;(void)w;return 0; }
void dm_cloud_char_conflict_note(const char *u) { (void)u; }
static void drain(void) { dispatch_sync(g_q,^{}); }
int main(void) { @autoreleasepool {
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];g_save=[root stringByAppendingPathComponent:@"save"];
    [NSFileManager.defaultManager createDirectoryAtPath:g_save withIntermediateDirectories:YES attributes:nil error:nil];
    g_q=dispatch_queue_create("test.shared.lifecycle",DISPATCH_QUEUE_SERIAL);atomic_store(&g_webdav,1);
    cloud_ingame(1);[@"first" writeToFile:[g_save stringByAppendingPathComponent:@"data"] atomically:YES encoding:NSUTF8StringEncoding error:nil];on_commit(g_save.fileSystemRepresentation);drain();assert(!calls && g_pend);
    [@"latest" writeToFile:[g_save stringByAppendingPathComponent:@"data"] atomically:YES encoding:NSUTF8StringEncoding error:nil];on_commit(g_save.fileSystemRepresentation);drain();assert(!calls && g_pend);
    cloud_charsel();drain();assert(calls==1 && !g_pend && [uploaded isEqual:@"latest"]);
    failNext=1;on_commit(g_save.fileSystemRepresentation);drain();assert(calls==2 && g_pend);
    dm_cloud_flush(0);drain();assert(calls==3 && !g_pend);
    cloud_ingame(1);on_commit(g_save.fileSystemRepresentation);drain();assert(calls==3 && g_pend);
    dm_cloud_flush(1);drain();assert(calls==4 && !g_pend);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];puts("PASS: shared in-game deferral, latest snapshot, exit, background and failure retention");
} }
