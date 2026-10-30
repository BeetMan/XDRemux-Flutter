# Apple Live Photo 包（.pvt）

> 对应代码：`xdremux/rust/src/live_photo_bundle.rs`（FFI `xdremux_make_live_photo_bundle` / `xdremux_live_photo_bundle_valid`）、`apps/flutter/lib/services/motion_photo_service.dart`（`composeLivePhoto(bundle: true)`）、`output_export_service.dart`（分享时打 zip）。
> 配对本身（MakerNote content identifier + MOV 重写）见 `live_photo.rs`；本页只讲把已配对的 HEIC + MOV 装进 `.pvt`。

## 1. 结构

`.pvt` 是 AirDrop、Telegram 等用来传一张 Live Photo 的**目录包**。UTI 是 `com.apple.private.live-photo-bundle`，它遵循 `com.apple.live-photo` 和 `com.apple.package`。只要目录名以 `.pvt` 结尾，macOS 的 Spotlight（`mdls`）就会识别成这个类型。

```
<名称>.pvt/
  <stem>.heic      带 Apple MakerNote 0x0011 content identifier 的静帧
  <stem>.mov       content identifier 相同的配对 MOV
  metadata.plist   XML plist：PFVideoComplementMetadataVersionKey = "1"（string）
```

参照样片：用户提供的 `IMG_3648_HDR10_Live.pvt`（iPhone 18 Pro / iOS 27.2，经 Telegram 传来，2026-10-30）。

- 包名和里面的文件名可以不一样（样片是 `IMG_3648_HDR10_Live.pvt/IMG_3648_HDR10_experimental.heic`）。但静帧和 MOV 的 stem 必须相同。
- `metadata.plist` 共 249 字节，末尾有换行。我们按字节原样写出。
- 样片的 MOV 主轨被 libx265 重编码成了 HDR10（PQ / BT.2020），属于用户的实验品。原生 iPhone Live MOV 的主轨是 BT.709 HEVC。我们**不重编码**，只按字节复制配对好的 MOV。

## 2. 写入规则（`write_bundle`）

1. 先用 `existing_pair_is_valid` 校验配对：两侧 content identifier 必须一致，否则拒绝。
2. 在同级的隐藏目录 `.<stem>.pvt.partial-<pid>` 里组装，组装完先用 `read_bundle` 自检。
3. 用 rename 换上去。已有同名包时，先把旧包改名为 `.old-<pid>`，换上新包后再删旧包；如果换失败就把旧包恢复。重试会整包替换，不会留下旧文件。
4. 源文件位于目标包内时拒绝，避免自己覆盖自己。
5. 里面的文件名统一用小写扩展名（`.heic` / `.mov`）。读取时扩展名不区分大小写，并忽略 `.DS_Store` 这类隐藏文件。

## 3. 应用行为

- 设置项「Live Photo 打包为 .pvt」（`ConversionConfig.livePhotoBundle`）**默认关闭**，关闭时行为和以前一样，输出同 stem 的 HEIC + MOV。
- 打开后：转换器仍然先把静帧写到原计划的 `<dir>/<stem>.heic`，合成时在临时目录配对，打包成 `<dir>/<stem>.pvt/`，最后删掉原位置那张没配对的静帧。`item.outputPath` 指向包里的 HEIC，`livePhotoMoviePath` 仍能找到包里的 MOV。
- 检查点里记录的是原计划路径。恢复时如果原路径不存在而 `<stem>.pvt/<stem>.heic` 存在，就改用包里的文件，并用 `xdremux_live_photo_bundle_valid` 校验。重新转换时会把路径还原到原计划位置。
- 保存：iOS 仍用 PhotoKit，以 `.photo` + `.pairedVideo` 写入包里的两个文件；Android 存两个独立媒体项，和以前相同。
- 分享（按平台，`sharesLivePhotoBundleDirectly`）：
  - iOS / macOS：直接把 `.pvt` 目录交给系统分享面板（iOS 走 `UIActivityViewController`，macOS 走 share_plus 的 `NSSharingServicePicker`），AirDrop 到苹果设备后就是一张 Live Photo，不打 zip。
  - Android / Windows / Linux / 鸿蒙：这些平台的分享面板只能发文件，不能发目录，所以先打成 `<名称>.pvt.zip`（deflate 等级 0，条目带 `<名称>.pvt/` 前缀），以单文件分享。鸿蒙原来不支持多文件分享，用这个方式也能发出去。

## 4. 验证记录（2026-10-30，macOS 27 / 照片 App）

| 用例 | 结果 |
|---|---|
| Rust 写出的 `.pvt`（OPPO「标准 1x」实况 → `xdremux_make_live_photo` → `xdremux_make_live_photo_bundle`，即 `examples/pvt_bundle.rs --from-source`）用 AppleScript 导入「照片」 | 导入为 **1 个**资产；按原件导出得到 `.heic` + `.mov` 两个资源，MOV 逐字节一致；源文件 SHA256 不变 |
| 已有的配对产物（`IMG_20261014_215647.jpg_iso.*`）打包后导入 | 同上，1 个资产，导出 2 个资源 |
| 用户样片 `IMG_3648_HDR10_Live.pvt` 只读校验 | `read_bundle` / `bundle_is_valid` 通过 |
| 用与 app 相同的参数打 zip，`ditto -x -k` 解压 | 得到 `.pvt` 目录，`mdls` 类型为 live-photo-bundle，校验通过 |
| 「照片」界面上的 `XDR_PVT_OPPO_std1x` | 用户肉眼确认：有实况标记，长按能播放（2026-10-30） |

**没验证**：
- 在 iOS / macOS 的 app 里直接分享 `.pvt` 目录（AirDrop、存到「文件」）的实机效果。
- iPhone 上经 AirDrop 或「文件」App 解压 zip 后能否直接存成实况。
- Android、Windows、鸿蒙上的实机分享。
- Flutter 端用真实文件跑的 `composeLivePhoto(bundle: true)`：macOS 的 `flutter_tester` 是 darwin-x64，加载不了 arm64 的核心库，所以 `test/live_photo_bundle_test.dart` 里的真实样片用例在本机会自动跳过，只在能加载核心库的主机上运行。

为验证往「照片」图库里导入了 3 个测试资产（`XDR_PVT_TEST_215647`、`XDR_PVT_E2E_215647`、`XDR_PVT_OPPO_std1x`），可以手动删除。
