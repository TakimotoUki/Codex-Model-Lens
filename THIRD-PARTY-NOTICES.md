# Sources and acknowledgements

This app is an independent native Swift implementation. It does not bundle CodexBar, Electron, an Agent's executable, OAuth client secrets, browser cookies or API keys.

- [CodexBar](https://github.com/steipete/CodexBar), MIT, copyright 2026 Peter Steinberger: compact menu organization, provider documentation, units and local-cost deduplication boundaries. Reference revision: `5de8b9ccfdcf3ed13d7c67e3639a2dd18d11230f`.
- [OpenAI Codex](https://github.com/openai/codex), Apache-2.0: model-routing protocol, response headers, authentication storage formats and official app-server account methods. Installed official CLI is discovered at runtime, verified by its signature and invoked in a private temporary home.
- [codex-routing-detector](https://github.com/darkdarkcocoa/codex-routing-detector): investigation of incoming WebSocket model fields prior to client handling. The probe here has its own bounded metadata parser.
- [agent-buddy-workbuddy](https://github.com/STFQ/agent-buddy-workbuddy): publicly documented personal/enterprise billing field formats. Current encrypted WorkBuddy logins use a local recorded-credit fallback, not credential decryption.
- [WorkBuddy usage documentation](https://www.workbuddy.cn/docs/workbuddy/Usage): account billing/usage remains the authoritative source for remaining credits.

SQLite is supplied by macOS. Swift, SwiftUI, AppKit, Security, CryptoKit, Charts, ScreenCaptureKit and UserNotifications are supplied by Apple. No third-party runtime package is required in the default monitoring mode. Optional network response capture downloads the standalone mitmproxy runtime described below.

## Visual assets

- `Resources/AppIcon.png`: user-supplied task-list / robot / magnifying-glass design, edited with the built-in image generation tool to deepen the graphite background and provide transparent pixels outside the rounded tile. The tool does not expose a selectable model version; no specific Image2.5 runtime is claimed. `make_icon.swift` only scales the source into standard ICNS sizes.
- Codex / ChatGPT, DeepSeek, Antigravity and OpenCode menu glyphs: provider brand shapes distributed in CodexBar's `Sources/CodexBar/Resources/ProviderIcon-*.svg`, fetched 2026-10-01 and rasterized without changing the shapes. Included MIT notice: `Resources/ProviderIcons/CodexBar-LICENSE.txt`. Provider trademarks remain the property of their respective owners and identify the selected service.
- WorkBuddy menu glyph: the official installed app renderer’s cat-head SVG foreground, retaining path and eye geometry, removing its tile / blur decoration, and rasterized to 128 px. All provider glyphs use macOS template rendering for the same monochrome / selected-blue appearance. These bundled visual assets do not contain an executable or depend on a developer-specific installation path.
- This is an independent app, with no endorsement or partnership implied by provider marks.

## Optional network component

- [mitmproxy 12.2.3](https://github.com/mitmproxy/mitmproxy/releases/tag/v12.2.3), MIT, copyright 2013 Aldo Cortesi. The official standalone arm64 distribution includes its own dependency notices. Model Lens does not bundle the executable in its base release; the explicit setup action downloads it into the app-owned directory. The locally written metadata-only observer is `Resources/NetworkCapture/model_capture.py`.
- Official archive: `https://downloads.mitmproxy.org/12.2.3/mitmproxy-12.2.3-macos-arm64.tar.gz`.
- Fixed SHA-256: `0a09ee3b82569e8985aff8186e4792618b8e5d0c766098db093d09a87d4b013a`, checked against the [Homebrew cask recipe](https://github.com/Homebrew/homebrew-cask/blob/main/Casks/m/mitmproxy.rb) and the downloaded archive.
- MIT notice: `Resources/NetworkCapture/mitmproxy-LICENSE.txt`. The complete downloaded application and its dependency notices are preserved. Because this exact upstream archive's package signatures do not validate, the app rebuilds ad-hoc signatures only on its private verified copy, retaining existing entitlements/runtime flags. This does not establish Developer ID notarization; see SECURITY.md.
- Official Codex [custom CA support](https://github.com/openai/codex/blob/main/codex-rs/http-client/src/custom_ca.rs) supplies process-local trust for the capture session. No system trust store is changed.
