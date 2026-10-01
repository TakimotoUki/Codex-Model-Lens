# Codex Model Lens

**一个轻量的原生 macOS 菜单栏应用：查看 Codex 任务的模型证据、Agent 用量，并管理专注时间。**

Swift · SwiftUI / AppKit · macOS 26+ · Apple Silicon · MIT

[下载 Release](https://github.com/TakimotoUki/Codex-Model-Lens/releases/latest) · [介绍网站](https://takimotouki.github.io/Codex-Model-Lens/) · [安全与隐私](SECURITY.md) · [贡献者](AUTHORS.md)

**Contributors**

| TakimotoUki | Codex AI（OpenAI） |
| --- | --- |
| [项目作者与产品设计](https://github.com/TakimotoUki) | [实现、测试、审核与文档协作](https://openai.com/codex/) |

AI 协作通过 `AUTHORS.md` 与提交的 `Co-authored-by: Codex <codex@openai.com>` 明确署名；GitHub 侧栏头像列表由账户映射自动生成，不关联同名的人类账号。

> **模型识别的边界：** 软件能读取服务端明确报告的模型字段和路由事件，并检测其与请求模型的差异。它不能证明服务端运行的模型权重，也无法从未保存、未公开的字段恢复任意现有任务的真实模型。没有有效证据时显示“模型未确认”。独立核验只说明该次核验请求。

<p align="center"><img src="docs/assets/menu-usage.png" width="360" alt="用量与任务模型菜单，明确标注为演示数据"> <img src="docs/assets/menu-timer.png" width="360" alt="独立的紧凑番茄钟菜单"></p>

## 功能

- **默认只出现在菜单栏。** 启动时没有 Dock 图标和主窗口；明确点击“打开主界面”才打开三栏 Codex 任务工作区。设置、账户与用量面板可直接从菜单打开。
- **Codex 模型证据。** 当前和历史任务、轮次请求模型、服务端响应 `model`、`openai-model` / `x-openai-model` 以及明确 `model/rerouted` 事件；保留来源、时间、响应 / 请求 ID。不能确定关联的事件不按时间猜测归属。
- **网络响应模型采集（1.5.0）。** 手动重新启动 Codex 后，用本机 HTTPS 反向代理读取服务端入站 WebSocket / SSE 的模型字段，按明确任务和轮次 ID 保存。无需修改原始 Codex 配置、系统代理或证书信任；按需下载独立组件，默认关闭。
- **实时模型监听。** 连接已登录桌面客户端的本机 IPC，读取当前轮次和历史快照中的明确路由事件；支持新版 canonical 历史与增量更新。连接验证同用户和 OpenAI 对端签名，只订阅、不执行任务。
- **请求诊断。** 区分 `at capacity` 文字、`server_is_overloaded` 错误、失败请求、HTTP 状态与安全缓冲；保存本机日志覆盖时间。计数差异本身不能证明客户端撒谎或替换了模型。
- **一致图标。** 主界面和关于窗口共用应用图标；菜单栏使用同一机器人与放大镜的原生单色线条版本，自动适应深浅菜单栏。菜单弹窗顶部直接显示功能切换按钮，省去软件名与 Logo。
- **历史。** 本地原子保存、增量读取、JSON / CSV 导出、模型证据导入。移除本地任务后后续扫描跳过它，原始 Codex 会话保留。损坏或更新版本的历史文件不会被静默覆盖。
- **独立模型核验。** 手动确认后用签名验证过的官方 CLI 发送一个 `pong` 测试，捕获原始入站响应的模型字段，区分预热响应和有输出的响应。会消耗少量 Codex 额度；从不自动发送。
- **多平台用量。** 五个平台可独立开启和关闭；仅所选、启用的平台按需读取。菜单参考 CodexBar 的紧凑组织方式，采用系统蓝色与原生 Liquid Glass 控件。
- **添加账户。** Codex 登录文件、DeepSeek API Key、OpenCode Go API Key 或手动工作区 Cookie；随机账户 ID，钥匙串保存凭据，账户缓存分别保存。Antigravity / WorkBuddy 使用本机 Agent 当前登录。
- **用量概览。** 区分购买余额、重置卡和积分；按账户保存最近 90 天的成功用量快照，累计 Token 图表明确标明计量范围。
- **平台服务状态与关于。** 左对齐显示在用量底部。Codex 覆盖 OpenAI 全部公开组件与 RSS 事件；Antigravity 聚合 Gemini API / AI Studio 全部流量层级及 Google Cloud 全部公开事件；DeepSeek 使用官方 RSS。OpenCode Go、WorkBuddy 无可用官方状态接口，因此不显示状态区域。未返回的数据字段与失败的状态源不展示空占位。关于窗口显示版本、开源链接和贡献署名。
- **独立番茄钟。** 自定义专注 1–240 分钟、休息 1–120 分钟，暂停、恢复、结束；菜单栏显示 `MM:SS` 并逐秒更新。使用截止时间计算，休眠后修正，时间到提醒；休息需手动开始。页面高度随内容调整，计时器操作不会刷新平台用量。

## 各平台支持范围

| 平台 | 认证 / 来源 | 可显示的信息 | 明确限制 |
| --- | --- | --- | --- |
| Codex | 已登录官方桌面内置 CLI；已知文件 / Keychain 登录；可添加登录文件账户 | 套餐、服务端额度窗口、剩余比例、重置时间；官方接口可用时的累计 / 今日 UTC Token；可用重置卡数量和最近到期时间 | 接口可能随版本和账户变化；订阅 Token 不是实际账单；任务模型字段不一定存在 |
| Antigravity / Gemini | 已安装、登录的签名 Google App，本机语言服务器 | `userTier` 实际套餐、quota summary 或模型额度、重置时间 | App 不运行时使用签名 Google 后台语言服务器查询，无需打开主 App；当前接口未提供 Token 总数 |
| OpenCode Go | `OPENCODE_API_KEY`、本机 `auth.json`；API Key 账户；手动 Cookie + `org_…` 工作区 | 官方 5 小时 / 周 / 月窗口（接口提供时）；本机 SQLite 最近 90 天 Token；工作区余额 | 工作区账户不混入全设备历史；本机 Token 不能推算账户额度；缺失 Token 组成保持未知 |
| DeepSeek | API Key 账户或环境变量 | 余额、充值余额与赠送余额 | 余额 API 不提供 Token 或重置，不由余额变化推算这些值 |
| WorkBuddy（实验性） | 支持的本机未加密登录格式 + 官方计费接口；新版加密格式使用本机数据库后备 | 支持格式下的个人 / 企业剩余积分、积分包和重置；加密格式下按请求去重的本机已记录消耗积分 | **本机新版加密登录尚不能读取剩余余额**；不会解密其认证文件，余额请到官方“套餐与用量”查看；积分不是 Token 或货币 |

Antigravity 的 `planStatus` 可能包含旧版通用 Pro 模板，本应用优先采用实际 `userTier`，例如 **Antigravity Starter Quota**。仅在经验证的本机旧版 GetUserStatus 协议中，`remaining_fraction` 为非可选 proto3 float；有有效重置时间但省略该字段时，按协议默认值显示 0%。缺少重置时间、显式 null 和新版可选额度字段仍保持未知。非零且不足 1% 的额度保留两位小数，避免显示为 0%。软件不将安全缓冲的 `fasterModel` 当成已交付模型。

OpenCode Go API 的 `percent` 是 0–100 百分数，`1` 表示已用 1%。工作区 micro-cents 按接口单位换算。本机 Token 选择 step-finish 记录或其父消息汇总中的一种，避免重复计数；仅选择 `providerID = opencode-go` 的 assistant 记录。

## 安装和首次运行

1. 从 [Releases](https://github.com/TakimotoUki/Codex-Model-Lens/releases/latest) 下载 `Codex-Model-Lens-1.5.2-arm64.zip`，按同页校验文件检查 SHA-256。
2. 解压，将 **Codex Model Lens.app** 放入 Applications（系统或用户 Applications 均可）。普通模式不需要 Python、Node、Homebrew 或外部 Swift 包。可选网络采集使用内置下载入口准备独立组件，无需额外安装这些运行环境。
3. 打开 App，在菜单栏找到机器人与放大镜线条图标。点击它查看 Codex；通过“设置…”开启其他平台。
4. 安装并登录对应的 Agent。Codex 通常使用 `~/.codex`；自定义 `CODEX_HOME` 可通过设置选择。Antigravity 需已安装并登录官方 App；没有运行中的语言服务时，软件会启动短期独立后台查询，结束后关闭。
5. 如果 macOS 请求访问对应登录的钥匙串项，按系统提示确认。DeepSeek / OpenCode 的额外账户通过 **添加账户** 添加。
6. 开始番茄钟时允许通知。拒绝通知权限时，App 仍运行期间会用原生提醒框和声音提示；退出 App 后该后备提示不可用。

**本次二进制采用 ad-hoc 签名，未进行 Apple Developer ID 公证。** 新下载的 App 可能被 Gatekeeper 拦截；检查来源后可在系统“隐私与安全性”中按 Apple 提供的单应用方式允许打开。请勿关闭整个系统的安全检查。后续维护者可使用自己的 Developer ID 签名并公证。签名检查通过不等于已经公证。

## 使用

菜单顶部直接显示“用量 / 番茄钟”切换，保持各自状态。平台按钮选择当前平台；有额外账户时显示账户选择器。用量页面右下角、更多功能按钮左侧的唯一刷新按钮更新本机任务和全部已启用平台的用量与服务状态；切换平台按需使用缓存。用量默认缓存 5 分钟；缓存保留原读取时间，失败不会假装更新成功。

Token 以 `k`（千）、`M`（百万）、`B`（十亿）显示：`12,345,678 → 12.35M`，`2,456,789,000 → 2.46B`。达到一亿时切入 `B`，所以一亿显示 `0.1B`。完整记录在导出的历史文件中；不将紧凑显示的四舍五入值用于统计。

“打开主界面”显示正在运行、全部任务、模型变化、安全缓冲和检测历史。运行状态来自本机客户端及近期未结束轮次活动；长时间没有本机活动的记录显示“活动待确认”，它不是后台任务的绝对真值。其他设备和未保存的云端会话不在本机覆盖范围。

**用量概览** 展示已成功读取的账户快照和可用图表，每账户每天保存最后一次成功快照，保留 90 天。累计 Token 曲线不能当成每日 Token 增量。仅本机设备记录会在来源和说明中明确标注。

## 重置卡与服务状态

Codex 的重置卡读取官方 `account/rateLimits/read` 返回的 `rateLimitResetCredits.availableCount`。详情列表可能省略或截断，数量始终采用汇总字段；仅保留数量和可用卡的最近到期时间，不保存兑换 ID。字段未提供时隐藏该行，不会默认为零。购买额度余额来自另一字段 `credits.balance`，不代表重置卡。余额与重置卡使用同层级、同字号文字，页面只有右下角统一刷新按钮。应用不调用兑换或消耗接口。[官方重置卡说明](https://help.openai.com/zh-hans-cn/articles/20001498-how-banked-codex-resets-work)。

服务状态按需读取公开 HTTPS，每个平台缓存 5 分钟，不附加登录凭据或账户身份。Codex 汇总 [OpenAI 状态页](https://status.openai.com/) 的全部公开组件，并结合 [OpenAI RSS](https://status.openai.com/feed.rss) 展示各产品最近事件。Antigravity 聚合 [Gemini API / AI Studio](https://aistudio.google.com/status) 全部流量层级与 [Google Cloud](https://status.cloud.google.com/) 公开状态，各来源单独标注；Google Cloud 的结果不等于 Antigravity 专属服务状态。DeepSeek 使用 [官方 RSS](https://status.deepseek.com/feed.rss)，没有未解决记录时标明“官方订阅暂无未解决事件”，不将历史订阅冒充绝对实时健康检查。OpenCode Go / WorkBuddy 没有已验证的独立官方接口，不显示状态区域；失败且没有可用事件的来源也不显示空占位。XML 限制大小并拒绝 DTD、外部实体、非官方事件链接，事件文本按纯文字展示。

新应用图标采用用户提供的深色任务列表、机器人与放大镜图案，圆角外透明；平台菜单使用各平台官方图案，并统一为单色模板；选中时使用系统蓝色。图标来源和授权见第三方说明，标志仅用于识别服务，不表示合作关系。

## 模型检测为什么有时未确认？

本机配置和轮次上下文只能说明请求了什么模型。真正可用的观察值是带明确关联的服务端模型字段或路由事件。普通 Codex 历史并不保证保存这些字段；服务端不公开的信息无法由本机软件补出。

独立核验在私有临时目录复制当前登录，使用独立工作目录与配置，不继承用户 hooks / MCP / 规则，并禁用 shell、app、web search 和多 Agent 功能；只保存白名单模型字段、响应 ID、时间和状态，不保存原始回复、认证头或完整 trace。结束和取消后清理临时文件。它不会监控已有桌面连接，也不会把该次结果套用到其他任务。

**1.3.1 修复：** 旧目录已迁移部分文件时，仍会逐文件恢复缺失核验和设置、合并模型证据。独立核验窗口显示最近核验，Codex 用量菜单不展示此结果，不把它套用于其他任务。`response.metadata` 无响应 ID 的模型响应头也可在有明确轮次关联时保存；同一响应优先采用 `openai-model` / `x-openai-model`，普通 `model` 字段保留供核对。已删除任务不会因迁移恢复。迁移在后台执行；成功后保存完成标记，后续启动无需再读同一个旧目录。

预热响应没有实际输出，不参与交付模型判断。没有输出归属、响应未完成、失败、超时、冲突字段或缺少模型时，核验保持未确认。只有本机日志不能证明服务端权重是否被替换，详见 [安全边界](SECURITY.md)。

<a id="live-model-capture"></a>

## 网络响应模型采集（1.5.0）

普通 rollout 文件通常只记录请求模型。路由事件只有发生明确切换时才出现；没有路由记录并不妨碍读取服务端模型。1.5.0 增加直接观察响应的入口，兼容服务端 WebSocket 的 `response.created` / `response.completed` 等 response 对象事件，以及 SSE 响应。不把客户端发送的 `model` 当作服务端报告，也不依赖模型自述或行为指纹。

1. 在 Model Lens 的 **设置 → 网络响应模型采集** 下载组件（约 52 MB）。普通扫描无需此组件。
2. 保存工作、结束或暂停任务，**自行退出 Codex / ChatGPT**。软件不会自动关闭运行中的客户端。
3. 点击 **以网络采集模式打开 Codex**。软件先用隔离的官方 CLI 只读查询账户，验证这条代理连接的 TLS 和账户读取；成功后才打开桌面客户端，失败时停止本次代理并显示原因，不强行启动。启动的客户端通过本机 `127.0.0.1` HTTPS 反向代理连接官方 ChatGPT 后端。
4. 在重新打开的客户端继续任务。取得带明确 `thread_id` / `turn_id` 的新响应后，模型记录进入该轮次，并显示在主界面和菜单中。后台扫描通常在 15 秒内更新，也可点击菜单右下角统一刷新。
5. 结束时先退出 Codex，再在 Model Lens 点击 **停止采集**。正常重新打开 Codex 即恢复通常连接；代理运行期间请保持 Model Lens 开启。

**1.5.1 修复登录连接：** 1.5.0 错误地把 CA 证书同时作为服务端证书，Codex 的 rustls 会报 `CaUsedAsEndEntity`。现在生成独立根 CA，并签发 `CA:FALSE`、`serverAuth`、含本机 SAN 的服务端证书；仅将根 CA 传给客户端。旧版采集导致连接失败时，请先正常打开 Codex 确认登录，再用新版采集入口。

启动仅向该客户端传递 `CODEX_APP_SERVER_CHATGPT_BASE_URL` 与 `CODEX_CA_CERTIFICATE`。桌面客户端将前者转换为 `chatgpt_base_url` 启动参数，后者使用官方 rustls 自定义 CA 机制。**不修改 `~/.codex/config.toml`、认证文件、App bundle、系统代理、钥匙串或系统信任。** 该入口针对已验证版本的官方本机客户端；第三方中转、远程任务、云端任务及其他设备暂不覆盖。客户端更新后内部启动接口可能变化。

代理临时解密、转发此客户端的 API 流量，因此认证和任务内容会经过代理内存。插件只保留模型、白名单模型响应头、任务 / 轮次 / 响应 ID 与采集时间，**不写原始抓包、不保存提示、回答、推理块、Cookie 或认证头**。匿名预热、冲突关联和缺失轮次 ID 都跳过。采集有额外 RAM / CPU 与磁盘开销，默认关闭；不发送额外模型测试请求。代理只监听 loopback，远端 TLS 保持标准验证，异常退出后子进程会检查所属主程序是否仍存在并自动停止。

可选组件是固定版本 mitmproxy 12.2.3 官方 Apple Silicon 独立包。下载后先核验固定 SHA-256；此版本官方包存在包装签名问题，软件仅对其私有副本重建 ad-hoc 签名并校验，不更改系统安全策略。组件和临时证书位于本应用私有目录，证书密钥在正常停止后清理。来源、校验值与许可见 [第三方说明](THIRD-PARTY-NOTICES.md)。

**实机验证（2026-10-01）：** 用户通过修复后的采集入口重新打开官方桌面客户端，正常任务响应的完整链路已取得两个并行任务分别上报的 `gpt-6.1-sol` 与 `gpt-6-luna`，并按任务及轮次 ID 独立关联。本软件没有为此额外发送模型测试请求；不会把一个任务的响应结果套用到另一个任务。不同客户端版本、第三方后端与其他设备的情况仍需要分别验证。

IPC 实时监听和既有日志解析仍保留作补充。原日志采集入口仅启用指定核心模块 info；实验性 trace 默认关闭，开启后 Codex 自身可能在日志中保存任务内容。新的网络采集避免依赖完整 trace 落盘。

依据：[官方进程内 CA 实现](https://github.com/openai/codex/blob/main/codex-rs/http-client/src/custom_ca.rs)、[官方 App Server 事件文档](https://developers.openai.com/codex/app-server#turn-events)。当前验证见 [VALIDATION-1.5.2.md](Documentation/VALIDATION-1.5.2.md)，历史记录见 [1.5.1](Documentation/VALIDATION-1.5.1.md) 与 [1.5.0](Documentation/VALIDATION-1.5.md)。

## 数据存放与隐私

正常运行数据位于：

```text
~/Library/Application Support/Codex Model Lens/
  settings.json                 本机检测设置
  model-history.json            任务与请求证据历史
  model-probes.json              手动核验记录
  pomodoro.json                  计时状态与自定义时长
  usage-preferences.json         平台开关、账户标签与选定账户（无秘密）
  usage-history.json             用量元数据快照
  ImportedEvidence/              导入后仅含白名单字段的证据
  NetworkEvidence/               网络响应采集的白名单模型元数据
  PrivateRuns/                   活跃 CLI 的临时私有登录目录，用后清理
  NetworkTools/                  可选采集组件与临时本机证书
```

手动账户凭据保存在 **macOS Keychain**。旧版 App 旁边的 `Data` 中有历史时，首次运行会复制受支持的历史文件到 Application Support，原文件保留。测试可用 `--data-directory` 显式隔离。

任务标题、工作目录和来源路径可能属于私人资料；导出前自行检查。软件没有遥测、广告、后台自动模型测试、浏览器密码提取或静默下载执行更新。原始 Agent 数据使用只读数据库访问。完整细节见 [SECURITY.md](SECURITY.md)。

## 从源码构建

需要 Apple Silicon Mac、macOS 26+ 和 Swift 6.2+ / macOS 26 SDK（Xcode 或适用的 Command Line Tools）。

```sh
git clone https://github.com/TakimotoUki/Codex-Model-Lens.git
cd Codex-Model-Lens
./Scripts/test.sh
./Scripts/build_release.sh
```

产物：`Distribution/Build-1.5.2/Codex Model Lens.app`、ZIP 和辅助 CLI。构建脚本优先选择安装的 macOS 26 SDK，所有缓存位于项目 `.build`，生成 arm64 包。CLI-only SwiftPM 当前使用 native 构建后端；其弃用提示不影响本次产物。

脚本默认 ad-hoc 签名。维护者可以设置 `MODEL_LENS_SIGNING_IDENTITY` 使用可用签名身份，再自行完成 Apple 公证流程。应用从 NSWorkspace 与标准安装位置发现 Agent，不包含开发者的绝对家目录。

介绍网站支持手动浅色 / 深色切换，记住选择，未手动设置时跟随系统；支持手机宽度、键盘导航与减少动态效果。

辅助 CLI：

```sh
Distribution/model-lens --summary
Distribution/model-lens --desktop-live 10 --summary
Distribution/model-lens --home /path/to/codex-home --client-offline --summary
Distribution/model-lens --account --data-directory ./Data/PrivateQA --output ./Data/codex-usage.json
Distribution/model-lens --provider antigravity --background-only --output ./Data/antigravity-usage.json
Distribution/model-lens --service-status deepseek
```

GUI 演示 / UI QA（显式假数据，不发起用量网络请求）：

```sh
'Distribution/Build-1.5.2/Codex Model Lens.app/Contents/MacOS/CodexModelLens' \
  --demo --data-directory ./Data/Demo --preview-menu \
  --preview-path ./Data/menu-demo.png
```

`--demo-long-titles --demo-tasks 2` 可检查中栏长标题和选中行；`--preview-provider antigravity` 可检查 Google 双源状态与缺失字段隐藏。`--demo-tasks 2 --demo-unconfirmed` 可检查多个较矮任务行，`--demo-tasks 8` 可检查滚动上限。`--preview-timer`、`--preview-countdown`、`--demo-empty`、`--preview-light`、`--preview-diagnostics`、`--preview-utility settings` 可组合检查。截图只捕获本应用自己的可用窗口。`--migration-audit /path/startup.json` 可输出逐文件恢复状态与已确认模型的白名单启动检查，不输出认证数据或响应正文。

## 验证与维护

实现采用增量文件游标、复用读取缓冲、只读 SQLite、按需账户读取、截止时间计时、原子写入和后台扫描。菜单栏背景扫描至少间隔 15 秒，Codex 关闭时 60 秒；计时器空闲或暂停时没有秒级 ticker，状态文件不每秒写入。

测试覆盖模型关联、伪装提示排除、安全缓冲边界、预热 / 实际输出区分、冲突响应字段、历史损坏保护、增量文件替换、Token 溢出 / 单位、平台解析、Token 去重与计时恢复。新增检查覆盖并行网络任务关联、跨轮次隔离、代理缓冲上限、SSE 分片、入站 / 出站区分、后台额度协议默认值、RSS / Atom 与 XML 安全边界。1.5.2 共 95 个 Swift 测试与 7 个代理插件测试，包含采集来源迁移、Google 状态解析与全部服务覆盖；真实数据源与验证边界见 [VALIDATION-1.5.2.md](Documentation/VALIDATION-1.5.2.md)，早期 UI / 性能记录见 [VALIDATION-1.3.md](Documentation/VALIDATION-1.3.md)。未具有凭据的平台使用离线结构测试；接口版本变化应按真实来源更新解析器。代码审核和测试不等于证明不存在任何漏洞。

源代码公开前排除 `Data`、构建缓存、发行产物、私人探测文件、原始日志和实际账户截图。Release 仅含 App；用户数据不会随安装包发布。

## 贡献与许可

MIT License。项目所有者与产品设计：**[TakimotoUki](https://github.com/TakimotoUki)**；实现、研究、测试、文档与网站：在用户指示下与 **Codex AI** 协作。详见 [AUTHORS.md](AUTHORS.md)。

感谢 [CodexBar](https://github.com/steipete/CodexBar) 的界面组织与公开数据源研究；本应用增加 Codex 模型证据工作区与独立番茄钟。相关来源与授权说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

### 网络采集来源与状态范围（1.5.2）

本机代理产生的记录标为“网络响应采集”，不再被误标为导入未认证。新增采集存于私有 `NetworkEvidence/`；旧版本在 `ImportedEvidence/` 下生成的保留 UUID 文件名仍可读取，手动导入器生成的 `evidence-<hash>.jsonl` 标为“手动导入”。这是来源说明，不是密码学认证：有权限修改本地文件的进程仍可改动元数据。明确响应字段能确定服务端对该请求上报的模型名，不能证明服务端的模型权重。

Google Gemini 状态复用官方 AI Studio 状态页的匿名 `ListIncidentsHistory` 查询，空请求 `[]`，动态读取官方公开网页客户端标识；不使用你的 Google 登录、Cookie、个人 API Key，不将网页标识写入钥匙串或历史。接口为网页内部接口，格式变化时隐藏该不可用来源；Google Cloud 使用官方 incidents JSON 和 Atom。平台用量继续走各自已授权的本机数据源。所有官方组件都参与 OpenAI 汇总，不把 ChatGPT 或 API 的事件丢弃。RSS 事件列表本身不证明每个服务都正常。
