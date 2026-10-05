#!/usr/bin/env python3
"""Download release sources and build recipes from committed locks, verify every byte."""
import concurrent.futures, hashlib, json, shutil, sys, urllib.request
from pathlib import Path
APP = Path(__file__).resolve().parents[1]
root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
locks = APP/'DependencyLocks'
rows = []
for file, folder in [('python-source.lock.json','python'), ('additional-source.lock.json','python'),
                     ('libreoffice-source.lock.json','libreoffice'),
                     ('libreoffice-external-source.lock.json','libreoffice-external')]:
    for row in json.loads((locks/file).read_text()):
        rows.append((folder, row))
native = json.loads((locks/'native.lock.json').read_text())['whisper.cpp']
rows.append(('native',dict(name='whisper.cpp-'+native['version']+'.tar.gz',url=native['url'],sha256=native['sha256'])))
def fetch(pair):
    folder, row = pair
    path = root/folder/row.get('file', row['name'])
    path.parent.mkdir(parents=True, exist_ok=True)
    def sha(file):
        h = hashlib.sha256()
        with file.open('rb') as stream:
            for data in iter(lambda: stream.read(1024*1024),b''): h.update(data)
        return h.hexdigest()
    if not path.exists() or sha(path) != row['sha256']:
        partial = path.with_suffix(path.suffix+'.partial')
        urllib.request.urlretrieve(row['url'],partial)
        if sha(partial) != row['sha256']:
            partial.unlink()
            raise RuntimeError('Source archive checksum mismatch: '+path.name)
        partial.replace(path)
    print(path.name, flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as workers:
    list(workers.map(fetch,rows))
shutil.copytree(locks, root/'locks', dirs_exist_ok=True)
print('Verified',len(rows),'source artifacts')
