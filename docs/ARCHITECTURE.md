# Architecture

This document is for contributors who need to understand how Switchboard cooperates with Codex without modifying the official application.

## Process model

Switchboard is made of three local components:

1. **Menu-bar manager** — owns account profiles, settings, presentation, account selection, and safe fallback switching.
2. **Live bridge** — forwards the desktop app's normal protocol to the official Codex service and provides a private control channel for authentication changes and live usage events.
3. **Pulse helper** — performs low-frequency background maintenance, including optional preparation of eligible five-hour windows while the Mac is awake.

Only the primary Codex service may own the live bridge. Auxiliary Codex processes pass directly through to the official executable so they cannot change account state or publish misleading activity.

## Data boundaries

Account authentication profiles are isolated under the Switchboard application-support directory. Codex's task history, projects, and ordinary workspace configuration remain in the shared Codex home. This separation is why authentication can change without moving or duplicating conversations.

The manager persists profile metadata, settings, validated quota snapshots, and a small event history. It does not persist conversation content in its own state. Authentication material is read only from private profile files when required and is not copied into status files or process arguments.

Billing sessions use either an embedded WebKit view with a persistent data-store identifier derived from the Switchboard account, or a selectable Chromium-family browser with an isolated user-data directory. Storage is partitioned by Switchboard account and browser, so changing the selection cannot merge cookies with another account or with the user's normal profile. The Safari app is intentionally not driven through private interfaces or UI scripting. Opera-specific VPN preparation is an optional adapter rather than a product dependency.

## Switching flow

For a live switch, the manager validates the destination session before asking the bridge to use it. The bridge changes the authentication used by subsequent requests and then the manager commits the same destination to persistent state. An in-flight network request remains owned by the account that started it.

When a task ends because of a confirmed usage limit, the event remains attributed to its originating account even if another account is already active. Switchboard can then continue the same task with the new account. If the live path is unavailable, the manager waits for a safe boundary, closes Codex normally, changes the persisted account transactionally, and reopens the official app.

## Usage windows

Protocol field position is not treated as a user-facing window type. Switchboard classifies each window by its declared duration, allowing plans with only a weekly allowance to display correctly. Older Codex versions that do not provide duration metadata retain the established positional fallback.

The active account can publish quota changes immediately through the bridge. Inactive profiles are checked separately and revalidated before automatic selection. Stored reset times are evaluated locally between checks so expired windows do not remain visually exhausted.

## Update compatibility

The integration depends on public behavior of the Codex service bundled inside the installed app, not on patched application resources. The bridge launches the official binary from the installed Codex bundle and forwards its protocol. A version mismatch or malformed response must produce a visible, non-destructive failure.

Compatibility checks should cover bridge negotiation, authentication refresh, quota events, delayed limit attribution, continuation, auxiliary-process pass-through, and both localized interfaces.

## Security invariants

- Never modify or re-sign the official Codex bundle.
- Never log or publish credentials, cookies, tokens, or conversation contents.
- Validate profile ownership before activating stored authentication.
- Keep runtime and profile directories private to the current user.
- Preserve the transactional fallback so interruption cannot leave authentication half-moved.
- Treat observed task activity and quota snapshots as time-sensitive state.
