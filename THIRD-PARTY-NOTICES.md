# Sources and acknowledgements

This app is an independent native Swift implementation. It does not bundle CodexBar, Electron, an Agent's executable, OAuth client secrets, browser cookies or API keys.

- [CodexBar](https://github.com/steipete/CodexBar), MIT, copyright 2026 Peter Steinberger: compact menu organization, provider documentation, units and local-cost deduplication boundaries. Reference revision: `5de8b9ccfdcf3ed13d7c67e3639a2dd18d11230f`.
- [OpenAI Codex](https://github.com/openai/codex), Apache-2.0: model-routing protocol, response headers, authentication storage formats and official app-server account methods. Installed official CLI is discovered at runtime, verified by its signature and invoked in a private temporary home.
- [codex-routing-detector](https://github.com/darkdarkcocoa/codex-routing-detector): investigation of incoming WebSocket model fields prior to client handling. The probe here has its own bounded metadata parser.
- [agent-buddy-workbuddy](https://github.com/STFQ/agent-buddy-workbuddy): publicly documented personal/enterprise billing field formats. Current encrypted WorkBuddy logins use a local recorded-credit fallback, not credential decryption.
- [WorkBuddy usage documentation](https://www.workbuddy.cn/docs/workbuddy/Usage): account billing/usage remains the authoritative source for remaining credits.

SQLite is supplied by macOS. Swift, SwiftUI, AppKit, Security, CryptoKit, Charts, ScreenCaptureKit and UserNotifications are supplied by Apple. No third-party runtime package is required.

## Visual assets

- `Resources/AppIcon.png`: user-supplied task-list / robot / magnifying-glass design, edited with the built-in image generation tool to deepen the graphite background and provide transparent pixels outside the rounded tile. The tool does not expose a selectable model version; no specific Image2.5 runtime is claimed. `make_icon.swift` only scales the source into standard ICNS sizes.
- Codex / ChatGPT, DeepSeek, Antigravity and OpenCode menu glyphs: provider brand shapes distributed in CodexBar's `Sources/CodexBar/Resources/ProviderIcon-*.svg`, fetched 2026-10-01 and rasterized without changing the shapes. Included MIT notice: `Resources/ProviderIcons/CodexBar-LICENSE.txt`. Provider trademarks remain the property of their respective owners and identify the selected service.
- WorkBuddy menu glyph: the official installed app renderer’s cat-head SVG foreground, retaining path and eye geometry, removing its tile / blur decoration, and rasterized to 128 px. All provider glyphs use macOS template rendering for the same monochrome / selected-blue appearance. These bundled visual assets do not contain an executable or depend on a developer-specific installation path.
- This is an independent app, with no endorsement or partnership implied by provider marks.
