# Codex Switchboard contributor rules

These rules apply to the whole repository.

## Product boundaries

- Keep the official Codex/ChatGPT application vanilla. Do not patch `app.asar`, the official executable, its signature, or its persistent conversation store.
- Keep one visual Codex instance. Authentication changes must use the external bridge and retain the safe restart fallback.
- Only the primary Codex app server may own the shared bridge runtime. Auxiliary and computer-use hosts must pass through without writing shared status or accepting switch commands.
- Never log, publish, embed, or display access tokens, refresh tokens, `auth.json`, cookies, or conversation contents.
- Attribute terminal events to the profile that owned the originating turn. A delayed event must never rotate the currently active profile by mistake.
- Keep background network activity opt-in for new installations. Do not add behavior intended to bypass service restrictions or provider terms.
- Keep billing profiles isolated by account and browser. Never make a browser-specific feature a product requirement.

## User interface and data

- Every user-visible string added or changed must ship in both Spanish and English in the same change. Static SwiftUI keys belong in both `es.lproj/Localizable.strings` and `en.lproj/Localizable.strings`; dynamic copy must use `L10n`.
- The selected language must apply immediately to the manager, menu bar, settings, alerts, and dynamic status banners. Run the visible-string checker; do not rely on manual catalog inspection.
- Keep product copy short and user-oriented. Put implementation detail in contributor documentation, not in the interface or the product overview.
- Display availability as remaining capacity from 100 to 0. Window countdowns always include seconds and use hours, minutes, and seconds as applicable.
- Apply active-account `account/rateLimits/updated` pushes immediately. Polling is only a fallback and for inactive accounts; never overwrite a newer push with older data.
- Layout changes must be checked at the minimum supported window size in both languages. No clipped, overlapping, or scrolling header content.
- Never place `TimelineView`, a per-second publisher, or another continuously invalidating view inside `MenuBarExtra`; macOS 26 can recurse through menu graph updates and crash. Use a precise snapshot in the menu and keep live ticking in the manager window.

## Required checks

- Run `node scripts/check-localizations.js`.
- Build with `./build.sh`, run the bridge protocol test, and verify the signed bundle before installation.
- Preserve the bundle identifier and signing identity so macOS App Management permission survives updates whenever the platform permits it.
- Keep the English `README.md` and Spanish `README.es.md` aligned when behavior, installation, privacy, or compatibility changes.
- Keep the main README product-oriented. Put protocol and contributor detail in `docs/ARCHITECTURE.md` and `CONTRIBUTING.md`.
