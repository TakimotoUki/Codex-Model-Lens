# 1.3.1 模型证据恢复验证

2026-10-01，Apple Silicon / macOS 27 本机，Swift 6.2 / SDK 26。

- 68 项离线测试通过，6 个 suite。覆盖已存在数据目录的逐文件恢复、迁移幂等、已有设置和损坏文件保护、删除任务不恢复、保存过的服务端证据保留。
- 无 ID 的 WebSocket `response.metadata` 模型响应头在有明确轮次关联时接收；没有轮次关联保持未知。嵌套 `response.headers` 优先于顶层 `headers`，大小写和数组格式受到支持。
- 同一响应优先采用模型响应头，保留普通 `model` 字段；后续不同响应独立判断。多个不同模型响应头仍不确认为单一模型。无关 metadata 不清空待归属模型头。
- 原始聊天、工具引用、出站请求、预热、失败、超时和无输出继续不作为输出模型确认依据。
- arm64 release 构建和 ad-hoc 签名完整性检查通过；未进行 Developer ID 公证。

## 本机复核及适用边界

只读检查旧版和当前 App 数据目录发现：旧版有一份成功的独立模型核验，当前目录缺少 model-probes.json 和 settings.json。旧迁移仅判断目录是否存在，导致部分迁移后余下记录被跳过。该成功核验报告输出模型 gpt-6-astra，只属于当次测试。

现有普通任务归档仅有轮次请求模型，不能因此确认为实际模型。日志中的聊天 / 工具引用不计入传输证据。当前桌面 IPC 可以初始化专用只读客户端，但任务 owner 查询未得到可用模型事件，因此没有接入不稳定或未核实的 IPC 模型检测。没有额外发送生成请求，也未重启 Codex。

解析优先级根据 [OpenAI 官方 Codex Responses 实现](https://github.com/openai/codex/blob/6b2a7ed47cb662f375f47bcac908b8c17bedc75e/codex-rs/codex-api/src/sse/responses.rs#L192) 核对。软件读取服务端报告的字段，不能证明后台权重身份，也不会将独立核验套用到已有任务。
