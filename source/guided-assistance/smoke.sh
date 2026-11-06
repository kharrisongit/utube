#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash build.sh simulator
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(v["udid"] for devices in d["devices"].values() for v in devices if v["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE" || true
xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" 'build/simulator/Guided Assistance.app'
xcrun simctl launch "$DEVICE" com.kharrison.guidedassistance --smoke-test
DATA=$(xcrun simctl get_app_container "$DEVICE" com.kharrison.guidedassistance data)
REPORT="$DATA/Library/Application Support/GuidedAssistance/simulator-check.json"
for attempt in {1..30}; do
  if [ -f "$REPORT" ]; then break; fi
  sleep 2
done
test -f "$REPORT"
cp "$REPORT" build/simulator-check.json
python3 - "$REPORT" <<'PY'
import json,pathlib,sys
report=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report['status']=='passed',report
print('Native import, search, revision, encrypted-backup, and persistence checks passed.')
PY
xcrun simctl io "$DEVICE" screenshot build/guided-assistance-screenshot.png
xcrun simctl terminate "$DEVICE" com.kharrison.guidedassistance
