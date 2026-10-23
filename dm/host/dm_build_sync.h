// 共享显示策略；传输与游戏控件各自在所属线程运行。
// Shared presentation policy; transport and game widgets remain on their own threads.
#pragma once
#include <stdint.h>

typedef enum { DM_SYNC_BUILD, DM_SYNC_UPLOAD, DM_SYNC_DOWNLOAD, DM_SYNC_COMPLETE, DM_SYNC_VERIFY, DM_SYNC_CHARACTER_COMPLETE, DM_SYNC_STASH_COMPLETE, DM_SYNC_CHARACTER_UPLOAD, DM_SYNC_STASH_UPLOAD, DM_SYNC_CHARACTER_DOWNLOAD, DM_SYNC_STASH_DOWNLOAD } dm_sync_phase;
typedef struct { dm_sync_phase phase; uint64_t complete_until; int transferred; } dm_sync_badge;
static inline void dm_sync_badge_begin(dm_sync_badge *s) { s->phase = DM_SYNC_BUILD; s->complete_until = 0; s->transferred = 0; }
static inline int dm_sync_is_transfer(dm_sync_phase phase) {
    return phase == DM_SYNC_UPLOAD || phase == DM_SYNC_DOWNLOAD || phase == DM_SYNC_CHARACTER_UPLOAD || phase == DM_SYNC_STASH_UPLOAD || phase == DM_SYNC_CHARACTER_DOWNLOAD || phase == DM_SYNC_STASH_DOWNLOAD;
}
static inline void dm_sync_badge_transfer(dm_sync_badge *s, dm_sync_phase phase) { s->phase = phase; s->complete_until = 0; if (dm_sync_is_transfer(phase)) s->transferred = 1; }
static inline void dm_sync_badge_finish(dm_sync_badge *s, int success, uint64_t now) {
    if (success && s->complete_until) return;
    s->phase = success && s->transferred ? DM_SYNC_COMPLETE : DM_SYNC_BUILD;
    s->complete_until = s->phase == DM_SYNC_COMPLETE ? now + UINT64_C(2000000000) : 0; s->transferred = 0;
}
static inline void dm_sync_badge_group_finish(dm_sync_badge *s, dm_sync_phase phase, uint64_t now) {
    s->phase = phase; s->complete_until = now + UINT64_C(2000000000); s->transferred = 0;
}
static inline dm_sync_phase dm_sync_badge_get(dm_sync_badge *s, uint64_t now) {
    if (s->complete_until && now >= s->complete_until) dm_sync_badge_begin(s);
    return s->phase;
}

// UIKit 管理手指对象；此策略仅判断手势是否为点击。
// UIKit owns the finger; this policy only decides whether its gesture is a tap.
typedef struct { float x, y; int cancelled; } dm_build_tap;
static inline int dm_build_rect_contains(const float r[4], float x, float y) {
    return x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3];
}
static inline void dm_build_tap_begin(dm_build_tap *t, float x, float y) { t->x = x; t->y = y; t->cancelled = 0; }
static inline void dm_build_tap_move(dm_build_tap *t, float x, float y) {
    float dx = x - t->x, dy = y - t->y;
    if (dx * dx + dy * dy > 100) t->cancelled = 1;
}

// 游戏启动前安装状态与回调。矩形相对游戏视图归一化；UIKit 不解引用游戏控件。
// Provider and callback are installed before the guest starts. Rectangles are
// normalized to the game UI view; UIKit never dereferences a guest widget.
void dm_update_sync_install(dm_sync_phase (*phase)(void), void (*open_settings)(void));
int dm_update_build_rect(float rect[4]);
void dm_update_build_open(void);
