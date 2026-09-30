#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
# Source this file only from project scripts that have the same Scripts/ parent.
cd "$TASK_ROOT"
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$TASK_ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_ROOT/.build/module-cache"
TASK_DEFAULT_SDK="$(xcrun --show-sdk-path)"
TASK_SDK="${TASK_DEFAULT_SDK:h}/MacOSX26.sdk"
if [[ ! -d "$TASK_SDK" ]]; then
  TASK_SDK="$TASK_DEFAULT_SDK"
fi
SWIFT_FLAGS=(--scratch-path "$TASK_ROOT/.build" --cache-path "$TASK_ROOT/.build/cache" --config-path "$TASK_ROOT/.build/config" --security-path "$TASK_ROOT/.build/security" --disable-sandbox --build-system native --sdk "$TASK_SDK")
