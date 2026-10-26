# WebDAV pack backend validation / 存档包后端验证

Validated on 2026-10-26 with Xcode 26.6, iOS SDK 26.5 and macOS SDK 26.5.

| Check / 检查 | Result / 结果 |
| --- | --- |
| New upstream branch / 新上游分支 | `codex/webdav-icloud-backend`, based on upstream `main` at `195ae11` |
| Local development branch / 本地开发分支 | `codex/local-build-webdav`; existing Prepared build customizations preserved |
| Shared sync regression / 共用同步回归 | 94 checks passed; two private stash-fixture groups skipped |
| WebDAV and lifecycle / WebDAV 与生命周期 | 32 tests passed on each branch |
| Local Prepared tooling / 本地 Prepared 工具 | 18 tests passed |
| iOS source/unit suite / iOS 源码与单元测试 | Passed on both branches; private native-binding fixtures and real-device receipts remain unavailable |
| Enabled builds / 开启后端的构建 | iOS and macOS Debug + Release passed on both branches |
| Default-off build / 默认关闭构建 | iOS Debug passed; no WebDAV classes/functions in the executable |
| Internationalization and source gates / 国际化及源码检查 | String-table, literal, native-widget write and mode-registration checks passed |
| Simulator / 模拟器 | Dedicated iPhone 17 Pro Max Simulator: actual settings UI; loopback probe, upload, download and byte equality passed |
| Native Mac / 原生 Mac | Isolated local build reached class selection with complete game resources; startup WebDAV listing completed |
| iPhone game flow / iPhone 游戏流程 | **UNRUN**: device unavailable; Simulator does not validate the guest small stack or real background suspension |
| Full game synchronization / 完整游戏同步 | **UNRUN**: actual gameplay, exit/save hook and background/quit sequence still require hands-on validation |

The HTTP suite exercises sidecars, first-use collision/local backup, backup failure, tombstones, Unicode names, shared stash inbox/base behavior, failed PUT/retry, lost MOVE response, bounded listing, invalid XML/origin, remote size, server digests, no upload readback, connection reuse, timeout reconstruction/late callback isolation, final publication verification and temporary staging cleanup. The lifecycle suite calls the actual commit callback and serial scheduler with a fake backend.

HTTP 测试覆盖附属文件、首次同名冲突及本机备份、备份失败、删除标记、Unicode 名称、共享仓库收件箱与基准、PUT 失败重试、MOVE 响应丢失、列表边界、异常 XML／来源、远端大小与服务器摘要、不读回上传、连接复用、超时重建与迟到回调隔离、发布后校验及暂存清理。生命周期测试调用真实提交回调与串行调度，传输部分使用假后端。

All network validation used a loopback fake WebDAV service and disposable saves. No real NAS was accessed. The initial native-game startup attempt used the small build-input RomFS rather than the complete game resources and crashed; the subsequent complete-resource local run reached class selection. This is not a claim that a complete game synchronization cycle has passed.

全部网络验证使用本机假 WebDAV 服务与临时存档，未访问真实 NAS。首次原生游戏启动误用了构建输入的小型 RomFS，出现崩溃；换用完整资源后，本地构建到达职业选择画面。完整游戏同步循环仍未验证通过。
