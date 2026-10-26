// 共用存档同步核心的可选存储接口；原文件系统入口保持不变。
// Optional storage operations for the shared save-sync core; the filesystem API is unchanged.
#ifndef DM_CLOUDSYNC_H
#define DM_CLOUDSYNC_H
#include <stdint.h>
typedef struct {
    void *context;
    int (*list)(void *, int (*emit)(void *, const char *), void *);
    int (*read)(void *, const char *unit, const char *local_path); // 1 存在、0 不存在、-1 失败 | 1 present, 0 absent, -1 failed
    int (*publish)(void *, const char *unit, const char *local_path);
} dm_cloud_storage;
int dm_cloud_sync(const char *, const char *, const char *, const char *, int, uint64_t, int (*)(const char *));
int dm_cloud_sync_backend(const char *, const char *, const char *, const char *, int, uint64_t, int (*)(const char *), const dm_cloud_storage *);
#if DM_WEBDAV
int dm_cloud_uses_webdav(void);
#define DM_CLOUD_NOTICE(cloud, dav) (dm_cloud_uses_webdav() ? (dav) : (cloud))
#else
#define DM_CLOUD_NOTICE(cloud, dav) (cloud)
#endif
#endif
