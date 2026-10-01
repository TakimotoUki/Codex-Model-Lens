# 1.5.0 验证记录

日期：2026-10-01。目标：macOS 26+、Apple Silicon。Swift 6.2 / macOS 26 SDK，在当前 Mac 上构建。

## 已验证

- 89 个 Swift 测试、9 个套件，以及 7 个 Python 代理插件离线测试通过。新增覆盖明确任务关联、并行任务分别归属、新轮次不继承旧模型、服务端 / 客户端方向区分、SSE 分片、模型字段投影与隐私、缓存上限、旧版 protobuf 默认零值、新版可选空值、RSS / Atom、XML 外部实体与非官方链接排除。
- arm64 Release 构建成功，ad-hoc 签名严格校验通过，LSUIElement 保留；默认菜单栏启动，主窗口按用户点击打开。设置与菜单原生截图已检查，重置卡没有独立刷新图标，字号与余额同层级。
- 对用户提供的真实 WebSocket 抓包做只读解析，新插件提取 2 条明确关联记录，属于 1 个测试轮次，服务端模型为 gpt-6.1-sol；跳过轮次 ID 为空的预热。仅保存元数据投影，未复制或发布原始抓包、认证与任务内容。该样本结果不代表当前桌面任务。
- 本机安装的桌面客户端包含 CODEX_APP_SERVER_CHATGPT_BASE_URL 到 chatgpt_base_url 的启动参数映射；官方 CLI 0.159.2 包含进程内 CODEX_CA_CERTIFICATE 支持。网络入口采用这些按进程配置，不改原始 config.toml 或系统设置。
- 官方 mitmproxy 12.2.3 arm64 包 SHA-256 与固定校验值一致。安装器在本应用私有副本重建 ad-hoc 签名，并完成完整代码校验。此版本上游包装签名不完整，未将该检查描述为 Developer ID 真实性或公证。
- 最终 Swift CLI 成功启动原生本机 HTTPS 反向代理。只带私有 CA 的无认证 GET 返回上游 405，证明本机 TLS 与转发路径工作；没有发送推理请求。主动结束测试 CLI 后，代理在所属进程检查中自动退出，端口关闭。
- 原生 Antigravity 查询强制使用独立 headless 语言服务器成功：实际 Starter Quota；Gemini 0%，Claude / GPT 约 0.11%，均有有效重置时间。没有调用正在运行的 App 的语言服务，证明查询进程可以独立工作；未为了测试强制关闭原始 Antigravity。
- 只读确认旧版 Google QuotaInfo.remaining_fraction 为非可选 proto3 float，JSON 省略默认零值；仅在经验证本机接口且有有效 resetTime 时解码为 0%。用户原始 OAuth / App 数据未修改；独立查询的认证副本和临时目录结束后删除。
- 原生网络客户端成功读取三份官方 RSS / Atom：Codex 分组状态正常；DeepSeek 订阅暂无未解决事件；Google Cloud 明确标为参考订阅，未覆盖 Antigravity。Feed 中未知状态不当作正常，服务事件放在对应平台 Token 下方。
- 源码和可发布资料检查未发现开发者家目录、研究临时路径或私人账户文件；发行包不包含 Data、采集流量、用户历史、凭据或下载的可选可执行组件。

## 尚未验证 / 明确限制

- 当前 Codex / ChatGPT 正在执行本任务，没有关闭或重新启动它。桌面启动入口、原生代理、证书链、真实 WebSocket 样本解析分别通过，但“重新打开桌面客户端 → 新的正常任务响应 → 菜单显示该轮服务端模型”的完整链路尚需在使用时确认。未宣称当前全部任务已经获得模型证据。
- 此轮没有新增模型生成或 pong 请求，不消耗额外推理额度。用户提供的旧测试样本只归属其明确标识的轮次。
- 网络模式仅覆盖通过本机采集入口重新打开的官方客户端与官方 ChatGPT 后端。已运行连接、丢失历史、其他设备、云端 / 远程任务、第三方中转没有被补抓。
- 服务端报告的 model / OpenAI-Model 不是模型权重证明；服务端不披露的内部静默切换无法由该字段独立识别。行为指纹未被当作确定身份。
- 可选采集代理有额外内存、CPU 和磁盘开销，默认关闭，基础 App 不捆绑其约 52 MB 下载包。未把基础模式性能数据套用于启用代理后的总占用。
- Antigravity 新版 quota-summary 在此账户可能受到资格 / 地区条件限制；使用官方本机旧版模型额度作后备，不绕过资格限制。此接口未提供 Token 总数，不能编造 Token 值或额度周期。
- Google Cloud 公共订阅没有 Antigravity 专属组件；“暂无未解决事件”也不等于绝对实时健康保证。
- Release 为 ad-hoc 签名，未完成 Apple Developer ID 公证。自动测试和代码审核不能证明软件没有任何未知缺陷。

## 核查依据

- [官方 Codex 进程内自定义 CA](https://github.com/openai/codex/blob/main/codex-rs/http-client/src/custom_ca.rs)
- [mitmproxy 12.2.3 官方发布](https://github.com/mitmproxy/mitmproxy/releases/tag/v12.2.3)
- [Homebrew 官方组件摘要](https://github.com/Homebrew/homebrew-cask/blob/main/Casks/m/mitmproxy.rb)
- [OpenAI RSS](https://status.openai.com/feed.rss)、[DeepSeek RSS](https://status.deepseek.com/feed.rss)、[Google Cloud Atom](https://status.cloud.google.com/en/feed.atom)

私有研究日志、原生截图、元数据投影和真实账户查询不进入仓库或发行包。公开记录仅含聚合结论与验证边界。
