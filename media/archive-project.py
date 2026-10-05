#!/usr/bin/env python3
"""Build an audited media archive from an explicit file list, without old voices."""
import argparse,hashlib,re,zipfile
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--project',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    names=['COPYRIGHT','LICENSE','THIRD_PARTY_NOTICES.md','REBUILD.txt',
           'assets/brand/ulecture-icon.png','assets/brand/ulecture-icon-original.png','assets/brand/ulecture-icon-source.svg','assets/brand/generation.md',
           'fonts/SourceHanSansCN-Regular.ttf','fonts/LICENSE-SourceHan.txt']
    names+=['media/'+n for n in ['README.md','timeline.json','render-video.py','generate-music.py','sanitize-capture.py','package-previews.py','validate-media.py','archive-project.py','render-requirements.lock','music-license.md']]
    names+=['media-input/'+n for n in ['actual-ui-continuous.mp4','capture-manifest.json','capture-redaction.json','source-sha256.txt','SOURCE_IDENTITY.txt','ULecture-music.wav','music-score.json','music-loudness.json','ULecture-zh.srt','ULecture-en.srt','ULecture-bilingual.srt','render-manifest.json','media-validation.json']]
    if (a.project/'media-input/media-desktop-playback.json').is_file():names.append('media-input/media-desktop-playback.json')
    checks=[]
    for name in names:
        f=a.project/name
        if not f.is_file():raise FileNotFoundError(f'Missing project input: {name}')
        if f.suffix in ['.txt','.md','.json','.py','.svg']:
            content=f.read_text()
            if re.search(r'/(?:Users|private/var)/[A-Za-z0-9_.-]+/', content):raise ValueError(f'Private path in {name}')
        checks.append(hashlib.sha256(f.read_bytes()).hexdigest()+'  '+name)
    sums='\n'.join(checks)+'\n';(a.project/'SHA256SUMS.txt').write_text(sums)
    names.append('SHA256SUMS.txt');a.output.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(a.output,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for name in sorted(names):
            info=zipfile.ZipInfo('ULecture-media-project/'+name,(1980,1,1,0,0,0));info.external_attr=0o100644<<16;info.compress_type=zipfile.ZIP_DEFLATED
            z.writestr(info,(a.project/name).read_bytes())
    with zipfile.ZipFile(a.output) as z:assert z.testzip() is None
    print(f'{a.output}: {len(names)} files; sha256={hashlib.sha256(a.output.read_bytes()).hexdigest()}')
if __name__=='__main__':main()
