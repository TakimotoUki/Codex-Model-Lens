# Security and privacy

Report a vulnerability privately through the repository's security reporting interface when available. Do not attach an auth file, API Key, Cookie, complete debug trace or unredacted task archive to a public issue. A minimized reproduction with fake credentials is preferred.

## What the app reads

Codex task titles, working directories, turn metadata, whitelisted routing events, response model fields/headers and request diagnostic metadata; enabled providers' quota/balance metadata; optional device-local cost/credit records. SQLite connections are read-only. Sources are not rewritten.

Saved task history contains task titles and paths. Even though the app excludes prompt/answer bodies and authorization headers from its evidence projection, an exported archive can still reveal private project information. Review it before sharing.

## Authentication boundaries

Manual accounts use the macOS Keychain and a random account UUID. A local Codex account uses its file or known Keychain authentication format. Before invoking its CLI, the app verifies OpenAI's signing identity. It copies login material to an owner-only temporary home to isolate configuration, hooks and MCP connections, removes that home afterward, and can clean stale owned runs after a crash. It never updates the original login file. Abnormally abandoned files may remain until the next account read or probe; the directory is restricted to its owner.

Incoming metadata is capped; commands have deadlines and cancellation; remote redirects are rejected; web accounts are workspace-scoped. Local Antigravity TLS acceptance is restricted to `127.0.0.1` and a port obtained from the same-user language server inside the signed installed Google app. It is never applied to remote HTTPS.

WorkBuddy encrypted authentication is not decrypted. Its fallback projects only recorded request credits from the local database. Browser credentials are not extracted; OpenCode Cookie accounts require an explicit manual value supplied by the user.

## Model identity

A server model field is a reported identity, not a cryptographic proof of model weights. Local logs and imported files can be altered. An independent probe describes only that probe and is not associated with a desktop task by timestamp. Missing fields, ambiguous associations and conflicting probe fields remain unconfirmed.

## Outbound connections

Only an explicitly opened/refreshed enabled provider is fetched. Expected remote hosts are `chatgpt.com`/OpenAI through the verified official CLI, `api.deepseek.com`, `opencode.ai`, and recognized official WorkBuddy billing hosts. Antigravity uses the local language server. No app telemetry, analytics SDK, update downloader or background model-generating request is included.
