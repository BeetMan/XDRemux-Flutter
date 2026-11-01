# Windows 真实接收进程崩溃恢复

2026-10-25，新增 `crates/xdremux-transfer-ffi/scripts/crash_smoke.py` 并纳入传输专项门禁。使用真实 ABI 1.3 DLL、独立接收子进程与 loopback 双向证书校验后的 HTTPS 上传。只结束脚本创建的子进程，未操作手机、用户应用或系统网络。结果见 [JSON](local-transfer-crash-report.json)。

1. 完整提交一个 64 KiB 基线文件，取得读取租约并保持；第二个 8 MiB 上传实际写入 64 KiB 后，保持连接并直接 `Popen.kill()`。确认磁盘上存在真实上传残留后，才同根／同端口重启。原身份保持、runtime 更新，半文件清理，只有已提交基线可见。
2. 重启后上传并实际观察第二个完整文件的 committed 事件，在 HTTP 客户端尚未读取响应时直接杀死接收进程。再次同根／同端口启动，核对两份回执保留且无重复；根据收件记录确认结果，没有重放这次 mutation。此场景是客户端尚未确认响应，不证明 ACK 未离开发送栈，也不等价于真实网络丢包。
3. 对确认未提交的部分文件执行一次显式重新发送；三件完整收件数据均进行独立磁盘长度／SHA-256 校验，保存自有审计副本。释放新租约后，三件均可显式删除，证明被杀进程的旧读取租约没有阻塞后续管理。源 fixture 哈希不变。

```powershell
python crates/xdremux-transfer-ffi/scripts/crash_smoke.py --library ABSOLUTE_DLL --root NEW_ABSOLUTE_ROOT
```

所有等待有期限，子进程握手／命令采用有界等待的 JSON 管道；测试失败也清理自有子进程并记录结果。最终进程退出、接收端口重绑定通过。根目录须为新目录；身份私钥及审计字节保留在此忽略目录，CI 仅收集其公开结果摘要，不上传这些文件。

本轮在重新构建的 Windows DLL 上通过两个实际强停场景及后续重试、校验、删除。此项覆盖 native／FFI 接收进程死亡，不覆盖断电／磁盘缓存丢失、发送进程死亡、Flutter 主进程状态、手机生命周期或真实切网；普通退出和构造目录恢复测试仍各自保留。
