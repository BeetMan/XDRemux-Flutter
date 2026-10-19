# P2.1 Dart worker 与接收箱交接验证

日期：2026-10-19。分支：`codex/local-transfer`。结构化结果见 [evidence](local-transfer-p21-evidence.json)。实现契约见 [Dart 模块](../../apps/flutter/lib/services/transfer/README.md) 与 [C ABI](../../crates/xdremux-transfer-ffi/README.md)。

## 交付

- 独立 Dart FFI 绑定与长期 worker isolate；worker 内加载 transfer 动态库，按 operation ID 匹配异步结果；有界轮询/事件缓冲、丢失标记、结果查询和 outcome_unknown。缺库/旧 ABI/不支持平台只返回互传能力不可用。
- 复制期间保持 native 读取租约，按声明长度与 SHA-256 流式校验，发布到 checkpoint 的 receipt UUID bucket，保留原文件名。同名回执隔离、重复请求合并；未知类型继续保留在接收箱。
- 现有首页队列注册显式 intake，复用分类/人像/华为策略；收到传输副本时不按文件名寻找其他 donor。保存 checkpoint 成功后才返回 ACK，失败不删除独立副本；重试按稳定路径去重。转换默认输出与输入/接收箱分离。
- import/ACK 和 checkpoint 清理串行；导入期间禁止队列编辑/启动。批量 picker 清理跳过 transfer buckets，明确移除队列项才清理其副本/标记。崩溃暂存和完整的未发布 ACK 标记可恢复。
- ABI 升为 **1.1 (`65537`)**，新增 advisory `check_space`，不改导出函数签名。副本位于同一应用 support 文件系统时，检查副本所需空间加 64 MiB 预留；写入仍须处理实际 I/O 错误。

没有搬入主工作区未提交的 codec/preview/thumbnail 代码。Flutter 只改已有基线上的队列/输出/checkpoint 入口；`crypto 3.0.7` 从既有 dev 依赖提升为生产依赖，保留锁定版本和原镜像源，没有升级其他依赖。

## 结果

| 检查 | 结果 |
|---|---|
| Flutter analyze（受影响源码、测试与 smoke） | 通过，无问题 |
| Flutter 测试 | 30 项通过：6 项新复制/持久化/清理测试、1 项真实 HEIC 首页队列测试，及现有 widget/checkpoint-motion 用例 |
| 真实首页队列 | 使用 P0 HEIC 样本的临时副本，走现有 Rust classifier、首页入队与 checkpoint 保存；第一次 added、再次 duplicate；独立副本哈希一致，删除模拟 inbox 原件后仍可读 |
| DLL + Dart worker | 真实 loopback HTTPS，4 文件、71,303,181 bytes；包括中文/emoji 文件名、同名照片、MOV、64 MiB JPEG 容器测试数据；独立文件哈希一致 |
| worker 能力与错误 | 缺 DLL、ABI 1.0 降级；真实 NoSpace 错误；队列 ACK 丢失后重复导入恢复；MOV 未入转换队列；原接收箱删除不影响副本 |
| 生命周期 | 观察到 64 MiB 文件仍在 staging 写入时调用 dispose；复制完整、租约释放后退出；重复 dispose、相同目录/端口重新启动、证书保持/实例更新通过 |
| Rust 回归 | 核心 17/17、adapter 2/2；两 crate fmt、adapter `clippy --all-targets --no-deps --locked -- -D warnings` 通过 |
| Windows ctypes ABI 回归 | ABI 1.1、3 文件 2,097,178 bytes；句柄、输出上限、租约/删除、分页与停服复验通过 |
| Android ARM64 | 新 `.so` / NDK API 24 构建；PKJ110 Android 17(API 37)，C dlopen 连续 3 次相同目录/端口启停通过，部署库哈希一致 |

真实首页用例通过环境变量显式提供 HEIC fixture；默认缺 fixture 时跳过，不能把 CI 的跳过当作实机/样本验证。该测试关闭既有的“跳过已转换”配置，以验证分类/队列交接；产品的拒绝/跳过策略未更改。未修改 supplied fixture。现有设置测试原来期待旧文案 `Apple 人像模式（Rust）`，已把断言同步到基线实际文案 `Apple 人像模式`。通知/托盘/缩略图插件在 host widget 测试中仍按已有逻辑报告不可用，不代表发布插件测试。

`tool/transfer_worker_smoke.dart` 的大 JPEG 是测试容器签名和不透明 payload，不作为照片解码或转换成功证据；真实 HEIC 分类/队列用例单独记录。日志、临时文件、旧 ABI 测试 DLL 和测试报告在 ignored target 中，未提交私人路径或二进制。

## 尚未验收

P2.1 没有互传页面、自动发现、发布库打包、APK/Flutter EXE LAN 权限或应用间双向验收。Android 本次仅由 ADB shell 加载 `.so`，**未证明 release APK 中 Dart worker 能成功加载和联网**；现有 image FFI 的 Android 注释也提示不同加载上下文需要真机复验。Windows Dart/ctypes 回环结果不代表最终 Flutter EXE 防火墙已放行。

副本空间检查针对同 support 文件系统的额外输入副本，不涵盖用户选定导出目录和转换输出的总空间预算。通用文件导出/Android SAF、未入队副本的保留清理 UI、退出/后台协调、信任/接收确认、实际应用发布打包与互操作属于下一步 **P2.2**。Apple/HarmonyOS 验证仍延后。
