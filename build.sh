#!/bin/zsh
# Builds a Release version of Cron (Apple Silicon + Intel) and installs it into /Applications.
#
#   ./build.sh               sign with the team set in Local.xcconfig (see Signing.xcconfig);
#                            without that file the app is signed ad hoc
#   CRON_ADHOC=1 ./build.sh  sign ad hoc (no Apple developer account needed, runs on this Mac only)

set -euo pipefail
cd "${0:A:h}"

signing=()
if [[ "${CRON_ADHOC:-0}" == "1" || ! -f Local.xcconfig ]]; then
    echo "Signing ad hoc."
    signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

xcodebuild \
    -project Cron.xcodeproj \
    -scheme Cron \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath build \
    "${signing[@]}" \
    build

ditto build/Build/Products/Release/Cron.app /Applications/Cron.app
echo "Installed /Applications/Cron.app"
