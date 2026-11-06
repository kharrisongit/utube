#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" != --skip-build ]; then bash build.sh simulator; fi
DEVICE=$(xcrun simctl list devices available -j | python3 -c 'import json,re,sys; d=json.load(sys.stdin)["devices"]; runtimes=sorted(d,key=lambda value:tuple(map(int,re.findall(r"\d+",value))),reverse=True); print(next(v["udid"] for runtime in runtimes for v in d[runtime] if v.get("isAvailable") and v["name"].startswith("iPhone")))')
xcrun simctl boot "$DEVICE" || true
python3 - "$DEVICE" <<'PY'
import subprocess,sys
try:
    subprocess.run(['xcrun','simctl','bootstatus',sys.argv[1],'-b'],check=True,timeout=180)
except subprocess.TimeoutExpired:
    subprocess.run(['xcrun','simctl','list','devices','available'],check=False)
    raise SystemExit('The simulator did not boot within three minutes.')
PY
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
