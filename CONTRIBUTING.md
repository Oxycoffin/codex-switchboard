# Contributing

Thank you for helping improve Codex Switchboard. Read [Architecture](docs/ARCHITECTURE.md) and [AGENTS.md](AGENTS.md) before making changes.

## Development setup

Requirements:

- macOS 14 or later
- The official Codex desktop app installed in `/Applications/ChatGPT.app`
- Xcode Command Line Tools, Swift, Node.js, and zsh

Build and run the local checks:

```zsh
./build.sh
swiftc UsageWindows.swift tests/test-usage-windows.swift -o /tmp/codex-switchboard-window-tests
/tmp/codex-switchboard-window-tests
node tests/test-hot-bridge.js "build/Codex Switchboard.app/Contents/Helpers/CodexHotBridge" tests/fake-codex.js
node tests/test-auxiliary-passthrough.js "build/Codex Switchboard.app/Contents/Helpers/CodexHotBridge" tests/fake-codex.js
```

Install a verified local build with `./install.sh`.

## Product rules

- Keep the official Codex app vanilla and preserve the safe fallback path.
- Keep the interface concise and written for users rather than implementers.
- Add every visible string in English and Spanish in the same change.
- Verify layouts at the minimum window size in both languages.
- Preserve account isolation, shared task history, and event attribution to the originating account.
- Do not commit local profiles, authentication material, browser data, build products, or screenshots containing personal account data.

## Pull requests

Describe the user-visible outcome first, followed by implementation notes and verification. Include screenshots for meaningful UI changes and identify any validation that still requires a real Codex account or a future app version.
