# Security and privacy

Report a vulnerability privately through the repository's security reporting interface when available. Do not attach an auth file, API Key, Cookie, complete debug trace or unredacted task archive to a public issue. A minimized reproduction with fake credentials is preferred.

## What the app reads

Codex task titles, working directories, turn metadata, whitelisted routing events, response model fields/headers and request diagnostic metadata; enabled providers' quota/balance metadata; optional device-local cost/credit records. SQLite connections are read-only. Sources are not rewritten.

The optional desktop observer uses a same-user Unix socket with a non-writable parent directory, validates the peer UID and the running OpenAI-signed router, caps frames at 16 MiB and subscriptions at 40, and never handles task execution or approval requests. State frames can transiently contain task contents in memory; only typed model routing items at known turn paths are retained. It does not recursively scan tool output or model text. Revision gaps discard identity mappings until a fresh snapshot arrives. This desktop IPC is an internal protocol and may change with client updates.

The capture launcher refuses to close or replace a running Codex / ChatGPT client. It verifies the installed client signature and supplies a process-local RUST_LOG setting only after an explicit button click. The default uses core info logging. The separately enabled experimental trace mode may cause Codex itself to retain raw task contents in its own logs and adds overhead; this is disclosed in the UI. Model Lens still retains only whitelisted metadata. A normal relaunch restores the client default. No bundle, Codex configuration, system proxy, trust store or global environment is changed.

Saved task history contains task titles and paths. Even though the app excludes prompt/answer bodies and authorization headers from its evidence projection, an exported archive can still reveal private project information. Review it before sharing.

## Authentication boundaries

Manual accounts use the macOS Keychain and a random account UUID. A local Codex account uses its file or known Keychain authentication format. Before invoking its CLI, the app verifies OpenAI's signing identity. It copies login material to an owner-only temporary home to isolate configuration, hooks and MCP connections, removes that home afterward, and can clean stale owned runs after a crash. It never updates the original login file. Abnormally abandoned files may remain until the next account read or probe; the directory is restricted to its owner.

Incoming metadata is capped; commands have deadlines and cancellation; remote redirects are rejected; web accounts are workspace-scoped. Local Antigravity TLS acceptance is restricted to `127.0.0.1` and a port obtained from the same-user language server inside the signed installed Google app. It is never applied to remote HTTPS.

WorkBuddy encrypted authentication is not decrypted. Its fallback projects only recorded request credits from the local database. Browser credentials are not extracted; OpenCode Cookie accounts require an explicit manual value supplied by the user.

## Model identity

A server model field is a reported identity, not a cryptographic proof of model weights. Local logs and imported files can be altered. An independent probe describes only that probe and is not associated with a desktop task by timestamp. Missing fields, ambiguous associations and conflicting probe fields remain unconfirmed.

## Outbound connections

Only an explicitly opened/refreshed enabled provider is fetched. Expected remote hosts are `chatgpt.com`/OpenAI through the verified official CLI, `api.deepseek.com`, `opencode.ai`, and recognized official WorkBuddy billing hosts. Antigravity uses the local language server. No app telemetry, analytics SDK, update downloader or background model-generating request is included.
