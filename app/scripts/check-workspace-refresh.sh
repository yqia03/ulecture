#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-workspace-refresh-XXXXXX)}"
mkdir -p "$checks_root/compile"
ditto app/Sources "$checks_root/compile/Sources"
ditto app/Native "$checks_root/compile/Native"
cp app/Tests/WorkspaceRefreshChecks.swift "$checks_root/compile/WorkspaceRefreshChecks.swift"
cp app/build/libClassroomASR.a "$checks_root/compile/libClassroomASR.a"
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$checks_root/compile/Sources" -g '*.swift' -g '!UwayClassroomApp.swift' | sort)
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache -import-objc-header "$checks_root/compile/Native/ASRBridge.h" "${sources[@]}" "$checks_root/compile/WorkspaceRefreshChecks.swift" "$checks_root/compile/libClassroomASR.a" -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security -o "$checks_root/workspace-refresh-checks"
"$checks_root/workspace-refresh-checks" --ui-test-workspace "$checks_root/workspace" --model-cache "$checks_root/workspace/models"
