# Codex Switchboard

**Use several Codex accounts as one continuous workspace on macOS.**

[Leer en español](README.es.md)

> [!IMPORTANT]
> Codex Switchboard is an independent, unofficial project. It is not affiliated with or endorsed by OpenAI. Users are responsible for complying with the terms that apply to every connected account and must not use Switchboard to share credentials or circumvent service restrictions.

Codex Switchboard keeps your paid accounts ready, shows how much usage each one has left, and moves Codex to an available account when the current one reaches its limit. Your tasks, projects, and conversation history stay together in the official Codex app.

## What it gives you

- One Codex window and one shared task history.
- Clear remaining usage and reset times for every connected account.
- Optional automatic switching when the active account is genuinely out of usage.
- Live switching when the bridge is available, with a safe app-restart fallback.
- Automatic recovery when every account was exhausted and one becomes available again.
- Sign-in, sign-out, account removal, plan visibility, and direct access to plan management.
- Optional preparation of five-hour windows while the Mac is awake.
- A native menu-bar app in English and Spanish, with no Dock icon.

Switchboard understands that plans do not all expose the same limits. A plan with only a weekly allowance is shown as weekly; it is never presented as a five-hour window simply because it is the first limit returned by Codex.

## How it works

Codex itself remains the app you use. Switchboard runs beside it and keeps an isolated, private sign-in profile for each account. The local Codex workspace remains shared, so changing the active account does not create another copy of the app or split your tasks.

When live switching is enabled, an external bridge sits on the standard connection between the Codex desktop interface and the Codex service bundled with the app. It forwards normal traffic unchanged and can replace the active authentication at a safe request boundary. If a limit interrupts a task, Switchboard can continue it in the same task with the next account without repeating completed work.

The bridge is external: Switchboard does not patch the Codex application, edit `app.asar`, replace the official executable, or re-sign the official bundle. Codex updates therefore install normally. If an update changes an essential protocol contract, Switchboard fails visibly and keeps the restart-based fallback instead of modifying Codex.

## Usage at a glance

1. Open Switchboard from the menu bar.
2. Add each Codex account through the official sign-in flow.
3. Choose which accounts may participate in automatic switching.
4. Enable automatic switching if you want it, or select an account manually at any time.
5. Open an account to see its plan, limits, reset times, and account actions.

The account currently used by Codex is always identified. Availability is shown as capacity remaining, from 100% down to 0%.

Automatic switching and five-hour window preparation are separate settings. Both are off on a new installation and run only after you enable them.

## Privacy and safety

All account profiles stay on this Mac under `~/Library/Application Support/Codex Switchboard` with private filesystem permissions. Switchboard never asks for a password and does not store tokens in logs, commands, the UI, or this repository. It does not copy or index conversation content.

Billing browser profiles are isolated per account. Choose the built-in WebKit browser (Safari's engine), Google Chrome, Microsoft Edge, Brave, Vivaldi, or Opera from Settings; each browser and account gets separate local storage. The Safari app itself is not automated because macOS does not expose a reliable public way to target a particular Safari profile. Opera's built-in VPN preparation is optional and appears only when Opera is selected.

## Installation

Codex Switchboard currently targets macOS 14 or later and is distributed from source. Published source builds are not notarized by Apple.

```zsh
chmod +x build.sh install.sh
./build.sh
./install.sh
```

The menu-bar app is installed in `/Applications`, and its background helper is registered for the current user. Reusing the same bundle identifier and signing identity helps macOS retain App Management permission between updates.

## Languages

The interface is available in English and Spanish. It can follow macOS automatically or be changed immediately from Settings.

## For contributors

Start with [Architecture](docs/ARCHITECTURE.md) for the process and data model, then read [Contributing](CONTRIBUTING.md) before changing the app. Repository-wide product and localization rules live in [AGENTS.md](AGENTS.md).

The official Codex app must remain untouched, account secrets must never be exposed, and every user-visible change must work in both English and Spanish.

Codex Switchboard is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, study, modify, and redistribute it for noncommercial purposes. Commercial use, sale, and sublicensing are not permitted. See the [Changelog](CHANGELOG.md), [Security](SECURITY.md), [Support](SUPPORT.md), and the [Code of Conduct](CODE_OF_CONDUCT.md) before participating.
