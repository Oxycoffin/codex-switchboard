#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_app="$project_dir/build/Codex Switchboard.app"
installed_app="/Applications/Codex Switchboard.app"
agent="$HOME/Library/LaunchAgents/local.codex.switchboard.pulse.plist"
user_domain="gui/$(id -u)"
signing_identity="${CODEX_SWITCHBOARD_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$signing_identity" ]] || signing_identity="-"

if [[ ! -d "$source_app" ]]; then
  "$project_dir/build.sh"
fi
pkill -x CodexSwitchboard 2>/dev/null || true
ditto --noextattr "$source_app" "$installed_app"
# ditto merges bundles; remove this retired resource so an update cannot keep
# executing a BrowserBridge left by an older installation.
if [[ ! -d "$source_app/Contents/Resources/BrowserBridge" && -d "$installed_app/Contents/Resources/BrowserBridge" ]]; then
  find "$installed_app/Contents/Resources/BrowserBridge" -depth -delete
fi
xattr -cr "$installed_app"
xattr -d com.apple.FinderInfo "$installed_app" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$installed_app" 2>/dev/null || true
codesign --force --deep --sign "$signing_identity" "$installed_app"
codesign --verify --deep --strict "$installed_app"
mkdir -p "$HOME/Library/LaunchAgents"
cp "$project_dir/local.codex.switchboard.pulse.plist" "$agent"
launchctl bootout "$user_domain" "$agent" 2>/dev/null || true
launchctl bootstrap "$user_domain" "$agent"
launchctl kickstart "$user_domain/local.codex.switchboard.pulse"
launchctl setenv CODEX_CLI_PATH "$installed_app/Contents/Helpers/CodexHotBridge"

echo "Instalado: $installed_app"
echo "Agente: $agent"
echo "Bridge preparado para el próximo inicio de Codex (la instancia actual no se interrumpe)."
