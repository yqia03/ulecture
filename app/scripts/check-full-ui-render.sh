#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$task_root"
checks_root="${1:?Pass a fresh isolated output directory}"
mkdir -p "$checks_root/compile"
ditto app/Sources "$checks_root/compile/Sources"
ditto app/Native "$checks_root/compile/Native"
cp app/Tests/FullUIRenderChecks.swift "$checks_root/compile/FullUIRenderChecks.swift"
cp app/build/libClassroomASR.a "$checks_root/compile/libClassroomASR.a"
cmp -s app/build/libClassroomASR.a "$checks_root/compile/libClassroomASR.a" || { echo 'Native library changed during snapshot; retry after the application build finishes.' >&2; exit 1; }
sources=()
while IFS= read -r file; do sources+=("$file"); done < <(rg --files "$checks_root/compile/Sources" -g '*.swift' -g '!UwayClassroomApp.swift' | sort)
shasum -a 256 "${sources[@]}" "$checks_root/compile/FullUIRenderChecks.swift" > "$checks_root/source-sha256.txt"
xcrun swiftc -swift-version 5 -Onone -target arm64-apple-macos14.0 -module-cache-path app/build/ModuleCache -import-objc-header "$checks_root/compile/Native/ASRBridge.h" "${sources[@]}" "$checks_root/compile/FullUIRenderChecks.swift" "$checks_root/compile/libClassroomASR.a" -lc++ -lsqlite3 -framework SwiftUI -framework AppKit -framework PDFKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreAudio -framework AudioToolbox -framework CoreMedia -framework Accelerate -framework Metal -framework MetalKit -framework Security -o "$checks_root/full-ui-render"
render_options=(--ui-test-preferences "local.ulecture.ui-render.$(uuidgen)" --ui-test-workspace "$checks_root/workspace" --model-cache "$checks_root/workspace/models" --render-output "$checks_root/images")
if [[ -n "${UI_RENDER_PAGES:-}" ]]; then render_options+=(--pages "$UI_RENDER_PAGES"); fi
"$checks_root/full-ui-render" "${render_options[@]}"
python3 - "$checks_root/images" <<'PY'
import html, json, pathlib, sys
root = pathlib.Path(sys.argv[1]); report = json.loads((root/'results.json').read_text())
cards = []
for item in report['images']:
    title = f"{item['page']} · {item['language']} · {item['theme']} · {item['width']}"
    cards.append(f'<figure data-key="{html.escape(title)}"><a href="{html.escape(item["path"])}"><img loading="lazy" src="{html.escape(item["path"])}" alt="{html.escape(title)}"></a><figcaption>{html.escape(title)}</figcaption></figure>')
text = '<!doctype html><meta charset="utf-8"><title>ULecture native UI rendering matrix</title><style>body{font:15px system-ui;margin:28px;background:#eee;color:#222}input{font:inherit;padding:8px;width:360px}main{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:18px}figure{margin:0;background:white;padding:10px}img{width:100%;height:320px;object-fit:contain}figcaption{margin-top:8px}li{margin:6px}</style><h1>ULecture native UI rendering matrix</h1><p>'+html.escape(report['scope'])+'</p><ul>'+''.join('<li>'+html.escape(x)+'</li>' for x in report.get('limitations',[]))+'</ul><p><input placeholder="Filter page, language, theme or width" oninput="for(const e of document.querySelectorAll(\'figure\'))e.hidden=!e.dataset.key.toLowerCase().includes(this.value.toLowerCase())"></p><main>'+''.join(cards)+'</main>'
(root/'index.html').write_text(text)
PY
