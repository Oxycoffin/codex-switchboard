#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
staging_root="$(mktemp -d /tmp/codex-switchboard-build.XXXXXX)"
trap 'rm -rf "$staging_root"' EXIT
source_root="$staging_root/Sources"
app_dir="$staging_root/Codex Switchboard.app"
output_app="$build_dir/Codex Switchboard.app"
signing_identity="${CODEX_SWITCHBOARD_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)}"
[[ -n "$signing_identity" ]] || signing_identity="-"

verify_copied_bundle() {
  local bundle="$1"
  local attempt
  # File Provider can attach Finder metadata immediately after a bundle is
  # copied into Documents. Remove it and retry the strict check until the copy
  # has settled; this does not alter signed bundle contents.
  for attempt in {1..20}; do
    xattr -cr "$bundle"
    xattr -d com.apple.FinderInfo "$bundle" 2>/dev/null || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle" 2>/dev/null || true
    if codesign --verify --deep --strict "$bundle" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  codesign --verify --deep --strict --verbose=2 "$bundle"
}

mkdir -p "$source_root" "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
node "$project_dir/scripts/check-localizations.js"
node "$project_dir/scripts/check-visible-localizations.js"
node "$project_dir/scripts/check-menu-safety.js"
for source in CodexSwitchboard.swift Pulse.swift CodexHotBridge.swift make_icon.swift Info.plist; do
  cp "$project_dir/$source" "$source_root/$source"
done
cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
cp -R "$project_dir/es.lproj" "$project_dir/en.lproj" "$app_dir/Contents/Resources/"
swift "$source_root/make_icon.swift" "$build_dir/icon-1024.png"
iconset="$build_dir/CodexSwitchboard.iconset"
mkdir -p "$iconset"
sips -z 16 16 "$build_dir/icon-1024.png" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$build_dir/icon-1024.png" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$build_dir/icon-1024.png" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$build_dir/icon-1024.png" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$build_dir/icon-1024.png" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$build_dir/icon-1024.png" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$build_dir/icon-1024.png" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$build_dir/icon-1024.png" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$build_dir/icon-1024.png" --out "$iconset/icon_512x512.png" >/dev/null
cp "$build_dir/icon-1024.png" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$app_dir/Contents/Resources/CodexSwitchboard.icns"
swiftc -parse-as-library -O -framework SwiftUI -framework AppKit \
  "$source_root/CodexSwitchboard.swift" \
  -o "$app_dir/Contents/MacOS/CodexSwitchboard"
swiftc -O -framework AppKit "$source_root/Pulse.swift" \
  -o "$app_dir/Contents/Helpers/CodexSwitchboardPulse"
swiftc -O "$source_root/CodexHotBridge.swift" \
  -o "$app_dir/Contents/Helpers/CodexHotBridge"
xattr -cr "$app_dir"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
codesign --force --deep --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
rm -rf "$output_app"
ditto --noextattr "$app_dir" "$output_app"
xattr -cr "$output_app"
xattr -d com.apple.FinderInfo "$output_app" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$output_app" 2>/dev/null || true
verify_copied_bundle "$output_app"
echo "$output_app"
