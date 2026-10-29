set shell := ["bash", "-euo", "pipefail", "-c"]

gen:
    xcodegen generate

# Build for the iOS Simulator. Pretty output only if xcbeautify is installed.
build: gen
    #!/usr/bin/env bash
    set -euo pipefail
    cmd=(xcodebuild -scheme Roll -destination 'generic/platform=iOS Simulator' build)
    if command -v xcbeautify >/dev/null; then "${cmd[@]}" | xcbeautify; else "${cmd[@]}"; fi

# RollCore unit tests on macOS; JUnit results land in Packages/RollCore/.build for `just status`.
test:
    cd Packages/RollCore && swift test --parallel --xunit-output .build/test-results.xml

# UI smoke tests on the Roll-QA simulator (run `just seed-sim` first; each run deletes 5 seeded screenshots).
uitest: gen
    xcodebuild test -scheme Roll -destination "platform=iOS Simulator,name=Roll-QA" | tail -40

# Creates or erases the Roll-QA simulator (newest iOS runtime) and seeds artifacts/seed/ into its library.
seed-sim:
    bash scripts/seed_sim.sh

# Writes STATUS.md (gitignored): the milestone checklist plus the last `just test` results.
status:
    python3 scripts/gen_status.py

# Builds for the first connected, unlocked physical iPhone (signing uses Team.xcconfig).
run-device: gen
    #!/usr/bin/env bash
    set -euo pipefail
    udid="$(python3 scripts/device_udid.py)"
    [ -n "$udid" ] || { echo "no connected physical iPhone found" >&2; exit 1; }
    xcodebuild -scheme Roll -destination "id=$udid" build

# Exit 1 is a finding, exit 2 means the check couldn't run (never a pass). Not in CI: its app build needs the GH_PAT secret.
# Checks a Release build (unsigned) has no DEBUG-only QA or UI-test code; run before every TestFlight upload.
release-check: gen
    bash scripts/check_release_no_qa.sh

# Placeholder until milestone M9 (App Store Connect, RevenueCat, internal TestFlight).
testflight:
    asc --help >/dev/null && echo "see docs/MILESTONES.md M9"
