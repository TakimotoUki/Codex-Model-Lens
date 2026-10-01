#!/bin/zsh
set -euo pipefail
source "${0:A:h}/swift_env.sh"
TASK_DEVELOPER="$(xcode-select -p)"
TASK_TEST_FRAMEWORKS="$TASK_DEVELOPER/Library/Developer/Frameworks"
TEST_FLAGS=()
if [[ -d "$TASK_TEST_FRAMEWORKS/Testing.framework" ]]; then
  TEST_FLAGS=(-Xswiftc -F -Xswiftc "$TASK_TEST_FRAMEWORKS" -Xlinker -F -Xlinker "$TASK_TEST_FRAMEWORKS" -Xlinker -rpath -Xlinker "$TASK_TEST_FRAMEWORKS")
fi
if [[ -d "$TASK_DEVELOPER/usr/lib/swift/host/plugins/testing" ]]; then
  TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TASK_DEVELOPER/usr/lib/swift/host/plugins/testing")
fi
swift test "${SWIFT_FLAGS[@]}" "${TEST_FLAGS[@]}"

if command -v python3 >/dev/null; then
  python3 Scripts/test_network_capture.py
fi
