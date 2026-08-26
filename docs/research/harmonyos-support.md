# 鸿蒙（HarmonyOS）支持研究

> 研究分支：`research/harmonyos`。调研时间：2026-08。结论状态：**Rust 核心 OHOS 构建已跑通；Flutter 引擎已在鸿蒙真机渲染（hello-world）**；待接入我们自己的 app。

## 0.7 真机里程碑（2026-08-26，PLR-AL50 / HarmonyOS 7.0.0.102 / API 26）

**Flutter hello-world 已在鸿蒙真机上运行**：签名 hap（正式包名 `io.github.beetman.xdremux`）安装成功，`aa start` 启动，Flutter Demo UI 完整渲染。

关键事实：

- flutter tool 能识别鸿蒙设备（`5BE0225520010754 • ohos-arm64 • API 26`），hdc 位于 `sdk/default/openharmony/toolchains/hdc.exe`
- 商用 HarmonyOS 设备**强制签名校验**（unsigned hap 报 `code:9568320 no signature file`）；DevEco 自动签名（华为账号）是唯一现实路径，生成的 debug profile 会注册设备 UDID
- 签名材料与包名绑定：改 bundleName 后必须在 DevEco 重新自动生成签名
- 商用机 HarmonyOS 7 的 API 是 26（比 DevEco 6.1.1 自带 SDK 的 API 24 还新）；oh-3.44.9-dev 的嵌入层目标 API 26，与真机代际吻合——后续可以重新评估 3.44 线
- 远程操控：`hdc shell power-shell wakeup` 唤醒；`aa start -b <bundle> -a EntryAbility` 启动；`snapshot_display -f ...jpeg` 截屏（注意只接受 .jpeg 后缀；Git Bash 要 `MSYS_NO_PATHCONV=1`）
- 锁屏时 aa start 报 10106102，需解锁

### 下一步（接入我们的 app）

- [x] `flutter create --platforms ohos .` 生成 ohos 目录（包名 `io.github.beetman.xdremux`，签名配置复制自 hello-world 项目）
- [x] pubspec 依赖适配：vendored 到 `apps/flutter/third_party/ohos/`（`tools/ohos/fetch_plugins.sh` 重建；**AtomGit 的 git 服务器不允许按 SHA fetch，pub 的 git ref 解析会错乱，只能用 path 依赖**）
- [x] notification_service 适配 flutter_local_notifications v19 位置参数 API
- [x] FFI 加 OHOS 分支（`Platform.operatingSystem == 'ohos'` 时按名加载 .so）；.so 放 `ohos/entry/libs/arm64-v8a/`（已 gitignore，`build_ohos.sh` 重建后手动复制）
- [x] **app 签名 hap 已在真机安装运行，首页 UI 正常**（PLR-AL50，HarmonyOS 7.0.0.102）
- [x] 文件选择交互验证通过（fluttertpc_file_picker 鸿蒙实现可用）
- [x] 保存图库打通（gallery_saver 走 PhotoAccessHelper，支持 .heic）——两个坑：插件必须在 `dependencies` 直接声明才进插件注册表（overrides-only 会编译过但 channel 未注册）；vendored 副本需删 `module:` 老标记 + 放宽 sdk 约束
- [ ] gal / share_plus / package_info_plus 无 OHOS fork（当前在鸿蒙上运行时缺失，不阻塞构建）
- [ ] flutter_foreground_task vendored 为 9.2.2（主线用 11）——**vendored path 依赖对所有平台生效，合入主线前必须评估版本回退影响**
- [ ] Rust FFI 端到端验证（完整转换流程）
- [ ] 真机回归完整工作流（水印恢复链路）

## 0.5 Spike 结果：Rust 核心 OHOS 构建（2026-08-25 完成，Windows + DevEco Studio）

**`libxdremux_core.so`（aarch64-unknown-linux-ohos）构建成功**：ELF 64-bit aarch64 动态库，3.73MB，23 个 `xdremux_*` FFI 导出齐全，依赖仅 `libc++_shared.so` + `libc.so`。宿主平台回归 123 测试全过。

新增资产：

- `xdremux/rust/build_ohos.sh`：一键构建脚本（x265 交叉 + Rust cdylib），默认使用 DevEco 安装的 NDK
- `build.rs`：OHOS 平台分支（见下述坑 1/3）
- `vendor/x265/build_ohos/libx265.a`：2.87MB（不入 git，脚本自动重建）

### Spike 中踩掉的四个坑（复现者必读）

1. **Rust OHOS 目标是 `os=linux, env=ohos`**：`CARGO_CFG_TARGET_OS` 拿不到 "ohos"，必须看 `CARGO_CFG_TARGET_ENV`。build.rs 平台分支因此用 env 判定
2. **DevEco 路径含空格**（`Program Files`/`DevEco Studio`）会炸 cc-rs 的 CFLAGS 拆分：默认用 8.3 短路径（`C:/PROGRA~1/Huawei/DEVECO~1/...`），可用 `OHOS_NATIVE` 覆盖
3. **cargo 的 `CARGO_TARGET_*` 环境变量名必须全大写**（`CARGO_TARGET_AARCH64_UNKNOWN_LINUX_OHOS_LINKER`），小写会被静默忽略；cc-rs 的 `CC_<target>` 则是小写下划线
4. **zstd 必须用 C 驱动编译（clang.exe）**：C++ 驱动在 Linux 目标上自动定义 `_GNU_SOURCE`，选中 zstd 的 glibc qsort_r 分支，而 OHOS musl 没有 qsort_r。C 驱动走 portable fallback（与 Android NDK 构建行为一致）

链接配置：musl 体系链 `c++_shared` + `m`（无 numa/pthread——musl 合入 libc，NDK 无 libnuma）；`-Wl,-Bsymbolic` 同 Android。产物需随包附带 NDK 的 `libc++_shared.so`（同 Android jniLibs 惯例）。

### 下一步 spike（Flutter 接入）

- [x] CPF-Flutter 引擎环境搭建与 hello-world hap 构建（见 §0.6）
- [ ] 引擎二进制分发方式核对（flutter_engine release 停在 3.27.0，高版本引擎随 flutter_flutter 仓 OBS 分发，已实测自动下载）
- [ ] 我们 app 的 pubspec 对接社区插件 fork（见 §1.3 表格；flutter_foreground_task 需降级 ^10 或换 fluttertpc 版本）
- [ ] .so 进 hap 的打包路径 + Dart FFI `DynamicLibrary.open('libxdremux_core.so')` 在 OHOS 的加载语义
- [ ] 签名收尾：DevEco 自动签名（华为账号）或修好手动 hap-sign-tool 证书链
- [ ] 真机/模拟器安装运行

## 0.6 Flutter OHOS 接入 spike（2026-08-25，Windows + DevEco Studio 6.1.1，无设备）

**结果：hello-world 的 unsigned debug hap 构建成功**（96MB，Flutter 3.41.10-ohos 引擎产物自动下载）。`flutter build hap` 全流程跑到签名步。

### 可行配置（实测）

```
Flutter fork: atomgit.com/CPF-Flutter/flutter_flutter @ oh-3.41.9-release
  （不要用 oh-3.44.9-dev：其嵌入层引用 autoFillManager.requestAutoFill 等
   API 26 新接口，而 DevEco 6.1.1 的 SDK 是 API 24，15 个 ArkTS 编译错误）
DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
flutter config --ohos-sdk "C:\Program Files\Huawei\DevEco Studio\sdk"
PATH 追加：
  C:\flutter-ohos\bin                    （fork 的 flutter）
  C:\tools\ohos-shim                     （ohpm.exe shim，源码 tools/ohos/ohpm-shim.c）
  DevEco Studio\tools\hvigor\bin          （hvigorw）
  DevEco Studio\jbr\bin                   （java，PackageHap 需要）
```

### 踩坑记录

1. **浅克隆拿不到版本号**：`--depth 1` 无 tag，Flutter 版本变成 0.0.0-unknown，pub 约束全炸。必须 `git fetch --deepen=2000 --tags` 让 `git describe` 能解析
2. **ohpm 裸调用**：fork 的 tool 在 Windows 裸调 `ohpm`（CreateProcess 不解析 .bat）。解法是 `tools/ohos/ohpm-shim.c` 编译成 ohpm.exe 放 PATH（直接转发到 `node pm-cli.js`，绕过 cmd 引号地狱）
3. **batch 递归炸弹**：在 Git Bash 里跑 `flutter build hap` 会触发 cmd "BATCH RECURSION exceeds STACK limits"（嵌套 bat 236 层）。**用 PowerShell/cmd 跑**，不要用 Git Bash
4. **签名**：hvigor 的 signingConfigs 拒绝明文密码（要 DevEco 加密形态 ≥32 字符）。无签名构建走通；hap-sign-tool 手动签名走通了 profile 签发（sign-profile），sign-app 的证书链校验（"cert chain file"）尚未通过——正式路线应该是 DevEco Studio 登录华为账号后自动签名（首次一次性配置）
5. 模板 compatibleSdkVersion 是 5.1.0(18)，DevEco 6.1.1 SDK 为 API 24——release 线引擎与其兼容

### 遗留

- 引擎与框架的对应版本管理（flutter_flutter 仓内含 engine/ 源码，构建时从 OBS 拉预编译产物）
- app 侧 pubspec 适配 + ohos 目录生成已验证可行（`flutter create --platforms ohos .`）
- 真机安装与 FFI 加载验证（等设备）

## 0. 先厘清"支持鸿蒙"的三种含义

| 解读 | 含义 | 本质 |
|---|---|---|
| **A. 应用跑在鸿蒙设备上** | XDRemux 本体在 HarmonyOS NEXT（纯血鸿蒙，无 AOSP）上运行 | 应用移植工程 |
| **B. 支持华为手机照片输入** | 华为/XMAGE 相机的 HDR HEIC 作为转换输入（新格式族） | 格式逆向工程 |
| **C. 输出适配鸿蒙图库** | 像"OPPO 兼容 / Apple 标准"一样增加"鸿蒙"输出模式 | 格式 + 产品工程 |

三者可以独立推进，B/C 甚至可以不依赖 A（在任何现有平台上处理华为照片）。**本研究的默认目标：A（NEXT 原生应用）为主线，B/C 作为衍生决策点**。

重要前提：**HarmonyOS 4.x 及更早版本基于 AOSP，现有 Android APK 理论可直接安装运行**——这提供了一个零成本基线。真正的工程只发生在 HarmonyOS NEXT（5.x+）。

## 1. 技术摸底结果

### 1.1 Rust 核心（好消息）

- `aarch64-unknown-linux-ohos` / `armv7-unknown-linux-ohos` / `x86_64-unknown-linux-ohos` 是 Rust 官方目标（rustup 可直接安装 std，已验证下载成功）
- `cargo check --target aarch64-unknown-linux-ohos` 实测卡点：build.rs 里 `cc` 找不到交叉编译器（本机无 OHOS NDK）——**这不是代码问题，是工具链问题**
- ~~需要的工作~~（已完成，详见 §0.5）：
  1. ~~安装 DevEco Studio（含 OHOS NDK，musl-based clang 交叉工具链）~~ ✅
  2. ~~`build.rs` 增加 OHOS 平台分支~~ ✅（注意：`CARGO_CFG_TARGET_OS=linux`，须用 `CARGO_CFG_TARGET_ENV == "ohos"` 判定）
  3. ~~x265 用 OHOS NDK 的 CMake 工具链交叉编译~~ ✅（`ohos.toolchain.cmake` + `-DENABLE_ASSEMBLY=OFF`）
  4. ~~cargo 目标构建~~ ✅（`aarch64-unknown-linux-ohos`，cdylib 直出 .so）
- 风险判断：**低**（实测证实）。x265 是纯 C++/汇编库（OHOS 下汇编关掉即可），Rust 核心无平台特定 syscall

### 1.2 Flutter 引擎（两个维护方，结论完全不同）

**维护方对比（2026-08-25 实测）：**

| 维护方 | 位置 | 最新版本 | 活跃度 |
|---|---|---|---|
| openharmony-sig（官方 SIG） | gitee | 3.7.12-ohos-1.0.4（2025-02 停滞） | 低 |
| **CPF-Flutter** | AtomGit（atomgit.com/CPF-Flutter） | **oh-3.44.9-dev（2026-08-25 提交）、oh-3.41.9-release**（2026-08-20） | **高（活跃开发中）** |

CPF-Flutter 组织维护完整生态：

- `flutter_flutter`：框架 fork，发布线 3.22 → 3.27 → 3.32 → 3.35 → **3.41.9-release**，开发线 **3.44.9-dev**（与我们 CI 的 3.44.5 同小版本线！）
- `flutter_engine`：引擎 fork（release 分支至 oh-3.27.0-release；**更新引擎的构建/分发方式待 spike 核对**，可能随框架仓 release 分发）
- `flutter_packages`：官方 packages fork（46 包，含 path_provider / shared_preferences / url_launcher / file_selector）
- `fluttertpc_*`：数百个三方插件 OHOS 适配
- `fluttertpc_dart_sdk`：Dart SDK fork

**引擎版本落差风险基本解除**：可用 oh-3.41.9-release（稳定）或直接跟我们同代的 oh-3.44.9-dev。

### 1.3 插件依赖盘点（CPF-Flutter 生态覆盖实测）

| 插件 | 用途 | CPF-Flutter 覆盖 |
|---|---|---|
| ffi | Rust FFI | SDK 内置 |
| path_provider / shared_preferences / url_launcher / file_selector | 基础 | ✅ flutter_packages fork |
| file_picker | 文件选择 | ✅ `fluttertpc_file_picker` |
| flutter_local_notifications | 通知 | ✅ `fluttertpc_flutter_local_notifications` |
| flutter_foreground_task | 后台转换保活 | ✅ `fluttertpc_flutter_foreground_task` |
| receive_sharing_intent | 接收分享 | ✅ `fluttertpc_receive_sharing_intent` |
| open_filex | 打开文件 | ✅ `fluttertpc_open_filex` |
| permission_handler | 权限 | ✅ `flutter_permission_handler` |
| gal | 相册写入 | ⚠️ 无官方 gal，有 gallery_saver 系列变体（需评估 API 差异） |
| share_plus | 分享 | ⚠️ 未在列表中匹配到（需再确认或自写薄桥） |
| package_info_plus | 版本信息 | ⚠️ 未匹配到（鸿蒙 bundleManager 可自写） |
| http / cupertino_icons | 纯 Dart | ✅ 无平台代码 |

**结论修正：插件层大部分已有社区适配，自写桥的工作量集中在 gal / share_plus / package_info_plus 三个（都是薄 API）。**

### 1.4 华为照片格式（B/C 的前提，未知）

- 华为 XMAGE 旗舰的 HDR 照片表示法待调研：是否私有尾部（类似 OPPO）？还是 Ultra HDR（Android 标准 gain map JPEG）？还是 HDR Vivid 静态扩展？
- 鸿蒙图库（图库 App）对 ISO 21496-1 HEIC 的支持程度未知
- **需要华为/鸿蒙真机样本**才能推进 B/C

## 2. 方案选项

### 方案 1：鸿蒙 NEXT 全量移植（解读 A）

CPF-Flutter 框架 fork（oh-3.41.9-release 或 oh-3.44.9-dev）+ Rust OHOS 目标 + 社区插件适配 + 少量自写桥。

- 成本：**中**（引擎版本风险已解除；剩余工作 = 引擎接入、3 个插件薄桥、新 CI 线、真机联调）
- 收益：NEXT 原生应用
- 阻塞点：DevEco 环境搭建、引擎 release 产物分发方式核对、鸿蒙真机

### 方案 2：先 B/C，不做 A（推荐第一步）

在**现有平台**（Windows/Android/macOS/iOS）上支持华为照片输入与鸿蒙图库输出：

- 拿到华为样张 -> 逆向 HDR 表示 -> 纳入转换管线（我们已有成熟的 ProXDR 逆向方法论：container/tail 解析 + 双解码器验证）
- 输出模式增加"鸿蒙兼容"（如果鸿蒙图库有特定格式要求）
- 成本：**中**（纯格式工程，无平台移植）
- 前提：华为真机样本 + 鸿蒙图库行为调研

### 方案 3：鸿蒙 4.x 基线验证（零成本立即做）

现有 Android APK 在鸿蒙 4.x 设备上直接安装验证：

- 确认 SAF、前台服务、Rust .so（aarch64-linux-android ABI 在鸿蒙 AOSP 层应兼容）可用
- 成本：**极低**（一次真机测试）
- 产出：决定方案 1 的紧迫性（如果 4.x 基线可用，NEXT 移植可以从容排期）

## 3. 推荐路径

```
方案 3（鸿蒙4.x基线验证，立即）──► 方案 2（华为格式支持，需样本）──► 方案 1（NEXT 移植，大工程，视需求）
```

方案 1 若启动，拆分顺序：
1. Rust 核心 OHOS 构建跑通（spike，~0.5-1 天：DevEco NDK + build.rs 分支 + x265 交叉）
2. CPF-Flutter 引擎接入（选定 oh-3.41.9-release 或 oh-3.44.9-dev；核对其引擎产物分发与构建方式）
3. 插件桥补齐（gal / share_plus / package_info_plus 三个薄桥）
4. CI 增加 OHOS 构建线

## 4. Spike 任务清单（本分支待办）

- [ ] 方案 3：Android APK 装鸿蒙 4.x 设备验证（需要鸿蒙设备）
- [ ] Rust：`build.rs` 加 ohos 分支 + DevEco NDK 下 `cargo build --target aarch64-unknown-linux-ohos` 跑通（需要 DevEco Studio）
- [ ] x265 OHOS 交叉编译验证
- [ ] CPF-Flutter `oh-3.44.9-dev` 可用性 spike：hello-world 跑通 + 我们 app 的 `flutter build hap` 走一遍
- [ ] 引擎二进制分发方式确认（flutter_engine release 只到 3.27.0；更新版本引擎随框架仓分发还是单独构建？）
- [ ] 华为 XMAGE 样张收集与格式逆向（`styles_diag` / `tail_dump` 探针直用）
- [ ] gal / share_plus / package_info_plus 的 OHOS 替代确认或薄桥实现

## 5. 风险与边界

- **生态维护风险**：CPF-Flutter 社区 fork 非 Flutter 官方主线；活跃度高（2026-08 仍在日更）但绑定它意味着跟随其节奏
- **引擎产物分发**：flutter_engine 仓 release 分支停在 3.27.0，与框架 3.41.9/3.44.9 的对应关系未核实（spike 第一项）
- **鸿蒙设备可得性**：本仓库目前无鸿蒙真机，所有验证依赖用户提供样本/设备
- **分发**：AppGallery 上架有审核；侧载（hdc 安装 .hap）供测试可行
- 与 iOS 侧载研究同样原则：鸿蒙私有 API 仅研究，不进产品承诺
