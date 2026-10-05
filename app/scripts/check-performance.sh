#!/bin/bash
set -euo pipefail
performance_main() {
performance_root="$(cd "$(dirname "$0")/../.." && pwd)"
performance_out="${1:?Pass fresh output directory}"
performance_source="${PERFORMANCE_SOURCE_ROOT:-$performance_root}"
mkdir -p "$performance_out/compile"
if [[ -z "${PERFORMANCE_REUSE_EXECUTABLE:-}" ]]; then
ditto "$performance_source/app/Sources" "$performance_out/compile/Sources"
ditto "$performance_source/app/Native" "$performance_out/compile/Native"
cp "$performance_root/app/Tests/PerformanceChecks.swift" "$performance_out/compile/PerformanceChecks.swift"
cp "$performance_root/app/build/libClassroomASR.a" "$performance_out/compile/libClassroomASR.a"
performance_sources=()
while IFS= read -r file; do performance_sources+=("$file"); done < <(rg --files "$performance_out/compile/Sources" -g '*.swift' -g '!UwayClassroomApp.swift' | sort)
shasum -a 256 "${performance_sources[@]}" "$performance_out/compile/PerformanceChecks.swift" "$performance_out/compile/libClassroomASR.a" > "$performance_out/source-sha256.txt"
performance_defines=(-D AUDIO_TESTING)
if [[ "$performance_source" == "$performance_root" ]]; then performance_defines+=(-D PERFORMANCE_CURRENT); fi
xcrun swiftc "${performance_defines[@]}" -swift-version 5 -whole-module-optimization -O -target arm64-apple-macos14.0 -module-cache-path "$performance_root/app/build/ModuleCache" -import-objc-header "$performance_out/compile/Native/ASRBridge.h" "${performance_sources[@]}" "$performance_out/compile/PerformanceChecks.swift" "$performance_out/compile/libClassroomASR.a" -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security -framework Vision -o "$performance_out/performance-checks"
else
 cp "$PERFORMANCE_REUSE_EXECUTABLE" "$performance_out/performance-checks"
 if [[ -f "$(dirname "$PERFORMANCE_REUSE_EXECUTABLE")/source-sha256.txt" ]]; then cp "$(dirname "$PERFORMANCE_REUSE_EXECUTABLE")/source-sha256.txt" "$performance_out/source-sha256.txt"; fi
fi
shasum -a 256 "$performance_out/performance-checks" > "$performance_out/executable-sha256.txt"
if [[ "${PERFORMANCE_COMPILE_ONLY:-0}" == 1 ]]; then exit 0; fi
performance_options=(--ui-test-preferences "local.ulecture.performance.$(basename "$performance_out")" --dataset "${PERFORMANCE_DATASET:-smoke}" --ui-test-workspace "${PERFORMANCE_WORKSPACE:-$performance_out/workspace}" --model-cache "$performance_out/model-cache" --output "$performance_out" --project "$performance_root" --seconds "${PERFORMANCE_SECONDS:-60}")
if [[ -n "${PERFORMANCE_AUDIO:-}" ]]; then performance_options+=(--audio "$PERFORMANCE_AUDIO" --audio-language "${PERFORMANCE_AUDIO_LANGUAGE:-en}"); fi
if [[ "${PERFORMANCE_PRODUCTION_WORKLOAD:-0}" == 1 ]]; then performance_options+=(--production-workload); fi
if [[ "${PERFORMANCE_LONG_ONLY:-0}" == 1 ]]; then performance_options+=(--long-only); fi
if [[ "${PERFORMANCE_BASELINE_NORMAL_EXIT:-0}" == 1 ]]; then performance_options+=(--baseline-normal-exit); fi
if [[ -n "${PERFORMANCE_START_BARRIER:-}" ]]; then performance_options+=(--start-barrier "$PERFORMANCE_START_BARRIER"); fi
if [[ -n "${PERFORMANCE_MODE:-}" ]]; then performance_options+=(--mode "$PERFORMANCE_MODE"); fi
if [[ "${PERFORMANCE_STARTUP_ONLY:-0}" == 1 ]]; then
 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$performance_out/performance-checks" "${performance_options[@]}" --mode startup --startup-output startup-fixture-setup-excluded.json
 for ((performance_i=1; performance_i<=${PERFORMANCE_STARTUPS:-10}; performance_i++)); do
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$performance_out/performance-checks" "${performance_options[@]}" --mode startup --startup-output "startup-$performance_i.json"
 done
 exit 0
fi
/usr/bin/caffeinate -dims /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$performance_out/performance-checks" "${performance_options[@]}"
if [[ -f "$performance_out/identity.json" ]]; then
 /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$performance_out/performance-checks" "${performance_options[@]}" --mode reopen
fi

if [[ "${PERFORMANCE_STARTUPS:-0}" -gt 0 ]]; then
 for ((performance_i=1; performance_i<=PERFORMANCE_STARTUPS; performance_i++)); do
  /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$performance_out/performance-checks" "${performance_options[@]}" --mode startup --startup-output "startup-$performance_i.json"
 done
fi

}
performance_main "$@"
