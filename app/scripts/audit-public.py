#!/usr/bin/env python3
"""Audit the exact Git tree/history selected for publication; never stages files.
Output contains paths and rule names, never suspected secret values.
"""
import argparse, hashlib, json, re, subprocess
from pathlib import PurePosixPath
p=argparse.ArgumentParser();p.add_argument('revision');p.add_argument('--output',required=True);a=p.parse_args()
def git(*args):return subprocess.check_output(['git',*args])
commits=git('rev-list',a.revision).decode().splitlines();findings=[];trees=[];seen=set();reviewed=[]
secret=re.compile(rb'(?:sk-proj-[A-Za-z0-9_-]{35,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)')
for commit in commits:
    records=git('ls-tree','-r','-l','-z',commit).split(b'\0');files=[]
    for record in records:
        if not record:continue
        meta,path=record.split(b'\t',1);mode,kind,oid,size=meta.decode().split();name=path.decode();pp=PurePosixPath(name)
        if kind!='blob':findings.append({'commit':commit,'path':name,'rule':'non-blob entry'});continue
        files.append({'path':name,'bytes':int(size),'gitBlob':oid})
        blocked=any(part in {'Dependencies','build','evidence','.scratch','dist','__pycache__','.DS_Store'} for part in pp.parts) or name.startswith('app/Resources/Models/') or pp.suffix.lower() in {'.caf','.wav','.mp4','.mov','.sqlite','.sqlite3','.p12','.pem','.key','.pyc'} or pp.name.startswith('.env')
        if blocked:findings.append({'commit':commit,'path':name,'rule':'private/generated/heavyweight path'})
        if int(size)>8*1024*1024:findings.append({'commit':commit,'path':name,'rule':'file exceeds reviewed 8 MiB source/media budget'})
        if oid in seen:continue
        seen.add(oid);data=git('cat-file','blob',oid)
        if mode=='120000':
            target=data.decode()
            if target.startswith('/') or '..' in PurePosixPath(target).parts:findings.append({'commit':commit,'path':name,'rule':'symlink escapes source tree'})
        if secret.search(data):
            generated_test_key = name == 'app/Tests/CloudChecks.swift' and b'generator.arguments = ["genrsa", "2048"]' in data and b'pkcs8.base64EncodedString()' in data and not re.search(rb'-----BEGIN [A-Z ]*PRIVATE KEY-----[\r\n]+[A-Za-z0-9+/=\r\n]{64,}',data)
            if generated_test_key:reviewed.append({'commit':commit,'path':name,'gitBlob':oid,'classification':'Reviewed runtime-generated RSA fixture, no embedded private key bytes'})
            else:findings.append({'commit':commit,'path':name,'rule':'credential/private-key pattern; manual classification required'})
        if re.search(rb'/Users/(?!test/)[A-Za-z0-9._-]+/', data):findings.append({'commit':commit,'path':name,'rule':'personal absolute path'})
    trees.append({'commit':commit,'files':files})
report={'revision':a.revision,'commitCount':len(commits),'uniqueBlobsInspected':len(seen),'findings':findings,'reviewedExceptions':reviewed,'trees':trees,'limitations':['Pattern scanning does not replace human review of every staged path, media, license and release artifact.','Fictional fixture content and public attribution are reviewed independently.']}
open(a.output,'w').write(json.dumps(report,indent=2)+'\n')
print(json.dumps({'commits':len(commits),'uniqueBlobs':len(seen),'findings':findings},indent=2))
raise SystemExit(bool(findings))
