# 1.5.1 验证记录

日期：2026-10-01。目标：macOS 26+、Apple Silicon。

- 用户报告采集模式的浏览器登录成功，但返回 Codex 后无法加载用户配置。只读本机日志发现明确 `invalid peer certificate: Other(OtherError(CaUsedAsEndEntity))`，此前普通 HTTPS 测试未暴露 rustls 对 CA 证书作为终端证书的拒绝。
- 修复为独立根 CA 签发独立服务端证书：根使用 CA:TRUE / keyCertSign，叶证书使用 CA:FALSE / serverAuth / loopback SAN，客户端信任根而非把根作为服务端证书。
- 使用本机签名官方 Codex CLI，通过最终本机代理执行隔离账户读取成功，输出 `Official Codex TLS accepted; quota windows: 1`。正常直连账户对照也成功。没有生成模型回复，没有修改原始 auth、config、客户端 bundle、系统代理或证书信任；私有认证副本结束后清理。
- 网络启动入口现在先执行同样的官方 CLI 账户检查；失败停止本次代理、显示已脱敏错误类别，保留正常启动路径。需要先正常登录 Codex。不会处理或伪造浏览器 OAuth 回调。
- 多任务区域从固定推算行高改为测量真实内容，达到上限才滚动。两个未确认任务的原生截图没有任务区尾部预留空白；八个已确认演示任务在紧凑上限内滚动，外层最大高度保持一致。
- 复用 Mutex 保护的 ISO 时间解析器，IPC 每帧设 autorelease pool，并释放空接收缓冲。90 个 Swift 测试、9 个套件和 7 个代理插件测试全部通过，包含并发时间解析、非有限输入、跨任务 / 跨轮次隔离与缓冲上限。
- arm64 Release 构建与严格 ad-hoc 签名校验通过。真实数据首次只读扫描覆盖 259 个任务、1,413 个轮次、168 个文件，读取约 580 MB，耗时 6.14 秒，诊断为 0。这是本机检测时快照，不是新 Mac 的固定数据或通用性能保证。

明确边界：没有退出执行本任务的 Codex，因此未完成新的桌面 OAuth 交互或 GUI 任务推理的端到端测试。账户核验成功证明导致配置读取失败的证书链已被同款官方 rustls 接受；它不应被描述为已确认当前任务模型。当前旧连接、已丢失的响应和没有明确关联的字段不能恢复。服务端模型名仍不等于模型权重证明。

依据：[rustls/webpki 的终端证书约束](https://github.com/rustls/webpki/blob/main/src/verify_cert.rs)、[Codex 进程内 CA 实现](https://github.com/openai/codex/blob/main/codex-rs/http-client/src/custom_ca.rs)。完整采集、用量和状态边界仍见 [1.5.0 记录](VALIDATION-1.5.md) 与 [安全说明](../SECURITY.md)。私有日志和账户数据不进入仓库或发行包。
