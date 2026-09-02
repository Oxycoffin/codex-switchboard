# Changelog

All notable user-facing changes are documented here.

## Unreleased

- Changed the project license to PolyForm Noncommercial 1.0.0. Noncommercial use, modification, and redistribution remain permitted; commercial use, sale, and sublicensing are not.

## 0.4.2 — 2026-09-02

- Made automatic account switching and five-hour window preparation clearly separate, opt-in settings.
- Preserved existing choices while keeping both features off by default for new or older incomplete configurations.
- Prevented an account-removal cleanup from taking down the menu-bar app on macOS 26.

## 0.4.1 — 2026-09-02

- Added the community, security, support, licensing, issue, pull-request, and continuous-integration files required for a public source repository.
- Made background window preparation opt-in on new installations.
- Added clear unofficial-project, notarization, privacy, and responsible-use notices.
- Added a billing-browser selector with isolated profiles for embedded WebKit (Safari's engine), Chrome, Edge, Brave, Vivaldi, and Opera; Opera VPN support is now optional.

## 0.4.0 — 2026-09-02

- Correctly identifies usage windows by their duration instead of their protocol position.
- Supports plans that expose only a weekly window and adapts when a five-hour window appears or disappears.
- Reorganized the documentation around the user experience, with the main guide in English and a Spanish edition.
