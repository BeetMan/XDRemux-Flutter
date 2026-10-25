# 传输存储管理与受保护清理

2026-10-26（UTC+8），基于 `514f471f`。互传页收件箱旁新增“存储管理”，提供完整收件分页统计、传输导入副本统计、逐件选择／确认、逐件清理结果与显式重试。证据见 [JSON 报告](local-transfer-storage-report.json)。未操作用户的真实收件箱或照片。

## 行为

- 收件原件通过 native 管理接口删除。正在导出／复制的读取租约返回 `busy`，保留文件；释放后可显式重试。删除原收件不影响已导入的独立副本。
- 副本只在 UUID 桶、marker、文件名、长度和内容哈希均可核对时清理。选择后会再次检查，变化或异常时保留。
- 当前队列路径、相同 receipt 桶的路径别名、`added`／`duplicate` ACK 副本均保留。队列接管的副本继续由队列移除流程管理。普通选择器／分享入队正在读取时，存储操作返回 busy；清理开始后阻止新入队，导入与清理共用现有所有权串行门。
- 已发布 checkpoint 的引用保留；损坏、截断、待完成 `.tmp` checkpoint 或无法识别的副本均禁止清理。符号链接／Windows junction 不授权遍历。
- 副本先改名到自有 trash 桶，再逐文件删除。没有递归删除；中断后留下的可核对 trash 会在预览中出现，可显式重试。额外未知文件、marker 临时文件和不可信内容均保留。
- 清理不会自动重试 mutation。部分成功与逐项错误分别记录；未知结果从重试选择中移除，并在当前清理窗口内禁用，提示重新打开互传页核对。重新扫描中已不存在的原收件不再发出删除命令。
- 转换输出、导出目标、图库、普通选择器缓存和不可识别目录不属于清理对象。统计是已识别文件内容的字节数，不等于文件系统实际分配空间，也不包含所有临时文件／索引开销。接收仍在进行时，预览是查询期间的记录，之后新增文件不自动选中。

磁盘扫描／哈希在独立 isolate 执行；RPC、扫描和清理由 controller 记录为受管操作，停服等待其结束。清理计划绑定 runtime ID，旧计划不能操作重启后的服务。

## 验证

新增 14 项：13 项受控／widget 回归及 1 项真实 DLL／worker／生产 controller 存储接口检查。受控用例覆盖 65 条收件的完整分页、队列与 ACK 保护、选择后引用变化、checkpoint 损坏／截断／待写、内容篡改、未知子项、清理残留恢复、Windows junction、部分失败、未知结果不重放、旧 runtime、入队中互斥及部分成功保留。界面在桌面和 390×844 尺寸检查选择、确认、禁用和显式重试流程。

真实 DLL 用合成 JPEG 签名字节完成 loopback 传输、保留真实读取租约；删除先得到 busy，释放后显式重试成功，受保护副本与原发送文件哈希不变。撤销测试队列引用后，未入队副本可显式清理。fixture 显式调度 controller 轮询，存储方法、读取保护和 stop 使用生产实现；不计作普通应用完整页面或 Android 真机验收。

完整 Flutter 运行通过 153 项，另有依赖 HEIC 素材的 classifier／首页队列用例默认跳过；随后使用既有自有验收素材单独补跑该 1 项通过，素材哈希不变。analyze 无问题。Windows 与 Android arm64 普通 main release 构建通过，未安装到手机；未修改 Rust 核心、ABI、锁文件或主线工作区。打包库及普通应用身份核对见 JSON。

```powershell
# apps/flutter 下；启用真实 Windows DLL 检查
$env:XDREMUX_TRANSFER_TEST_DLL = 'ABSOLUTE_DLL'
flutter test --no-pub test/transfer_storage_test.dart test/transfer_storage_native_test.dart
flutter analyze --no-pub
```

本轮仍不代替真实磁盘耗尽、系统断电、Android SAF 提供者／OEM 生命周期、真实切网／VPN、Apple 或鸿蒙设备验收。
