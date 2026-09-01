# Codex Switchboard

[Documentación en español](README.md)

A local multi-account manager for Codex on macOS. It keeps a single visual instance of the official app, uses the bundled Codex app server for identity and usage data, and preserves one shared conversation store.

## Highlights

- Keeps each account session in a private profile while conversations, projects, and configuration remain in `~/.codex`.
- Shows the detected identity, plan, five-hour availability, and weekly availability throughout the UI and menu bar.
- Displays remaining capacity from 100 to 0. Reset countdowns update every second and always include seconds, plus minutes and hours when applicable.
- Applies live `account/rateLimits/updated` notifications to the active account immediately. Inactive accounts use a 15-second fallback poll and are revalidated before automatic selection.
- Switches authentication through an external stdio bridge without modifying the official application, its signature, or `app.asar`. The safe restart mechanism remains as a fallback.
- Associates terminal events with the account that started each turn. A delayed usage-limit event cannot trigger a second switch against the account that is now active.
- Can prepare clean five-hour windows with a minimal `OK` interaction. The model and reasoning effort are selectable and default to `gpt-5.6-luna` / `low`.
- Supports sign-in, sign-out, account deletion, rotation exclusion, and isolated Opera billing profiles.

## Privacy and update safety

Tokens are never placed in command files, process arguments, logs, UI, or this repository. The bridge receives a private profile path, validates it, and reads authentication only in memory. Conversation content is not copied or indexed by Switchboard.

The official Codex application remains vanilla. Compatibility depends only on the external app-server protocol and authentication contract; an incompatible update produces a visible safe failure instead of modifying official files or credentials.

## Build and test

```zsh
chmod +x build.sh
./build.sh
swiftc -O CodexHotBridge.swift -o /tmp/CodexHotBridge
node tests/test-hot-bridge.js /tmp/CodexHotBridge tests/fake-codex.js
node tests/test-auxiliary-passthrough.js /tmp/CodexHotBridge tests/fake-codex.js
```

The signed bundle is written to `build/Codex Switchboard.app`. The build validates that Spanish and English contain the same localization keys. A stable `Apple Development` identity is reused when available to preserve macOS App Management authorization across reinstalls.

Install locally with `./install.sh`.

## Compatibility

Version 0.3.5 is validated against the local Codex 0.151.0-alpha.7.2 protocol. The bridge regression test covers external authentication, token refresh, live usage notifications, continuation, and delayed limit events attributed to the originating account. Auxiliary Codex hosts pass through to the official binary and cannot claim the primary control channel. The menu bar uses a precise snapshot to avoid the SwiftUI recursion caused by `TimelineView` inside `MenuBarExtra` on macOS 26; the manager window still updates every second.

## Contributing

Repository-wide requirements are documented in `AGENTS.md`. Every user-visible change must ship in Spanish and English, and behavior or compatibility changes must update both READMEs.
