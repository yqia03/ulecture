#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--hardware" || "$#" -ne 2 ]]; then
  echo 'Usage: check-system-audio-hardware.sh --hardware <fresh-output-directory>' >&2
  echo 'Plays 12 seconds of fictional speech and captures system audio locally; no recordings or transcript text are saved.' >&2
  exit 2
fi
hardware_root="$(cd "$(dirname "$0")/../.." && pwd)"
hardware_out="$2"
mkdir -p "$hardware_out"
test ! -e "$hardware_out/system-audio-hardware.json"
ffmpeg -nostdin -hide_banner -loglevel error -i "$hardware_root/app/Tests/Fixtures/Audio/fictional-lecture-en.flac" \
  -t 12 -ar 48000 -ac 1 "$hardware_out/fictional-playback.wav"
xcrun swiftc -D AUDIO_TESTING -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$hardware_root/app/build/ModuleCache" -import-objc-header "$hardware_root/app/Native/ASRBridge.h" \
  "$hardware_root"/app/Sources/Audio/*.swift "$hardware_root/app/Tests/SystemAudioHardwareChecks.swift" \
  "$hardware_root/app/build/libClassroomASR.a" -lc++ -framework Accelerate -framework Metal -framework MetalKit \
  -framework AVFoundation -framework AppKit -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox \
  -framework CoreMedia -o "$hardware_out/system-audio-hardware-checks"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  "$hardware_out/system-audio-hardware-checks" --hardware "$hardware_root" "$hardware_out" "$hardware_out/fictional-playback.wav"
