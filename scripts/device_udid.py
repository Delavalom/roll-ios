#!/usr/bin/env python3
"""Print the UDID of the first connected physical iPhone, or exit 1 with a message."""
import json, subprocess, sys, tempfile, os

with tempfile.TemporaryDirectory() as tmp:
    out = os.path.join(tmp, "devices.json")
    subprocess.run(["xcrun", "devicectl", "list", "devices", "--quiet", "--json-output", out], check=True)
    devices = json.load(open(out))["result"]["devices"]

for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if (d.get("visibilityClass") != "simulators" and hw.get("platform") == "iOS"
            and hw.get("deviceType") == "iPhone" and conn.get("tunnelState") == "connected" and hw.get("udid")):
        print(hw["udid"])
        sys.exit(0)
sys.exit("no connected physical iPhone found (connect and unlock one, then retry)")
