#!/usr/bin/env bash
# Builds Roll in Release (unsigned) and checks that none of the DEBUG-only device-QA and UI-test code shipped: QA
# types, launch arguments, metrics event names, the keep-awake idle-timer call and the RevenueCat Test Store key.
# Run it before every TestFlight upload (`just release-check`). Needs about 2 GB free and Roll.xcodeproj (`just gen`).
#
# Exit 0: clean. Exit 1: a finding. Exit 2: the check itself couldn't run (build failed, no Release product, the scan
# can't see the app's own strings); never read that as a pass.
#
# Swift may fold string literals of 15 bytes or fewer into code in an optimized build, so short event names are a
# best-effort check; the type names (symbols and Swift metadata) and the longer strings are what really cover it.
set -euo pipefail
cd "$(dirname "$0")/.."

harness() { echo "ERROR: $*" >&2; exit 2; }

for tool in xcodebuild strings file; do command -v "$tool" >/dev/null || harness "$tool not found"; done
[ -d Roll.xcodeproj ] || harness "Roll.xcodeproj is missing: run 'just gen' first"

out=build/dd-release-check
rm -rf "$out"
trap 'rm -rf "$out"' EXIT
xcodebuild build -scheme Roll -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$out" \
  CODE_SIGNING_ALLOWED=NO -quiet || harness "the Release build failed"

app="$out/Build/Products/Release-iphoneos/Roll.app"
binary="$app/Roll"
[ -d "$app" ] || harness "no Release product at $app"
[ -f "$binary" ] || harness "no executable at $binary"
file -b "$binary" | grep -q "Mach-O 64-bit executable arm64" || harness "$binary is not an arm64 executable: $(file -b "$binary")"

dump=$(mktemp)
trap 'rm -rf "$out" "$dump"' EXIT
strings -a "$binary" > "$dump"

# Controls: strings the Release app must contain (one from the app, one from RollCore). If the scan can't see them,
# it can't see QA strings either.
for control in "Sizes are estimates. Deleted items stay in Recently Deleted" "SELECT newAssetID FROM squishJournal"; do
  grep -qF -- "$control" "$dump" || harness "the scan can't see '$control' in the Release binary"
done

needles=(
  # Types and helpers (App/QA, RollCore's #if DEBUG files).
  "QARuntime" "QAEventLog" "QAMetrics" "QAPause" "QACounters" "QALibrary" "QASquishAudit" "QAInventory"
  "QAThumbProbe" "QAKeepAwake" "QAController" "QADebugOverlay" "QAScopeGate" "QAReadOnlyGate" "QAAlbumGate"
  "QAScopeViolation" "QASquishHooks" "QAStoreStats" "QAMediaProbe" "QADolbyVisionExperiment" "qaScoped"
  "resetForUITests" "UITestResetOutcome" "PhotoKitFingerprint" "QARestock" "QARestockRoom" "removeFromQAAlbum"
  # Launch arguments.
  "-QAAlbum" "-QAMetrics" "-QAPauseBeforeSquishDelete" "-QAFakeAvailableBytes" "-QAThumbProbe" "-QAExhaustFreeQuota"
  "-QADolbyVisionExperiment" "-QARestock" "-QASquishStartEmpty" "-RCTestStore" "-UITestStubEmbedder" "-UITestSkipPaywall" "-UITestResetState"
  "-UITestOpen" "-UITestTab"
  # Fixed QA text, files and accessibility identifiers. (Not a bare "RCTestStore": RevenueCat itself has
  # @objc(RCTestStore). The Test Store key is checked in Info.plist below.)
  "QA scope" "metrics.jsonl" "qa.continueDelete" "com.delavalom.roll.qa" "qa-restock" "qa.restock" "QA restock"
  "remove from the QA album"
  # Metrics event names (QAEventLog.write).
  "qa_gate" "qa_config_error" "qa_fake_space" "qa_exhaust_quota" "ui_test_reset" "locality_scan" "types_resolved"
  "upgrade_pass" "squish_before_delete" "squish_prepared" "squish_failed" "squish_commit" "squish_copy_after_delete"
  "squish_catalog" "index_batch" "index_run" "store_stats" "library_totals" "sync_read" "signal_timing"
  "thumb_probe" "album_inventory" "dv_experiment" "keep_awake" "qa_restock"
  # The keep-awake call (QAKeepAwake).
  "setIdleTimerDisabled:"
)
fail=0
for needle in "${needles[@]}"; do
  n=$(grep -cF -- "$needle" "$dump" || true)
  if [ "$n" != "0" ]; then echo "FAIL: '$needle' found $n times in the Release binary"; fail=1; fi
done

key=$(/usr/libexec/PlistBuddy -c "Print :RCTestStoreKey" "$app/Info.plist" 2>/dev/null || true)
if [ -n "$key" ]; then echo "FAIL: RCTestStoreKey is not empty in Release"; fail=1; fi

[ "$fail" = 0 ] && echo "PASS: Release has no device-QA or UI-test code, no idle-timer call and an empty Test Store key"
exit "$fail"
