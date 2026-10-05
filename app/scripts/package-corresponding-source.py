#!/usr/bin/env python3
"""Partition already verified upstream source artifacts into independent portable archives."""
import argparse, hashlib, json, pathlib, tarfile
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
files=sorted(x for x in a.source.rglob('*') if x.is_file() and not x.name.endswith('.partial'))
parts=[[]];size=0
for path in files:
    if path.is_symlink():raise RuntimeError('Unexpected source symlink: '+str(path))
    if size+path.stat().st_size>1200*1024**2 and parts[-1]:parts.append([]);size=0
    parts[-1].append(path);size+=path.stat().st_size
report=[]
for i,items in enumerate(parts,1):
    output=a.output/f'ULecture-1.1.0-corresponding-source-{i:02d}.tar.gz'
    if output.exists():raise RuntimeError('Keep previous archive and choose a fresh output directory')
    with tarfile.open(output,'w:gz',compresslevel=1) as archive:
        for file in items:
            info=archive.gettarinfo(str(file),arcname='corresponding-source/'+file.relative_to(a.source).as_posix());info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0
            with file.open('rb') as data:archive.addfile(info,data)
    hasher=hashlib.sha256()
    with output.open('rb') as stream:
        for block in iter(lambda:stream.read(1024*1024),b''):hasher.update(block)
    digest=hasher.hexdigest()
    if output.stat().st_size>=2*1024**3:raise RuntimeError('Release asset too large')
    report.append({'name':output.name,'sha256':digest,'bytes':output.stat().st_size,'fileCount':len(items),'files':[x.relative_to(a.source).as_posix() for x in items]});print(output.name,output.stat().st_size,flush=True)
(a.output/'corresponding-source-index.json').write_text(json.dumps(report,indent=2)+'\n')
