#!/bin/bash
set -euo pipefail
# Development-only fixtures; never included in the .app. ffmpeg is a build/QA tool.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES="$HOME/Library/Containers/app.hao.HaoPlayer/Data/Library/Application Support/EnhancementAcceptance"
mkdir -p "$FIXTURES"
if [[ "${1:-}" == "prepare" ]]; then
  for rate in 24 30; do
    ffmpeg -hide_banner -loglevel error -y -ss 10 -i "$HOME/Downloads/20260813_124251.mp4" -t 15 -vf "fps=$rate" -c:v h264_videotoolbox -b:v 4M -c:a aac "$FIXTURES/base$rate.mp4"
    ffmpeg -hide_banner -loglevel error -y -stream_loop -1 -i "$FIXTURES/base$rate.mp4" -t 630 -c copy "$FIXTURES/1080p$rate.mp4"
  done
  ffmpeg -hide_banner -loglevel error -y -ss 20 -i "$HOME/Downloads/sample_1280x720_surfing_with_audio.mkv" -t 15 -vf fps=24 -c:v h264_videotoolbox -b:v 3M -c:a aac "$FIXTURES/base720.mp4"
  ffmpeg -hide_banner -loglevel error -y -stream_loop -1 -i "$FIXTURES/base720.mp4" -t 630 -c copy "$FIXTURES/720p24.mkv"
  exit
fi
cd "$ROOT"
# The XCTest host receives extra test entitlements, so use a standalone Release app.
DERIVED="/private/tmp/hao-enhancement-gate"
APP="$DERIVED/Build/Products/Release/HaoPlayer.app"
if pgrep -f "^$APP/Contents/MacOS/HaoPlayer" >/dev/null; then
  echo "Acceptance app is already running; do not overwrite its embedded libraries." >&2
  exit 1
fi
xcodegen generate
xcodebuild -scheme HaoPlayer -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" SWIFT_ACTIVE_COMPILATION_CONDITIONS=ENHANCEMENT_ACCEPTANCE build
python3 - "$FIXTURES" "${HAO_ACCEPTANCE_SECONDS:-600}" "${HAO_ACCEPTANCE_CASE:-}" <<'PYREQUEST'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
request = {"seconds": float(sys.argv[2])}
if sys.argv[3]: request["cases"] = [sys.argv[3]]
(folder / "request.json").write_text(json.dumps(request))
for name in ["finished.txt", "error.txt", "outcomes.json"]:
    (folder / name).unlink(missing_ok=True)
PYREQUEST
codesign -d --entitlements :- "$APP" > "$FIXTURES/entitlements.plist"
open -n "$APP"
started=$SECONDS
while [[ ! -f "$FIXTURES/finished.txt" ]]; do
  if [[ -f "$FIXTURES/error.txt" ]]; then cat "$FIXTURES/error.txt" >&2; exit 1; fi
  if (( SECONDS - started > 15 )) && ! pgrep -f "^$APP/Contents/MacOS/HaoPlayer" >/dev/null; then
    echo "Acceptance app exited without a completed report." >&2
    exit 1
  fi
  sleep 1
done
python3 - "$FIXTURES/outcomes.json" <<'PYRESULT'
import json, sys
results = json.load(open(sys.argv[1]))
for result in results: print(result)
sys.exit(0 if results and all(r.get("passed", True) for r in results) else 1)
PYRESULT
