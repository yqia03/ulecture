#!/bin/bash
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_ROOT="${1:-$APP_DIR/Native}"
mkdir -p "$APP_DIR/build"
# Multiple isolated checks may request the native archive at once. Serialize
# construction and publish only a complete archive to concurrent consumers.
if [[ "${UL_ENGINE_BUILD_LOCKED:-0}" != "1" ]]; then
  exec python3 - "$APP_DIR" "$NATIVE_ROOT" <<'PY'
import fcntl, os, pathlib, subprocess, sys
root, native = sys.argv[1:]
with open(pathlib.Path(root) / 'build/engine-build.lock', 'w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    result = subprocess.run(['/bin/bash', str(pathlib.Path(root) / 'scripts/build-engine.sh'), native],
                            env=dict(os.environ, UL_ENGINE_BUILD_LOCKED='1'))
    raise SystemExit(result.returncode)
PY
fi
SRC="$APP_DIR/Dependencies/whisper.cpp-927cfce34f31707e17f2bff35c349632fb9e2c3a"
CMAKE="$APP_DIR/Dependencies/cmake-3.31.6/bin/cmake"
if [[ ! -x "$CMAKE" ]]; then CMAKE="$(command -v cmake || true)"; fi
[[ -x "$CMAKE" ]] || { echo 'CMake 3.31.6 is required. Set up the documented project-local tool.' >&2; exit 1; }
ARCHIVE_HASH="$(/usr/bin/shasum -a 256 "$APP_DIR/Dependencies/whisper.cpp-927cfce.tar.gz" | /usr/bin/cut -d ' ' -f 1)"
[[ "$ARCHIVE_HASH" == '41b664fee09e79176ac277b5237debec34f8d74af3c7d71f333f1ec67989ecde' ]] || { echo 'Pinned source archive checksum failed.' >&2; exit 1; }
[[ -d "$SRC" ]] || tar -xf "$APP_DIR/Dependencies/whisper.cpp-927cfce.tar.gz" -C "$APP_DIR/Dependencies"
"$CMAKE" -S "$SRC" -B "$APP_DIR/build/engine" -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_C_FLAGS="-ffile-prefix-map=$APP_DIR=/ULecture/app" -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$APP_DIR=/ULecture/app" \
 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DGGML_NATIVE=OFF \
 -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF \
 -DWHISPER_BUILD_SERVER=OFF -DWHISPER_CURL=OFF -DWHISPER_COREML=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
"$CMAKE" --build "$APP_DIR/build/engine" --target whisper -j 4
xcrun clang++ -std=c++17 -O2 -ffile-prefix-map="$APP_DIR=/ULecture/app" -arch arm64 -mmacosx-version-min=14.0 \
 -I"$SRC/include" -I"$SRC/ggml/include" -c "$NATIVE_ROOT/ASRBridge.cpp" -o "$APP_DIR/build/ASRBridge.o"
/usr/bin/libtool -static -o "$APP_DIR/build/libClassroomASR.pending.a" "$APP_DIR/build/ASRBridge.o" \
 "$APP_DIR/build/engine/src/libwhisper.a" "$APP_DIR/build/engine/ggml/src/libggml.a" \
 "$APP_DIR/build/engine/ggml/src/libggml-base.a" "$APP_DIR/build/engine/ggml/src/libggml-cpu.a" \
 "$APP_DIR/build/engine/ggml/src/ggml-metal/libggml-metal.a" "$APP_DIR/build/engine/ggml/src/ggml-blas/libggml-blas.a"
mv "$APP_DIR/build/libClassroomASR.pending.a" "$APP_DIR/build/libClassroomASR.a"
