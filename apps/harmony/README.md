# XDRemux 鸿蒙原生版

**当前版本：0.5.4** · 需要 HarmonyOS 7（API 26）及以上

[下载鸿蒙原生版 0.5.4](https://github.com/BeetMan/XDRemux-Flutter/releases/tag/harmony-v0.5.4) · Flutter 跨平台版：[最新版本](https://github.com/BeetMan/XDRemux-Flutter/releases/latest)

[问题反馈](https://github.com/BeetMan/XDRemux-Flutter/issues) · [构建与安装](BUILDING.md) · [开发计划](../../docs/plans/harmony-native.md)

**让照片跨越设备，也保留继续创作的可能。**

XDRemux 鸿蒙原生版是一款面向 HarmonyOS 的照片格式转换工具，采用 ArkTS / ArkUI 构建原生界面，搭配 Rust 图像处理引擎，将照片导入、浏览、信息查看、转换与导出整合到一个应用中。

它支持将 OPPO、一加、realme 拍摄的 ProXDR 照片转换为标准 HDR HEIC，并根据后续使用场景选择「OPPO 兼容」或「Apple 标准」输出。原生版还提供了华为照片识别、符合条件的华为人像转换、Apple 摄影风格数据写入，以及动态照片拆分和 Live Photo 配对等能力，让不同设备拍摄的照片拥有更多跨平台使用方式。

<img width="1320" height="2232" alt="image" src="https://github.com/user-attachments/assets/12e107f2-1c13-4bd3-a8dc-77277cb77919" />

应用围绕 **图库、队列、互传、设置** 四个 Tab 展开：在图库中浏览和处理单张照片，在队列中管理批量任务，在互传中与同一 Wi-Fi 下的设备收发照片，在设置中调整默认转换选项。界面采用鸿蒙原生组件，并在支持的系统上呈现沉浸式导航与材质效果。

> 原生版的功能和设备兼容性仍在持续完善。Apple 摄影风格、人像及 Live Photo 等能力包含实验性实现，实际效果以照片结构、系统版本和目标设备为准。

## Flutter 版：共享转换核心的跨平台版本

除鸿蒙原生版外，XDRemux 的 Flutter 跨平台版本见[最新发布](https://github.com/BeetMan/XDRemux-Flutter/releases/latest)，覆盖 Windows、macOS、Android、iOS 和 HarmonyOS（Flutter 引擎）。

原生 0.5.4 使用与 Flutter 0.4.7 相同的 Rust 0.4.7 转换核心。核心包含 ProXDR 转标准 HDR HEIC、OPPO 兼容与 Apple 标准、符合条件的人像转换、摄影风格与动态照片处理能力。本轮新增与 Flutter 版共用的局域网互传（LocalSend），并纳入开启摄影风格时 Live Photo 配对失败的修复。两端的界面、预览和导出接入独立；Flutter 的 iOS PhotoKit 保存、编解码诊断 UI，以及可选 libheif 解码扩展不等同于鸿蒙原生版已接入。

在 HarmonyOS 上可选择 ArkUI 原生交互；需要在桌面或其他移动平台处理照片时，可选择 Flutter 版。[原生 0.5.4 更新说明](RELEASE_NOTES_v0.5.4.md)列出了本轮变化和使用范围。

## 图库：从浏览照片开始

图库是应用的主要入口。通过系统照片选择器导入照片后，应用会将所选原图复制到本地私有存储，并以三列网格展示。已导入的照片可以在应用重启后继续浏览，无需每次重新选择。

点击照片即可进入大图详情。详情页支持左右切换照片、双指缩放和双击放大，方便查看画面细节；在支持的照片和设备上，还可以按住照片查看 SDR 画面，松开后恢复 HDR 显示，直观比较高光与亮度表现。

<img width="1320" height="2232" alt="image" src="https://github.com/user-attachments/assets/180a5c9b-f275-4025-a3a3-138cc04d8e07" />

照片信息与转换操作集中在可展开的底部面板中。你可以查看文件格式、图像尺寸、HDR 类型，以及照片中已有的相机型号、拍摄时间、曝光、光圈、ISO、焦距等信息，了解这张照片的来源和可用能力。

<img width="1320" height="2232" alt="image" src="https://github.com/user-attachments/assets/bfc6b893-6351-4b8e-aafd-731aba192e5e" />

**每张照片都可以拥有独立的转换设置。** 应用会根据照片识别结果显示可用的输出模式与功能选项。你可以直接转换当前照片，也可以先加入队列，稍后统一处理；单张照片的设置会随对应任务保存，方便在同一批照片中采用不同的处理方式。

顶栏会显示拍摄设备型号与识别到的模式，支持识别 OPPO 拍摄的各种模式、华为人像模式、本软件转换后的模式等。

<img width="3645" height="1327" alt="image" src="https://github.com/user-attachments/assets/d441806d-02f7-4a47-b9a8-774fde7d0eba" />

图库中的转换会生成新文件并保留原图。转换结果保存在应用本地图库，可通过详情页分享按钮分享文件；队列中的转换结果可通过导出选择保存位置。

## 队列：集中管理批量转换

队列用于管理多张照片的转换任务。你可以从文件选择器添加照片，从图库中加入单张或全部照片，也可以通过系统分享将支持的 HEIC、HEIF、JPEG 图片交给 XDRemux 处理。

<img width="1320" height="2232" alt="image" src="https://github.com/user-attachments/assets/21f80d19-7794-4ee2-98ed-c159c579bb4a" />

队列按「全部」「待处理」「已完成」「失败」分类展示任务。每个项目会显示处理状态、使用的转换模式和运行进度，便于快速找到尚未处理的照片、查看转换结果，或定位失败原因。

批量转换采用串行处理。一张照片转换失败后，后续待处理任务仍可继续；失败项目可以重新加入处理，已完成项目也可以调整设置后重新转换。如果重新转换失败，应用会保留上一次成功结果，便于继续导出。

任务记录会保存到本地，重启后可以恢复队列中的项目及已有结果。当前转换需要应用保持前台；停止操作会在当前任务结束后阻止后续任务启动，重启应用后也需要手动开始后续处理。

完成的照片支持单独导出，也可以批量导出尚未导出的结果。队列管理区域还提供存储查看、缓存清理与最近批量导出记录，方便管理应用内的处理文件。

对于识别为 Motion Photo 的照片，队列详情还提供动态照片处理入口：

- 查看可读取的视频尺寸、时长、编码和音轨信息。
- 拆分静态照片与视频资源，并分别导出。
- 对符合条件的照片生成 Live Photo 配对文件，成对导出 HEIC 与 MOV，或导出 / 分享为 `.pvt` 包（`<名称>.pvt.zip`，在 Mac 上解压后「照片」可导入为一张 Live Photo）。在图库对动态照片点「转换单张」会在队列中单独转换并直接进入这些操作。

Live Photo 的实际导入、播放和声音表现仍需在目标设备上验证。

## 互传：在局域网内收发照片

「互传」与 LocalSend 协议兼容，可以和同一 Wi-Fi 下运行 LocalSend 或 XDRemux 的手机、电脑直接互传，不经过云端。

- **发送**：点选附近设备即可发送；可以从相册选择照片，也可以在队列详情里把转换结果「发送到其他设备」。找不到设备时会自动扫描网段，也可以手动输入对方 IP。
- **接收**：手动打开「可被发现」后才会接收，每次有人发来文件都需要你确认。打开「互传」页就能看到收件箱；收件箱显示预览，iPhone 发来的实况照片（同名照片 + MOV）和 `.pvt.zip` 显示为一张实况照片，可以直接加入转换队列，或存入图库、存入相册、分享。
- 接收开启后可以切到其他页面继续接收；应用切到后台时停止。传输过程中屏幕保持常亮。

## 设置：选择照片的输出方式

设置页用于调整后续任务默认使用的转换选项。你可以先编辑设置，再明确保存，也可以取消修改或恢复默认值。保存后的设置会在应用重启后保留；正在转换的任务继续使用启动时的参数。

应用提供两种主要输出模式：

| 输出模式 | 适用场景 |
|---|---|
| **OPPO 兼容** | 面向 OPPO、一加、realme 图库使用，可配置兼容策略及相机附加信息的保留方式。 |
| **Apple 标准** | 面向 Apple 照片及标准 HDR 工作流，并可按照片条件写入摄影风格或人像编辑数据。 |

Apple 相关选项包括：

- **摄影风格数据**：为支持的照片写入可继续调整的摄影风格数据。
- **摄影风格 3（质感 + 颗粒）**：在基础摄影风格之外，加入用于支持设备上质感与颗粒编辑的数据。
- **人像数据**：对具备可用景深信息且结构受支持的照片，生成可供 Apple 照片继续编辑的人像数据。

这些选项用于生成可继续编辑的照片文件。人像转换需要源照片提供可用的景深信息，应用会根据照片条件决定可用功能。

原生版也提供了符合条件的华为人像照片向 Apple 人像转换的路径，并支持在该路径上追加摄影风格。对于已兼容 Apple 的华为 HDR 照片，可保存独立静帧或按条件附加风格数据。

高级设置中提供「严格 ISO 兼容」选项，用于特定标准兼容性测试；普通使用建议保持默认配置。

## 开始使用

1. 在「图库」中导入照片，或通过文件选择、系统分享添加到「队列」。
2. 查看照片信息，选择输出模式及需要的功能。
3. 直接转换单张照片，或在队列中开始批量转换。
4. 转换完成后导出结果；动态照片可按条件拆分资源或导出 Live Photo 配对文件。

当前发布包为未签名 HAP，需要通过 DevEco Studio 等方式完成本地签名与安装。建议保留原始照片，并先用少量样本确认目标设备上的 HDR、摄影风格、人像和实况照片效果。

欢迎反馈使用问题，并附上设备型号、系统版本、转换选项与可供复现的原始样本，帮助原生版逐步完善。

## 开发与技术文档

- [构建与验证](BUILDING.md)：Rust 库准备、DevEco 构建、本地签名与 HAP 校验。
- [开发说明（英文）](#development-notes)：各版本的同步记录、队列与持久化设计、主机测试。
- [鸿蒙原生开发计划](../../docs/plans/harmony-native.md)：开发阶段与验证记录。
- [技术文档索引](../../docs/README.md)：共享 Rust 引擎、照片容器、摄影风格与人像管线。

原生工程位于 `apps/harmony/`，复用 `xdremux/rust/` 图像处理引擎。应用使用独立包名 `io.github.beetman.xdremux.arkui`，可与 Flutter 版共存。发布 HAP 保持未签名，设备测试使用 DevEco 本地签名。

---

## Development notes

This is the HarmonyOS native app for the existing Rust bridge. Its Gallery tab is a three-column XDRemux local library: users import selected photos through PhotoViewPicker, the app physically copies originals into persistent private storage, and tapping a tile opens the oversized detail card with format, dimensions, EXIF information, classification, and conversion controls. The app does not request `ohos.permission.READ_IMAGEVIDEO` or enumerate the device library. Gallery and queue imports both copy each selected URI into the app sandbox before Rust reads it; the queue retains its API 26 CURRENT-original and high-resolution HEIC options. The top navigation keeps Gallery, Queue, and Settings on the left and places Gallery's Import action on the right. The app uses a transparent immersive status bar and HDS Navigation detail title bar with adaptive material. It also receives supported HEIC/JPEG shares into sandbox files, runs a bounded foreground conversion queue, exports completed results through one serial multi-file save session, and can inspect and split Motion Photos, create eligible Live Photo pairs, and export paired HEIC/MOV files. Settings and queue recovery stay in same-page panels so opening them does not destroy the queue session.

## Native 0.5.4 release (2026-11-07)

The native branch merges main `ce35efd`, so the shared Rust core is `0.4.7` (same as Flutter v0.4.7, including the Live Photo MakerNote fix for styled stills). Native app metadata is `0.5.4` / code `50400`; the `.arkui` identity and queue/settings schemas are unchanged. New: the 互传 tab (LocalSend device transfer, described below), Settings → 开源许可 with the GPL-3.0-only notice and the XDRemux, x265 and LocalSend license texts, and the `INTERNET` / `GET_NETWORK_INFO` permissions. See [0.5.4 release notes](RELEASE_NOTES_v0.5.4.md).

## LocalSend device transfer (experimental)

互传 is the third main tab (图库 / 队列 / 互传 / 设置), styled like the queue page: Send/Receive chips in the title bar, summary cards and queue-style item cards. It runs on the shared LocalSend adapter (`crates/xdremux-transfer*`, vendored LocalSend protocol, Apache-2.0; see `crates/xdremux-transfer/UPSTREAM.md`). `transfer_bridge.cpp` exposes the poll-only C ABI 1.3; `ets/transfer/TransferModel.ts` applies poll records, `TransferController.ts` correlates results, `TransferInbox.ts` holds inbox grouping, `.pvt.zip` validation, naming and subnet-scan rules (host tests: `tests/transfer_*_test.mjs`), and `TransferPanel.ets` is the tab.

- Receiving (port 53319) starts only from the toggle and keeps running across tabs; sending to a queue item's 发送到其他设备 or picked photos starts it too. Moving the app to the background stops it (pickers and share sheets opened by the tab do not). Pending offers show on the tab label and the Receive chip.
- Send: tap a device to send (no fingerprint screen), pick photos, or connect to a typed IP; when multicast stays quiet for 3 s the /24 is scanned on 53319/53317. A cached Live Photo pair goes out as HEIC + MOV under the original name.
- Receive: offers wait for 接收全部 / 拒绝; this device's name is editable and its addresses are listed under 对方找不到本机？. The inbox shows previews, groups a same-session HEIC + MOV as one Live Photo and unpacks `.pvt.zip`. The round + adds a photo to the conversion queue (through a local-gallery copy); the card menu offers 存入图库, 存入相册 (photo + video for Live Photos), 分享 and 删除. The screen stays on while a transfer runs.

Verified on a Pura X View (HarmonyOS 7.0.0.111) against LocalSend 1.18.2 on macOS and the crate's test client: discovery, receive with Live Photo grouping and previews, queue import, manual IP connect and send. Not yet verified on a device: 存入相册, 分享, picking photos, and subnet-scan discovery. The app requests `ohos.permission.INTERNET` and `GET_NETWORK_INFO`.

## Native 0.5.3 release (2026-10-31)

The native branch merges main `60b2b48` and `release/0.4.6-prep` (`c649570`), so the shared Rust core reports `0.4.6` (main already carried every 0.4.6 code change; the prep branch only adds the version bump). Native app metadata is `0.5.3` / code `50300`; the `.arkui` identity and queue/settings schemas are unchanged. New native features: Live Photo export/share as a stored `<stem>.pvt.zip` (new `livePhotoBundleMake` N-API call over `xdremux_make_live_photo_bundle`), Gallery "convert single" of an Apple-mode Motion Photo runs only that item through the queue, Live Photo exports are named after the original photo, and Photographic Styles 2 results can be paired as Live Photos (main #51). Fixes: taps on the expanded gallery info/settings panel no longer reach the hidden thumbnail strip, and the Styles toggles are named Photographic Styles 2 / 3. See [0.5.3 release notes](RELEASE_NOTES_v0.5.3.md).

This release was built on macOS (Apple Silicon) with DevEco Studio 26.0; see [BUILDING.md](BUILDING.md) for the macOS commands.

## Native 0.5.2 release (2026-10-25)

The native branch synchronizes main `ebabc301` and its unreleased Rust `0.4.5` core. Native app metadata is `0.5.2` / code `50200`; the `.arkui` identity, queue/settings schemas and gallery cancellation fix are preserved. The relevant core updates are JPEG HDR version fallback, RGB ICC profile preservation and JPEG HDR inspection diagnostics. Flutter layout, Linux packaging and iOS thumbnail changes are not native UI features.

Build an unsigned **debug-mode HAP** with the release-optimized core from the existing `build_ohos.sh`, following [BUILDING.md](BUILDING.md). See [0.5.2 release notes](RELEASE_NOTES_v0.5.2.md) for validation scope. The independent `harmony-v0.5.2` release contains the verified Debug unsigned HAP and SHA256SUMS. It preserves the Flutter Latest release; `harmony-v0.5.1` and its existing assets remain unchanged.

## Native 0.5.1 release (2026-10-22)

Native `0.5.1` / code `50100` synchronizes the shared Rust `0.4.4` core at main `6c34ed42` and retains the gallery inspection-cancellation fix. The `.arkui` bundle identity and queue/settings schemas remain unchanged. See [release notes](RELEASE_NOTES_v0.5.1.md) for scope and signing instructions. The release uses the independent `harmony-v0.5.1` tag and an unsigned HAP; it does not use the Flutter `v*` tag workflow or replace the cross-platform Latest release.

The following synchronization entries are historical build records.

## Main synchronization (2026-10-16)

This branch merges `origin/main` at `9ee2431f` while preserving the native README/screenshots, ArkUI app, `.arkui` identity and `0.5.0-alpha1` / code `50001`. Shared-core updates include OPPO front-camera portrait depth, Huawei Motion Photo still isolation, JPEG HDR metadata/color-space handling, Apple MakerNote preservation, and Live Photo source/output safety. Native-specific still-extraction FFI and Apple editing metadata inspection remain available.

The optional `libheif-decoder` sources are synchronized but are not enabled or bundled for OHOS. The native app keeps system image rendering and its existing paired document-export flow; Flutter-specific UI, PhotoKit export and runtime diagnostics are not native UI additions.

Validation: Rust workspace tests passed (core 226 passed / 3 ignored, host FFmpeg encoder fallback); six opt-in Huawei corpus tests passed; all 16 native Node suites, five HAP verifier tests and the C++ PS3 helper passed. Host FFI version/classification smoke released Rust allocations with their matching free functions. The existing `build_ohos.sh` rebuilt the OHOS core, the staging helper copied it into the app, and `devecocli build --product default --build-mode release` plus unsigned HAP verification passed. No device installation or new Apple Photos acceptance was performed for this sync. Evidence and the unsigned HAP are in the external `harmony-native/main-sync-20261016/` directory.

## Build

Run these commands from the repository root in PowerShell. Always pass the path of an already-built OHOS core explicitly; this helper stages that file and the matching DevEco C++ runtime into the ignored `entry/libs/arm64-v8a` directory and does not rebuild or modify the Rust core.

```powershell
$core = 'C:\path\to\existing\libxdremux_core.so'
.\tools\ohos\prepare_harmony_native.ps1 -CorePath $core
Set-Location .\apps\harmony
devecocli build --product default --build-mode debug
```

When no local signing profile is selected, the unsigned HAP is written to `entry/build/default/outputs/default/entry-default-unsigned.hap`. The app is displayed as `XDRemux`, with version name `0.5.4` and version code `50400`. The project targets arm64 devices and uses the independent bundle ID `io.github.beetman.xdremux.arkui`. Use local DevEco signing for device tests and leave release packages unsigned.

The local gallery index is `filesDir/xdremux-gallery/library.json`; imported originals live under `filesDir/xdremux-gallery/items/`. Queue-owned inputs remain separate under the queue sandbox. Import copies are committed to the index only after the copied file is verified, and the index is replaced atomically.

The gallery remains in the app's persistent private sandbox. A future task may let users choose a managed folder through the system document picker; if added, keep copying selected content into the app sandbox before inspection or passing a path to Rust. External-folder selection is deferred for now.

The historical code40011 signed test HAP uses the `.native` bundle ID. The current `.arkui` app has a separate identity and a matching local DevEco test-signing profile; it does not inherit `.native` app data. Release artifacts remain unsigned.

DevEco signing material is machine-specific and must remain untracked. Use local signing only for device-test packages; release artifacts remain unsigned. Do not reuse the Flutter application's identity or credentials.

## System image sharing

The `sendData` Share Kit target accepts supported file-backed HEIC/HEIF/JPEG image records. The ability reads shared records during `onCreate` or `onNewWant` and promptly copies each temporary URI into the app sandbox before queue import or Rust calls. Unsupported records are ignored with a visible count. The queue journal owns a copied file only after its durable checkpoint; restart reconciliation keeps a ready inbox copy protected until that handoff completes. If a temporary grant expires before copying, the failed task cannot retry the old URI: select that task and use **重新选择失效分享图片** to choose a replacement into the same queue item.

## Device smoke

After configuring new-app signing, list devices and run the module with the DevEco CLI. The run command performs the build using the configured signing profile:

```powershell
devecocli device list
devecocli run --module entry --device <device-serial>
```

P3 device verification should select several real files, including one known-invalid input, and check that valid items continue when one item fails. Check start/resume, stop-after-current, retry, reconvert after changing the global mode, per-item progress, details, single export, and multi-file export. For batch export, verify shuffled picker URI order maps by the unique requested filename, one failed target does not block later targets, stop-after-current leaves later items canceled, and a journal failure reports physical writes separately from queue state. Select a converted item and request Motion Photo information on demand; check an ordinary photo, a supported Motion Photo, and an unreadable/invalid input, then switch items and confirm each result stays with its photo. The displayed ranges and optional video/audio details must remain readable. Compare source bytes with the materialized sandbox file before conversion. Confirm a failed reconversion still labels and exports its previous successful sandbox result. The settings checklist should change each supported option, save, reopen the panel, and restart the app to confirm persistence; then verify a running conversion keeps its start-time snapshot while a later item uses the newly saved settings. A signed-device P3 run is not part of the unsigned build evidence.

## Source main synchronization

This worktree merged `origin/main` at `747ad8ffd4e59ecc7ea2c65feb068bb989d1f692` in merge commit `e65c970` after checkpoint `82bbd04`. The source tree therefore contains the newer mainline Rust work, including the SDR photographic-style path, PS3 texture/grain and semantic-matte work, and EXIF orientation fixes.

The previously verified main-sync HAP used staged core `D2C6BBA679846718124FE77BDDDD0276367B9EFB810A789C97714F273B828A80`; that artifact and its old-feature limitation are historical. The current code40009 build reuses staged core `B994FB28E379C8C43B40BB952B7276EF75E38E5D40DC38DCC8E579C9F81CA63D` (4,321,800 bytes), including the native Photographic Styles 3 post-processing path.

The previous code40008 unsigned HAP (5,448,800 bytes, SHA-256 `FE8F31DB6C151A73F794124061B49BC216F7BDA03EDB0F4E08FD43BA54994F67`) and the earlier post-merge main-sync artifact are kept outside the repository, under the `harmony-native/` evidence directory (`p3-styles3/` and `main-sync/`), for historical comparison.

The user has confirmed the code40007 basic workflow works; that confirmation does not cover every error branch, boundary, cache/lifecycle path, or device compatibility case.

## Queue behavior and lifecycle

The queue journal is `filesDir/queue.json`; writes go to a sibling `.tmp`, verify the complete UTF-8 byte count, flush and close, then atomically rename the temporary record. Progress ticks stay in memory, while item creation, input ownership, attempt state, result publication, export state, deletion intent, and record deletion are checkpointed. A write failure is latched, stops later scheduling and maintenance, and must be explicitly retried before the queue can continue.

On startup the app validates the schema, stable IDs, decimal-string `u64` values, mode/config snapshots, input/result ownership, and sandbox file status before restoring the queue. A running or cleanup-pending item never resumes native work automatically: it becomes a visible manual-retry or cleanup record. A pending item whose sandbox input is missing becomes a visible failed item that must be re-imported. A malformed or unsafe journal is retained for an explicit quarantine/recovery action, and no orphan cleanup runs while recovery is required. The journal is sized for the bounded picker selection rather than split across Preferences keys.

The UI offers OPPO and Apple output modes plus the Rust-backed OPPO compatibility, camera-tail, strict ISO, Apple Photographic Styles, Apple Photographic Styles 3, and Apple Portrait data options. The gallery's conversion settings are scoped to the selected photo and show only formats/features supported by its inspected ProXDR data; queue records preserve that photo-specific mode through restart and reconversion. “Convert single” runs only that photo and leaves other pending queue items untouched, while “Add to queue” stores it without starting the queue. Photographic Styles 3 automatically enables the 2023 styles graph and uses a stable per-input seed for its texture metadata; switching back to OPPO clears all Apple feature flags. The values are captured as the exact five `ConvertConfig` bytes plus a separate bridge-only PS3 option for each item. Apple output and any Apple feature use `oppoCompat=0` and `oppoCameraTail=0`; the default OPPO output uses `oppoCompat=2` and `oppoCameraTail=255`. Each item receives a stable ID and moves through pending, running, succeeded, or failed states. Conversion is serial; a failed item does not block later pending items, and stop requests take effect after the active native call settles. Retry of an import failure repeats URI materialization, details, and classification before conversion. Queue items without a photo-specific override capture the current committed settings when conversion starts; all reconversions retain the last successful result if a Rust or PS3 post-process attempt fails.

The restored session is foreground-only. `onPageHide` detaches the UI and requests stop-after-current; `onPageShow` reattaches without automatically resuming. Queue records are not background work and are not automatically resumed after process restart. Removing an item persists deletion intent before cleaning its owned sandbox paths, then removes the record only after cleanup succeeds. Cleanup covers old outputs and temporary files from previous attempts, never the picker source URI or a successfully exported destination. A cleanup failure remains a retryable removal record. The explicit cache maintenance action validates the root and `inputs`/`outputs` directories, refuses symlinks or unsafe paths, and deletes only recognized unreferenced app artifacts; it is disabled during any import, conversion, export, settings save, recovery, or journal write.

Batch export snapshots only usable, unexported results and locks those queue items for the picker and serial FD copies. The selected target URIs are matched by their unique final filename, regardless of returned array order; every queue source and sandbox path is protected from becoming a target. API18 may pre-create empty targets, so a non-empty target is rejected and no document-provider URI is deleted on failure. A successful FD copy is recorded separately from the later queue journal checkpoint; a journal failure stops later copies while retaining the physical-export fact and sandbox result. Picker cancellation and foreground teardown leave later items explicitly canceled, and the batch is never resumed automatically after restart.

Motion Photo inspection is an explicit action for the currently selected, already imported photo. The panel reports an ordinary photo or unsupported structure, recognized Motion Photo ranges and available video/audio information, or a clear inspection error. Recognized Motion Photos can be split into still/video resources or paired with an Apple HEIC conversion from the same imported source. Inspection, split, and pair-generation caches are session-only.

## Persistent settings

`SettingsStore` uses the documented `@kit.ArkData` Preferences API with one JSON record (`schema=1`) under the native app's sandbox. The record stores the output mode, Rust OPPO compatibility value, camera-tail value, strict ISO flag, and all three Apple feature flags. A schema 1 record from before Photographic Styles 3 may omit that field; it migrates to `false`, while a present non-boolean value is rejected. Missing data uses the documented defaults: OPPO compatibility `2`, camera tail `255`, and all three flags `false`. Stored schema, enum ranges, and boolean types are checked before any value reaches N-API. Malformed data produces a visible warning and leaves the original record untouched.

Settings are edited as a draft. A successful `flush()` publishes the committed snapshot used by future queue items; failed saves restore the previous raw Preferences value, retain the draft for retry, and leave running items unchanged. Writes are serialized so an older asynchronous save cannot finish after a newer save. Restore defaults changes the draft and requires an explicit save. Each conversion retains its mode/config summary, so later settings changes cannot relabel an old result.

## ABI boundary

The Live Photo wrapper exposes the existing xdremux_make_live_photo and xdremux_live_photo_pair_valid functions asynchronously under the shared core mutex. The creation report is released with xdremux_free_string; pair validation returns u8.

The N-API bridge declarations mirror `xdremux/rust/src/lib.rs`: `xdremux_version` returns an owned string freed with `xdremux_free_string`; `xdremux_classify` returns `ClassificationResult` by value with six owned string pointers released with `xdremux_free_classification_result`; `xdremux_inspect_photo_details` returns an owned JSON string; and `xdremux_convert_with_progress` returns `ConversionResult` by value with three owned string pointers (`mode`, `family`, and `error_message`) released by `xdremux_free_result`. The arm64 static assertions in `entry/src/main/cpp/napi_bridge.cpp` guard the expected 72-byte classification and 48-byte conversion layouts. `u64` flags are exposed to ArkTS as `bigint` values.

## Deterministic queue tests

The controller tests exercise serialization, same-tick and double-start guards, single-item execution, photo-specific mode overrides, failure continuation, stop-after-current, defensive mode snapshots, retry/reconversion, missing-input rematerialization, detach/resume, cleanup failure boundaries, and remove/export locks. The persistence regression tests also cover photo-specific mode snapshots, immutable records, first-write failure latching and explicit retry, native-result retention when a result checkpoint fails, deletion intent ordering, progress-only updates, and restore waiting for an in-flight write. Run them from the repository root with Node 24 or newer:

```powershell
node --experimental-strip-types apps/harmony/tests/p2_queue_controller_test.mjs
node --experimental-strip-types apps/harmony/tests/p2_queue_controller_persistence_test.mjs
node --experimental-strip-types apps/harmony/tests/queue_persistence_test.mjs
node --experimental-strip-types apps/harmony/tests/queue_sandbox_test.mjs
node --experimental-strip-types apps/harmony/tests/settings_model_test.mjs
node --experimental-strip-types apps/harmony/tests/batch_export_edge_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_batch_export_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_motion_photo_model_test.mjs
node --experimental-strip-types apps/harmony/tests/motion_inspect_edge_test.mjs
node --experimental-strip-types apps/harmony/tests/motion_split_model_test.mjs
node --experimental-strip-types apps/harmony/tests/motion_split_edge_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_styles3_model_test.mjs
node --experimental-strip-types apps/harmony/tests/p3_live_photo_pair_test.mjs
node --experimental-strip-types apps/harmony/tests/share_import_model_test.mjs
```

The persistence and sandbox tests exercise the production queue codec/store and path policy through fake IO adapters, including malformed-record preservation, missing-file recovery, ownership isolation, symlink refusal, orphan cleanup, schema validation, exact Rust mappings, serial writes, and flush failure recovery. These tests do not prove Harmony picker, N-API, codec, Preferences framework integration, or device export behavior. Those require the signed-device checklist above.
## Motion Photo split (code40009)

The previous code40009 unsigned artifact (5,537,354 bytes, SHA256 `A80165677C2F709E29FEC1E6FAAA91EA1AEA4D7F6CCE33C3BE0955C7240A76CA`) is kept outside the repository, under the `harmony-native/p3-motion-split/` evidence directory together with its build and test evidence and the pending device checklist. It reuses the code40008 Rust core without rebuilding it.

After inspection identifies a Motion Photo, the details panel can split its still and video resources. Each attempt copies the materialized input to a unique scratch path and registers all candidate outputs before writing. Existing files or ownership conflicts stop the attempt without deletion. The split report must match exact candidate names, MIME-derived extensions, regular files, and expected byte lengths. Failures clean only that attempt and preserve previous successful split and conversion results; cleanup failures retain ownership for later task deletion.

Split results are cached by task and source input for this session. Restart requires reinspection and splitting again; previous files remain task-owned and are removed with the task. Each resource exports through a single save picker with source and sandbox URI-alias protection. Resource export does not mark the converted image as exported. The full video may contain multiple streams or vendor trailing data; a primary-video option appears only when Rust reports one. Live Photo pairing and gallery integration are outside this batch.

Twelve Node test files and the unchanged C++ PS3 helper regression passed for code40009. This is host-side validation, not device N-API, picker lifecycle, playback, or Apple Photos validation. code40008 and code40009 device checks remain pending; unsigned delivery is unchanged.

## Live Photo paired files (code40010, historical)

This section records the code40010 test build from before the `.arkui` identity existed: it used the bundle ID `io.github.beetman.xdremux.native` (distinct from the Flutter app's `io.github.beetman.xdremux`, so both could be installed side by side), versionCode 40010 and the staged Rust 0.4.2 core. The current app is `io.github.beetman.xdremux.arkui` at 0.5.4 (see Build above). The unsigned DevEco artifact (5,636,835 bytes, SHA256 `8ADAE2D6540500726C09E891897AE4032CEE2DF12504A2CAD21B962653A1B42B`) is kept outside the repository under the `harmony-native/p3-live-photo/` evidence directory. DevEco skipped signing because the project had no signing profile; sign locally in DevEco only for device testing.

Pair generation requires a currently identified Motion Photo and an Apple HEIC result whose persisted sourceInputPath exactly matches the current source. Older queue records may omit this field and remain exportable, but must be converted again before pairing. This prevents a newly imported Motion Photo from being combined with a stale successful result retained during preparation.

Each attempt allocates a unique source scratch file and flat HEIC/MOV candidates. All paths are checked for collisions, registered to the queue item, and durably saved before copying or calling Rust. The N-API calls run asynchronously under the existing core mutex. Rust's owned JSON string is released with xdremux_free_string; pair validation is invoked only after both output paths are confirmed non-empty regular files. Exact report paths, a UUID-shaped content identifier, output files, and Rust pair validation must pass before publishing the pair. Failure cleanup is limited to that attempt and keeps previous pairs and conversion output.

The session cache key contains task ID, current input path, and Apple result path; restart does not resume pair generation. Pair files remain queue-owned until task deletion. Paired export requests same-stem HEIC and MOV names from one save picker, maps returned URIs by decoded filename regardless of response order, and checks the complete target set against all source and sandbox aliases before opening a file. Copies are serial, each file reports its result, and partial success is visible. Pair export never changes the converted result's exportedUri.

Rust verifies that the two embedded identifiers match. This feature does not import the pair into the system gallery or claim Apple Photos playback compatibility. Host tests cover exact source binding and legacy records, ownership/persistence ordering, candidate collisions, malformed reports, native pair-validation failure, per-attempt cleanup, unordered picker URI mapping, alias rejection, and 1-of-2 serial export. All 13 Node tests and the C++ PS3 helper regression passed. The unsigned HAP manifest reports bundle `io.github.beetman.xdremux.native`, version `0.4.2` / code `40010`, API 18; its packaged Rust core hash matches code40009. Device picker/copy, gallery import, and Apple Photos playback remain unverified; see the external p3-live-photo device checklist.
