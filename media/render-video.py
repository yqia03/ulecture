#!/usr/bin/env python3
"""Render a bilingual, music-only film using the actual native application capture.
No UI is invented. Caption demonstration is 600 uninterrupted source frames.
"""
import argparse, hashlib, json, math, subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
W,H,FPS=1920,1080,30
BG=(18,20,23); FG=(246,246,244); MUTED=(169,176,185)

def ease(x):
    x=max(0,min(1,x)); return 1-(1-x)**3

def stamp(t):
    ms=round(t*1000); h,ms=divmod(ms,3600000); m,ms=divmod(ms,60000); s,ms=divmod(ms,1000)
    return f'{h:02}:{m:02}:{s:02},{ms:03}'

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--capture',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path)
    p.add_argument('--music',required=True,type=Path)
    p.add_argument('--font',type=Path,default=ROOT/'app/Dependencies/babeldoc-runtime/assets/fonts/SourceHanSansCN-Regular.ttf')
    p.add_argument('--repository',default=None)
    p.add_argument('--still',type=float,help='Render one design review frame without encoding')
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    timeline=json.loads((ROOT/'media/timeline.json').read_text()); repo=a.repository or timeline['repository']
    assert (timeline['width'],timeline['height'],timeline['fps'],timeline['duration'])==(W,H,FPS,75)
    fonts={size:ImageFont.truetype(str(a.font),size) for size in [22,24,26,28,30,32,34,36,38,42,48,52,54,60,64,72,86,96]}
    icon=Image.open(ROOT/'assets/brand/ulecture-icon.png').convert('RGBA')
    cues=[]
    for s in timeline['scenes']:
        if s['kind']=='captions':cues.extend(timeline['subtitleDetails'])
        else:cues.append(s)
    for language in ['zh','en','bilingual']:
        chunks=[]
        for i,cue in enumerate(cues):
            wording='\n'.join([cue['zh'],cue['en']]) if language=='bilingual' else cue[language]
            chunks.append(f'{i+1}\n{stamp(cue["start"])} --> {stamp(cue["end"])}\n{wording}')
        (a.output/f'ULecture-{language}.srt').write_text('\n\n'.join(chunks)+'\n',encoding='utf-8')
    metrics=[]
    def text(canvas,xy,value,size=42,fill=FG,anchor=None):
        draw=ImageDraw.Draw(canvas);bbox=draw.textbbox(xy,value,font=fonts[size],anchor=anchor)
        if bbox[0]<0 or bbox[1]<0 or bbox[2]>W or bbox[3]>H:raise ValueError(f'Text outside canvas: {value}: {bbox}')
        draw.text(xy,value,font=fonts[size],fill=fill,anchor=anchor)
    y,x=np.mgrid[0:H,0:W]
    glow=np.maximum(0,1-np.sqrt(((x-1260)/1700)**2+((y-380)/1100)**2))
    base=np.zeros((H,W,3),dtype=np.uint8)
    for i,c in enumerate(BG):base[:,:,i]=c+(glow*9).astype(np.uint8)
    background=Image.fromarray(base)
    def decor(canvas,t):
        draw=ImageDraw.Draw(canvas)
        draw.line((96,1020,1824,1020),fill=(55,58,64),width=2)
        draw.line((96,1020,96+1728*t/75,1020),fill=(184,190,198),width=3)
    def frame(t,scene,raw=None):
        local=t-scene['start']; im=background.copy();kind=scene['kind']
        if kind in ['brand','end']:
            arrival=ease(local/.9); size=round((270 if kind=='brand' else 220)*(.92+.08*arrival))
            art=icon.resize((size,size),Image.Resampling.LANCZOS)
            ix=(W-size)//2; iy=round((105 if kind=='brand' else 70)+(1-arrival)*25)
            im.paste(art,(ix,iy),art)
            text(im,(960,iy+size+20),'ULecture',96 if kind=='brand' else 86,anchor='mt')
            text(im,(960,iy+size+169),scene['zh'],54,anchor='mt')
            text(im,(960,iy+size+247),scene['en'],36,MUTED,'mt')
            if kind=='brand':
                text(im,(960,838),'课程资料  ·  听课理解  ·  学习记录',30,MUTED,'mt')
                text(im,(960,893),'Materials  ·  Understanding  ·  Notes',26,MUTED,'mt')
            else:
                text(im,(960,713),'macOS  ·  开源学习工作空间 / Open-source learning workspace',28,MUTED,'mt')
                text(im,(960,796),repo.replace('https://',''),42,FG,'mt')
                text(im,(960,875),'源码、下载与使用说明 / Source, downloads and guide',26,MUTED,'mt')
        else:
            text(im,(96,28),scene['zh'],52)
            text(im,(96,106),scene['en'],30,MUTED)
            text(im,(1824,52),'ULecture',28,MUTED,'rt')
            if raw is not None:
                if kind=='captions':
                    # Exact pixels of the shared production NSView, not reconstructed text.
                    raw=raw.crop((150,478,1770,1008)).resize((1710,559),Image.Resampling.LANCZOS)
                    cue=next(c for c in timeline['subtitleDetails'] if c['start']<=t<c['end'])
                    text(im,(105,214),cue['zh'],34)
                    text(im,(105,269),cue['en'],26,MUTED)
                    im.paste(raw,(105,340))
                    text(im,(105,944),'虚构课程回放 · 原生字幕面板 / Fictional lesson replay · Native caption panel',24,MUTED)
                elif kind=='files_ui':
                    # Exclude the fixture's temporary workspace path below these native controls.
                    raw=raw.crop((385,158,1888,361)).resize((1710,231),Image.Resampling.LANCZOS)
                    im.paste(raw,(105,272))
                    text(im,(110,568),'transcript.txt',48)
                    text(im,(110,647),'仅原文',36)
                    text(im,(110,704),'Source text only',28,MUTED)
                    text(im,(960,568),'transcript-bilingual.txt',48)
                    text(im,(960,647),'原文与对应译文',36)
                    text(im,(960,704),'Source with its matching translation',28,MUTED)
                    text(im,(110,853),'两份记录持续更新，可分别在 Finder 定位。',32)
                    text(im,(110,911),'Both files keep updating and can be revealed in Finder.',28,MUTED)
                else:
                    raw=raw.resize((1408,792),Image.Resampling.LANCZOS)
                    im.paste(raw,(256,178))
            if kind=='files':
                cards=[(100,'transcript.txt',['[00:00–00:04]','Learning begins with a question.','','[00:05–00:09]','Connect a new idea to','something you already know.']),
                       (980,'transcript-bilingual.txt',['[00:00–00:04]','Learning begins with a question.','学习，从一个问题开始。','','[00:05–00:09]','Connect a new idea to','something you already know.','把新观点与已有知识联系起来。'])]
                draw=ImageDraw.Draw(im)
                for i,(cx,title,lines) in enumerate(cards):
                    yy=round(235+20*(1-ease((local-i*.15)/.6)))
                    draw.rounded_rectangle((cx,yy,cx+840,yy+640),24,fill=(32,35,39),outline=(76,80,86),width=2)
                    text(im,(cx+38,yy+30),title,36)
                    draw.line((cx+38,yy+103,cx+802,yy+103),fill=(77,81,87),width=2)
                    for j,line in enumerate(lines):text(im,(cx+38,yy+132+j*54),line,26,MUTED if line.startswith('[') else FG)
                text(im,(100,937),'虚构会话内容节选 / Excerpts from a fictional session',26,MUTED)
        if local<.23:im=Image.blend(background,im,ease(local/.23))
        decor(im,t)
        return im
    def decode(scene,count,offset=0):
        command=['ffmpeg','-v','error','-threads','1','-ss',str(scene.get('source',0)+offset),'-i',str(a.capture),'-frames:v',str(count),'-vf','fps=30,scale=1920:1080','-threads','1','-f','rawvideo','-pix_fmt','rgb24','-']
        return subprocess.Popen(command,stdout=subprocess.PIPE)
    if a.still is not None:
        sc=next(s for s in timeline['scenes'] if s['start']<=a.still<s['end']); raw=None
        if 'source' in sc:
            dec=decode(sc,1,a.still-sc['start']);buf=dec.stdout.read(W*H*3);dec.wait();raw=Image.frombytes('RGB',(W,H),buf)
        dest=a.output/f'review-{a.still:05.1f}.png';frame(a.still,sc,raw).save(dest);print(dest);return
    dest=a.output/'ULecture-introduction.mp4'
    command=['ffmpeg','-y','-v','warning','-f','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-', '-i',str(a.music),'-map','0:v:0','-map','1:a:0','-c:v','libx264','-threads','2','-preset','medium','-crf','19','-pix_fmt','yuv420p','-c:a','aac','-b:a','192k','-ar','48000','-t','75','-movflags','+faststart','-metadata','title=ULecture — Bring your learning together','-metadata','comment=Original instrumental music; Chinese and English captions; fictional native UI replay',str(dest)]
    encoder=subprocess.Popen(command,stdin=subprocess.PIPE)
    for scene in timeline['scenes']:
        count=round((scene['end']-scene['start'])*FPS); dec=decode(scene,count) if 'source' in scene else None
        for i in range(count):
            t=scene['start']+i/FPS;raw=None
            if dec:
                buf=dec.stdout.read(W*H*3)
                if len(buf)!=W*H*3:raise RuntimeError('Native capture ended early')
                raw=Image.frombytes('RGB',(W,H),buf)
            rendered=frame(t,scene,raw)
            if i==min(count-1,45):rendered.save(a.output/f'scene-{scene["start"]:04.1f}.jpg',quality=94)
            encoder.stdin.write(rendered.tobytes())
        if dec and dec.wait()!=0:raise RuntimeError('UI decoder failed')
        print('Rendered',scene['start'],scene['end'],flush=True)
    encoder.stdin.close()
    if encoder.wait()!=0:raise RuntimeError('Video encoder failed')
    metadata={'timeline':timeline,'repository':repo,'nativeCaptureSHA256':digest(a.capture),'musicSHA256':digest(a.music),'videoSHA256':digest(dest),'font':a.font.name,'fontSHA256':digest(a.font),'renderScriptSHA256':digest(Path(__file__)),'timelineSHA256':digest(ROOT/'media/timeline.json'),'music':True,'vocals':False,'narration':False,'nativeFootage':'Production SwiftUI/AppKit fixture replay, not a recording of a live microphone or cloud provider','captionSourceMapping':{'finalSeconds':[32.5,52.5],'nativeSeconds':[45,65],'frames':600,'nativeCrop':[150,478,1770,1008],'finalCrop':[105,340,1815,899]}}
    (a.output/'render-manifest.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2)+'\n')
    print(dest)
if __name__=='__main__':main()
