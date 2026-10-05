#!/usr/bin/env python3
"""Package an already-verified app; retain source/license identity and verify ZIP extraction."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess, tempfile

def run(args):subprocess.run([str(x) for x in args],check=True)
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--app',required=True,type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path);a=p.parse_args()
    app=a.app.resolve();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    info=plistlib.loads((app/'Contents/Info.plist').read_bytes());version=info['CFBundleShortVersionString']
    manifest=json.loads((app/'Contents/Resources/build-manifest.json').read_text())
    if not manifest['workspaceMatchesSnapshot']:raise RuntimeError('Refusing mismatched build snapshot')
    run(['codesign','--verify','--deep','--strict',app])
    stem=f'ULecture-{version}-macOS-arm64'
    zipfile=out/(stem+'.zip');dmg=out/(stem+'.dmg')
    if zipfile.exists() or dmg.exists():raise RuntimeError('Use a fresh distribution output directory; previous artifacts are retained')
    run(['ditto','-c','-k','--norsrc','--keepParent',app,zipfile])
    with tempfile.TemporaryDirectory(prefix='ulecture-package-',dir=out) as folder:
        stage=pathlib.Path(folder);volume=stage/'volume';volume.mkdir()
        run(['ditto',app,volume/'ULecture.app'])
        (volume/'Applications').symlink_to('/Applications')
        (volume/'安装与许可.txt').write_text('ULecture '+version+'\n\n将 ULecture.app 拖入 Applications 后打开。\n本包为 Apple Silicon / macOS 14+ 构建。\n采用临时签名，没有 Developer ID 签名或 Apple 公证。\n若 macOS 阻止打开，请确认来源与 SHA-256 后使用系统支持的“隐私与安全性”流程，或从源码构建；不要关闭系统安全保护。\n\n源码、使用说明、隐私、第三方许可和对应源码：\nhttps://github.com/yqia03/ulecture\n\n自有源码 AGPL-3.0-only；第三方组件保留其原许可。\n')
        run(['hdiutil','create','-volname','ULecture '+version,'-fs','HFS+','-format','UDZO','-imagekey','zlib-level=6','-srcfolder',volume,dmg])
        extracted=stage/'extracted';run(['ditto','-x','-k',zipfile,extracted]);copy=extracted/'ULecture.app'
        run(['codesign','--verify','--deep','--strict',copy])
        for rel in ['Contents/MacOS/ULecture','Contents/Info.plist','Contents/Resources/build-manifest.json','Contents/Resources/ULecture.icns']:
            if sha(copy/rel)!=sha(app/rel):raise RuntimeError('ZIP round trip changed '+rel)
        run(['hdiutil','verify',dmg])
    for artifact in [zipfile,dmg]:
        if artifact.stat().st_size>=2*1024**3:raise RuntimeError('Release asset reaches GitHub 2 GiB limit: '+artifact.name)
    shutil.copy2(app/'Contents/Resources/build-manifest.json',out/'build-manifest.json')
    report={'version':version,'build':info['CFBundleVersion'],'architecture':'arm64','minimumSystem':info['LSMinimumSystemVersion'],'signing':'ad-hoc','notarized':False,'buildInputTreeSHA256':manifest['buildInputTreeSHA256'],'publicSourceTreeSHA256':manifest['publicSourceTreeSHA256'],'zipRoundTripSignatureVerified':True,'dmgStructureVerified':True,'executableSHA256':sha(app/'Contents/MacOS/ULecture'),'artifacts':{x.name:{'bytes':x.stat().st_size,'sha256':sha(x)} for x in [zipfile,dmg]}}
    (out/'distribution-manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
