#!/usr/bin/env bash
# Device QA (docs/qa/device-2026-10-23.md): pulls Roll's identifier-free QA files from the phone and exports the screenshots
# from an xcresult into artifacts/qa/ (gitignored: the screenshots show the user's photos).
#   scripts/qa_pull.sh <udid> [result.xcresult ...]
set -euo pipefail
udid="${1:?usage: qa_pull.sh <udid> [xcresult ...]}"; shift
out=artifacts/qa
mkdir -p "$out/device" "$out/shots"
xcrun devicectl device copy from --device "$udid" --domain-type appDataContainer \
  --domain-identifier com.delavalom.roll --source Documents/qa --destination "$out/device" >/dev/null
echo "pulled: $(ls "$out/device" | tr '\n' ' ')"
for result in "$@"; do
  dir="$out/shots/$(basename "$result" .xcresult)"
  mkdir -p "$dir"
  xcrun xcresulttool export attachments --path "$result" --output-path "$dir" >/dev/null
  # Name each file after its XCTest attachment name.
  python3 - "$dir" <<'PY'
import json, os, sys
d = sys.argv[1]
manifest = json.load(open(os.path.join(d, "manifest.json")))
for test in manifest:
    for a in test.get("attachments", []):
        src = os.path.join(d, a["exportedFileName"])
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        base, ext = os.path.splitext(a["exportedFileName"])
        clean = name.split("_0_")[0] if "_0_" in name else os.path.splitext(name)[0]
        dst = os.path.join(d, clean + ext)
        if os.path.exists(src) and not os.path.exists(dst):
            os.rename(src, dst)
PY
  echo "exported: $dir ($(ls "$dir" | wc -l | tr -d ' ') files)"
done
