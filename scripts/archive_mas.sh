#!/usr/bin/env bash
# Archive Hao Player for Mac App Store and check the exported entitlements.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/HaoPlayer.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$ROOT/build/MASExport}"
DERIVED="${DERIVED:-$ROOT/build/DerivedData}"

command -v xcodegen >/dev/null || { echo "ERROR: xcodegen not found" >&2; exit 2; }
xcodegen generate

xcodebuild archive \
  -scheme HaoPlayer \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM=M2WM2NJP68 \
  CODE_SIGN_STYLE=Automatic

rm -rf "$EXPORT_PATH"
if ! xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$ROOT/ExportOptions-MAS.plist"; then
  cat >&2 <<'EOF'
ERROR: exportArchive failed.

通常是还没有 Mac App Store 描述文件，或没有 Apple Distribution 证书。
1. https://developer.apple.com/account/resources/identifiers/list
   注册 macOS App ID：app.hao.HaoPlayer
2. Xcode → Settings → Accounts → Team M2WM2NJP68 → Manage Certificates →
   加上 Apple Distribution
3. 再跑本脚本，或打开 HaoPlayer.xcodeproj → Product → Archive →
   Distribute App → App Store Connect（Automatic 会拉描述文件）

日常调试仍用 project.yml 里的 Apple Development，不要改成 Distribution。
EOF
  exit 2
fi

APP="$(find "$EXPORT_PATH" -name 'HaoPlayer.app' -maxdepth 3 | head -n 1)"
if [[ -z "$APP" ]]; then
  echo "ERROR: exported .app not found in $EXPORT_PATH" >&2
  exit 2
fi

ENTS="$(mktemp)"
trap 'rm -f "$ENTS"' EXIT
codesign -d --entitlements "$ENTS" "$APP" >/dev/null

if grep -q 'get-task-allow' "$ENTS"; then
  echo "ERROR: exported app still has get-task-allow" >&2
  cat "$ENTS" >&2
  exit 2
fi

for key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-only \
  com.apple.security.files.bookmarks.app-scope
do
  if ! grep -q "$key" "$ENTS"; then
    echo "ERROR: missing entitlement $key" >&2
    cat "$ENTS" >&2
    exit 2
  fi
done

dylibs=0
signed=0
while IFS= read -r -d '' lib; do
  dylibs=$((dylibs + 1))
  if codesign --verify --verbose=2 "$lib" 2>/dev/null; then
    signed=$((signed + 1))
  else
    echo "ERROR: unsigned or invalid signature: $lib" >&2
    exit 2
  fi
done < <(find "$APP/Contents/Frameworks" -name '*.dylib' -print0)

if [[ "$dylibs" -eq 0 ]]; then
  echo "ERROR: no FFmpeg dylibs in $APP/Contents/Frameworks" >&2
  exit 2
fi

echo "MAS export OK: $APP"
echo "FFmpeg dylibs signed: $signed/$dylibs"
echo "entitlements: sandbox only, no get-task-allow"
