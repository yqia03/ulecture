#!/bin/bash
set -euo pipefail
app_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_root="${1:-$(mktemp -d /private/tmp/ulecture-babeldoc-controller-XXXXXX)}"
mkdir -p "$checks_root/compile"
ditto "$app_root/Sources/Cloud" "$checks_root/compile/Cloud"
ditto "$app_root/Sources/Conversion" "$checks_root/compile/Conversion"
cp "$app_root/Tests/CloudFeatureChecks.swift" "$app_root/Tests/BabelDOCControllerChecks.swift" "$checks_root/compile/"
xcrun swiftc -D DOCUMENT_TRANSLATION_TESTING -swift-version 5 -target arm64-apple-macos14.0 "$checks_root"/compile/Cloud/*.swift "$checks_root"/compile/Conversion/*.swift "$checks_root/compile/CloudFeatureChecks.swift" "$checks_root/compile/BabelDOCControllerChecks.swift" -o "$checks_root/babeldoc-controller-checks"
"$checks_root/babeldoc-controller-checks" "$app_root/.." "$checks_root"
