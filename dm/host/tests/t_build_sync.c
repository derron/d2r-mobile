// 使用合成控件树和确定性时钟，不使用游戏或 NAS 文件。
// Synthetic widget tree and deterministic clocks; no game or NAS files.
#include "../dm_update.c"
#include <assert.h>

module_t g_mod[MAX_MOD]; int g_nmod;
static int ingame, busy, unstable, pad;
static uint32_t generation = 1;
int dm_uiscreen_ingame(void) { return ingame; }
int dm_padmode_busy(void) { return busy; }
int dm_padmode_current(void) { return pad; }
uint64_t dm_padmode_page_keys(uint64_t mask) { (void)mask; return 0; }
uint32_t dm_ui_gen(void) { return generation; }
int dm_ui_unstable(void) { return unstable; }
uint64_t dm_wref_get(dm_wref *ref) { return ref->w; }
const char *dm_ui(const char *key) { return key; }
const char *dm_str(uint8_t *base, const char *key) { (void)base; (void)key; return "Build %d"; }
static void widget(uint8_t *w, const char *name) { *(const char **)(w + 8) = name; w[0x50] = 1; }

int main(void) {
    dm_sync_badge state = {0};
    assert(dm_sync_badge_get(&state, 0) == DM_SYNC_BUILD);
    dm_sync_badge_transfer(&state, DM_SYNC_UPLOAD);
    dm_sync_badge_finish(&state, 1, 100);
    assert(dm_sync_badge_get(&state, UINT64_C(2000000099)) == DM_SYNC_COMPLETE);
    assert(dm_sync_badge_get(&state, UINT64_C(2000000100)) == DM_SYNC_BUILD);
    dm_sync_badge_transfer(&state, DM_SYNC_DOWNLOAD);
    dm_sync_badge_finish(&state, 1, 100);
    dm_sync_badge_begin(&state); dm_sync_badge_transfer(&state, DM_SYNC_UPLOAD);
    assert(dm_sync_badge_get(&state, UINT64_C(9000000000)) == DM_SYNC_UPLOAD); // 旧完成提示的过期时间不能结束新上传。 | Old expiry cannot end a new upload.
    dm_sync_badge_transfer(&state, DM_SYNC_VERIFY);
    assert(dm_sync_badge_get(&state, 0) == DM_SYNC_VERIFY);
    dm_sync_badge_group_finish(&state, DM_SYNC_CHARACTER_COMPLETE, 100);
    dm_sync_badge_finish(&state, 1, 200);
    assert(dm_sync_badge_get(&state, UINT64_C(2000000099)) == DM_SYNC_CHARACTER_COMPLETE);
    assert(dm_sync_badge_get(&state, UINT64_C(2000000100)) == DM_SYNC_BUILD);
    dm_sync_badge_group_finish(&state, DM_SYNC_STASH_COMPLETE, 100);
    assert(dm_sync_badge_get(&state, 101) == DM_SYNC_STASH_COMPLETE);
    dm_sync_badge_transfer(&state, DM_SYNC_UPLOAD);
    assert(dm_sync_badge_get(&state, UINT64_C(9000000000)) == DM_SYNC_UPLOAD);
    dm_sync_badge_finish(&state, 0, 0); assert(state.phase == DM_SYNC_BUILD);
    dm_sync_badge_finish(&state, 1, 0); assert(state.phase == DM_SYNC_BUILD); // 未发生传输时不显示完成。 | No transfer, no completion.
    const dm_sync_phase typed[] = {DM_SYNC_CHARACTER_UPLOAD, DM_SYNC_STASH_UPLOAD, DM_SYNC_CHARACTER_DOWNLOAD, DM_SYNC_STASH_DOWNLOAD};
    const char *keys[] = {"dmSyncCharacterUpload", "dmSyncStashUpload", "dmSyncCharacterDownload", "dmSyncStashDownload"};
    for (unsigned i = 0; i < sizeof typed / sizeof typed[0]; i++) {
        dm_sync_badge_begin(&state); dm_sync_badge_transfer(&state, typed[i]);
        assert(dm_sync_badge_get(&state, 0) == typed[i]);
        assert(!strcmp(sync_caption(typed[i]), keys[i]));
        dm_sync_badge_transfer(&state, DM_SYNC_VERIFY); dm_sync_badge_finish(&state, 1, 100);
        assert(dm_sync_badge_get(&state, 101) == DM_SYNC_COMPLETE);
    }
    dm_build_tap tap;
    dm_build_tap_begin(&tap, 30, 40); dm_build_tap_move(&tap, 36, 48); assert(!tap.cancelled);
    dm_build_tap_move(&tap, 37, 48); dm_build_tap_move(&tap, 30, 40); assert(tap.cancelled);

    uint8_t *base = calloc(1, 0x2f06000);
    uint64_t root[32] = {0}, menu[32] = {0}, build[32] = {0}, note[32] = {0}, modal[32] = {0};
    widget((uint8_t *)menu, "MainMenuPanel"); widget((uint8_t *)build, "TouchBuild");
    widget((uint8_t *)note, "TouchUpdNote"); widget((uint8_t *)modal, "ConfirmationDialog");
    uint64_t children[] = {(uint64_t)build, (uint64_t)note}, panels[] = {(uint64_t)menu, (uint64_t)modal};
    *(uint64_t *)((uint8_t *)root + 0x58) = (uint64_t)panels; *(uint64_t *)((uint8_t *)root + 0x60) = 2;
    *(uint64_t *)((uint8_t *)menu + 0x58) = (uint64_t)children; *(uint64_t *)((uint8_t *)menu + 0x60) = 2;
    ((uint8_t *)modal)[0x50] = 0;
    int32_t *br = (int32_t *)((uint8_t *)build + 0x70), *nr = (int32_t *)((uint8_t *)note + 0x70);
    const int sizes[][2] = {{1280,720}, {2532,1170}, {1920,1080}}; // iPad 界面沿用已有的 16:9 视图。 | iPad UI uses its existing 16:9 view.
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        *(int32_t *)(base + 0x211da38) = sizes[i][0]; *(int32_t *)(base + 0x211da3c) = sizes[i][1];
        float width = (float)sizes[i][0] * 2160 / sizes[i][1], rect[4];
        br[0] = i == 1 ? 310 : 79; br[1] = 2046; br[2] = 420; br[3] = 60;
        nr[0] = br[0] + 341; nr[1] = 2046; nr[2] = 1500; nr[3] = 60;
        publish_build_rect(base, (uint64_t)root, (uint64_t)menu, (uint64_t)build);
        assert(dm_update_build_rect(rect));
        assert(dm_build_rect_contains(rect, (br[0] + 50) / width, 2070 / 2160.0f));
        assert(!dm_build_rect_contains(rect, (nr[0] + 1) / width, 2070 / 2160.0f));
        generation++; assert(!dm_update_build_rect(rect)); // 游戏界面重建后旧矩形立即失效。 | Rebuilt guest UI invalidates old snapshots immediately.
        pad = 1; br[0] = width - 420 - 79; br[1] = 60; nr[1] = 130;
        publish_build_rect(base, (uint64_t)root, (uint64_t)menu, (uint64_t)build);
        assert(dm_update_build_rect(rect) && dm_build_rect_contains(rect, (br[0] + 200) / width, 90 / 2160.0f));
        pad = 0;
    }
    float r[4];
    for (int reason = 0; reason < 5; reason++) {
        ingame = reason == 0; busy = reason == 1; unstable = reason == 2;
        ((uint8_t *)modal)[0x50] = reason == 3; ((uint8_t *)build)[0x50] = reason != 4;
        publish_build_rect(base, (uint64_t)root, (uint64_t)menu, (uint64_t)build);
        assert(!dm_update_build_rect(r));
    }
    free(base);
    puts("BUILD_SYNC OK: completion clock, tap cancellation, safe areas, pad layout, adjacent update notice and hidden/rebuilt UI");
}
