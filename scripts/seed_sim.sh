#!/usr/bin/env bash
# Creates (or resets) the dedicated Roll-QA simulator and seeds its photo library (Task 14).
# Uses the newest installed iOS runtime and its newest "Pro" iPhone (else its newest iPhone). Only Roll-QA is touched:
# it is erased on every run so the UI test starts from the same library. Prints the simulator's UDID.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME=Roll-QA
BUNDLE=com.delavalom.roll

read -r RT DEVTYPE < <(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("isAvailable") and r.get("platform") == "iOS"]
if not runtimes: sys.exit("no iOS simulator runtime installed (Xcode > Settings > Components)")
runtime = max(runtimes, key=lambda r: [int(x) for x in r["version"].split(".")])
phones = [d for d in runtime["supportedDeviceTypes"] if d.get("productFamily") == "iPhone"]
if not phones: sys.exit("the runtime supports no iPhone")
pro = [d for d in phones if d["name"].endswith(" Pro")]
print(runtime["identifier"], (pro or phones)[0]["identifier"])  # newest first
')

UDID=$(xcrun simctl list devices -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
print(next((d['udid'] for ds in devices.values() for d in ds if d['name'] == '$NAME' and d.get('isAvailable', True)), ''))
")
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl create "$NAME" "$DEVTYPE" "$RT")
else
  xcrun simctl shutdown "$UDID" 2>/dev/null || true
  xcrun simctl erase "$UDID"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null

python3 scripts/make_seed_media.py >&2
xcrun simctl addmedia "$UDID" artifacts/seed/*
# Takes effect once Roll is installed; on a fresh (erased) simulator iOS still asks, and the UI test allows it.
xcrun simctl privacy "$UDID" grant photos "$BUNDLE"
echo "$UDID"
