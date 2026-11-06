#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:-device}
VERSION=${GUIDED_VERSION:-1.0.0}
BUILD=${GUIDED_BUILD:-1}
mkdir -p build
if [ "$MODE" = simulator ]; then
  SDK=iphonesimulator
  ARCH=$(uname -m)
  DESTINATION='generic/platform=iOS Simulator'
else
  SDK=iphoneos
  ARCH=arm64
  DESTINATION='generic/platform=iOS'
fi
xcodebuild -quiet -project GuidedAssistance.xcodeproj -scheme GuidedAssistance-iOS \
  -configuration Release -sdk "$SDK" -destination "$DESTINATION" \
  -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/Packages \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ONLY_ACTIVE_ARCH=YES ARCHS="$ARCH" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build
SOURCE="build/DerivedData/Build/Products/Release-$SDK/Guided Assistance.app"
test -d "$SOURCE"
if [ "$MODE" = simulator ]; then
  APP='build/simulator/Guided Assistance.app'
else
  APP='build/Payload/Guided Assistance.app'
fi
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$SOURCE" "$APP"
python3 - "$APP" <<'PY'
from pathlib import Path
import sys
notices=[Path('THIRD_PARTY_NOTICES.md').read_text()]
for path in sorted(Path('build/Packages/checkouts').rglob('*')):
    if path.is_file() and '.git' not in path.parts and path.name.upper().split('.')[0] in {'LICENSE','LICENCE','COPYING','NOTICE'}:
        notices.append('\n'+'='*72+'\n'+str(path.relative_to('build/Packages/checkouts'))+'\n\n'+path.read_text(errors='replace'))
Path(sys.argv[1],'ThirdPartyNotices.txt').write_text('\n'.join(notices))
PY
# AltStore replaces the ad-hoc signature with the user's development signature.
if [ -d "$APP/Frameworks" ]; then
  while IFS= read -r -d '' framework; do codesign --force --sign - "$framework"; done < <(find "$APP/Frameworks" -type d -name '*.framework' -print0)
  while IFS= read -r -d '' library; do codesign --force --sign - "$library"; done < <(find "$APP/Frameworks" -type f -name '*.dylib' -print0)
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
cp Assets.xcassets/AppIcon.appiconset/icon-1024.png build/guided-assistance-icon.png
if [ "$MODE" != simulator ]; then
  rm -f build/GuidedAssistance.ipa
  (cd build && zip -qry GuidedAssistance.ipa Payload)
  python3 scripts/check_ipa.py build/GuidedAssistance.ipa "$VERSION" "$BUILD"
fi
