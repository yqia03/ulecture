#!/usr/bin/env python3
"""Verify the delivered bundle against current sources and collect local evidence."""
import argparse, datetime, hashlib, importlib.util, json, pathlib, subprocess, plistlib, sys
root = pathlib.Path(__file__).resolve().parents[2]
app = root/'app/build/ULecture.app'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('evidence', nargs='?', type=pathlib.Path, default=root/'app/evidence')
parser.add_argument('--public-commit', help='Full public Git commit whose build input files must match this bundle')
arguments = parser.parse_args()
evidence = arguments.evidence
evidence.mkdir(parents=True, exist_ok=True)
def digest(p):
    value = hashlib.sha256()
    with p.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''):
            value.update(chunk)
    return value.hexdigest()
checks = []
for line in (app/'Contents/Resources/source-sha256.txt').read_text().splitlines():
    expected, name = line.split(None, 1)
    name = name.strip()
    checks.append({'source': name, 'match': digest(root/'app'/name) == expected})
assert checks and all(c['match'] for c in checks), 'Compiled source snapshot differs from working source'
manifest = json.loads((app/'Contents/Resources/build-manifest.json').read_text())
spec = importlib.util.spec_from_file_location('ulecture_build_manifest', root/'app/scripts/build-manifest.py')
provenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provenance)
source_association = provenance.verify_inputs(manifest, root/'app', arguments.public_commit)
for source, packaged in {'LICENSE': 'Licenses/ULecture-AGPL-3.0.txt',
                         'COPYRIGHT': 'Licenses/ULecture-COPYRIGHT.txt',
                         'THIRD_PARTY_NOTICES.md': 'Licenses/THIRD_PARTY_NOTICES.md'}.items():
    assert digest(app/'Contents/Resources'/packaged) == manifest['releaseInputs']['distributionFiles'][source], 'Packaged distribution notice differs: ' + source
assert manifest['nativeArchiveSHA256'] == digest(root/'app/build/libClassroomASR.a')
assert {c['source'] for c in checks} == {str(p.relative_to(root/'app')) for p in (root/'app/Sources').rglob('*.swift')}, 'Source manifest is incomplete'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
binary=app/'Contents/MacOS/ULecture'
commands={'file':['file',str(binary)],'deployment':['xcrun','vtool','-show-build',str(binary)],'runtimeDependencies':['otool','-L',str(binary)]}
outputs={name:subprocess.check_output(args,text=True) for name,args in commands.items()}
for line in outputs['runtimeDependencies'].splitlines()[1:]:
    dependency=line.strip().split(' (')[0]
    assert dependency.startswith(('/System/Library/','/usr/lib/')), dependency
conversion = app/'Contents/Resources/Conversion'
subprocess.run([sys.executable, '-B', str(root/'app/scripts/sanitize-python-caches.py'),
                str(conversion/'LibreOffice.app'), '--check'], check=True)
assert (conversion/'LibreOffice.app/Contents/MacOS/soffice').is_file(), 'Missing bundled office converter'
assert (conversion/'ul-pdfium').is_file(), 'Missing PDFium helper'
conversion_manifest_file = app/'Contents/Resources/ConversionIntegrity.json'
conversion_id = (app/'Contents/Resources/ConversionIntegrity.id').read_text().strip()
assert digest(conversion_manifest_file) == conversion_id, 'Converter repair manifest hash differs'
conversion_manifest = json.loads(conversion_manifest_file.read_text())
assert conversion_manifest['schema'] == 1
actual_conversion_paths = {str(p.relative_to(conversion)) for p in conversion.rglob('*') if p.is_file() or p.is_symlink()}
assert actual_conversion_paths == {entry['path'] for entry in conversion_manifest['files']}, 'Converter repair manifest is incomplete'
for entry in conversion_manifest['files']:
    path = conversion/entry['path']
    assert not pathlib.Path(entry['path']).is_absolute() and '..' not in pathlib.Path(entry['path']).parts
    assert path.resolve().is_relative_to(conversion.resolve()), 'Converter link leaves bundle'
    if 'link' in entry:
        assert path.is_symlink() and str(path.readlink()) == entry['link']
    else:
        assert not path.is_symlink() and path.stat().st_size == entry['bytes'] and digest(path) == entry['sha256']
babeldoc = app/'Contents/Resources/BabelDOC'
runtime_manifest = json.loads((babeldoc/'runtime-manifest.json').read_text())
assert runtime_manifest['engineVersion'] == '0.6.4', 'Unexpected BabelDOC engine version'
assert digest(babeldoc/'worker.py') == digest(root/'app/Resources/BabelDOC/worker.py'), 'BabelDOC bridge differs from source'
assert digest(babeldoc/'requirements.lock') == runtime_manifest['requirementsSHA256'], 'BabelDOC dependency lock differs'
assert digest(babeldoc/'assets/manifest.json') == runtime_manifest['assetsManifestSHA256'], 'BabelDOC assets manifest differs'
subprocess.run([str(babeldoc/'runtime/bin/python3'), '-I', '-B', '-c', 'import babeldoc.const, pymupdf, onnxruntime, httpx, hyperscan; assert babeldoc.const.__version__ == "0.6.4"'],check=True)
for path in babeldoc.rglob('*'):
    if path.is_symlink():
        assert path.resolve().is_relative_to(babeldoc.resolve()), 'BabelDOC runtime link leaves bundle'
conversionInspection = {}
for path in [conversion/'ul-pdfium', conversion/'LibreOffice.app/Contents/MacOS/soffice']:
    conversionInspection[str(path.relative_to(app))] = {
        'deployment': subprocess.check_output(['xcrun', 'vtool', '-show-build', str(path)], text=True),
        'dependencies': subprocess.check_output(['otool', '-L', str(path)], text=True)}
models=[]
for path in (app/'Contents/Resources/Models').glob('*'):
    sha=digest(path)
    assert sha == digest(root/'app/Resources/Models'/path.name)
    models.append({'name':path.name,'bytes':path.stat().st_size,'sha256':sha,'matchesSourceResource':True})
files=[]
for base in [app, root/'app/Sources', root/'app/Native',root/'app/scripts',root/'app/Tests']:
    files.extend(p for p in base.rglob('*') if p.is_file())
files += [root/'app/build/libClassroomASR.a']
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
report={'createdUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'version':info['CFBundleShortVersionString'] + ' (' + info['CFBundleVersion'] + ')',
        'app':str(app),'executableSHA256':digest(binary),'compiledSourcesMatch':True,'sourceFiles':checks,
        'bundleBytes':sum(p.stat().st_size for p in app.rglob('*') if p.is_file()),
        'codeSignatureVerified':True,'models':models,'inspection':outputs,'conversionInspection':conversionInspection,'conversionIntegrityID':conversion_id,'conversionIntegrityEntries':len(conversion_manifest['files']),'buildManifest':manifest,
        'sourceAssociation':source_association,
        'files':{str(p.relative_to(root)):{'bytes':p.stat().st_size,'sha256':digest(p)} for p in sorted(set(files))},
        'acceptance':'Final local build integrity; product acceptance is evaluated separately'}
(evidence/'delivery-artifacts.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
(evidence/'package-integrity.json').write_text(json.dumps({'sourceFiles':checks,'models':models,'bundleBytes':report['bundleBytes'],'codeSignatureVerified':True,'sourceAssociation':source_association},indent=2))
print(json.dumps({k:report[k] for k in ['executableSHA256','compiledSourcesMatch','bundleBytes','codeSignatureVerified']},indent=2))
