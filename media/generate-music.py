#!/usr/bin/env python3
"""An original, deterministic instrumental electronic score; no samples or voices."""
import argparse, hashlib, json, math, subprocess, wave
from pathlib import Path
import numpy as np
RATE=48000
DURATION=75
BPM=96
BEAT=60/BPM

def digest(path):
    with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True)
    mix=np.zeros((RATE*DURATION,2),dtype=np.float64)
    rng=np.random.default_rng(20261005)
    score=[]
    def add(voice,start,duration,notes=(),gain=.1,pan=0):
        n=min(int(duration*RATE),len(mix)-round(start*RATE))
        if n<=0:return
        t=np.arange(n)/RATE
        if voice=='pad':
            s=sum(np.sin(2*np.pi*(440*2**((m-69)/12))*t+0.008*np.sin(2*np.pi*.19*t))+
                  .24*np.sin(2*np.pi*(440*2**((m-69)/12))*1.002*t) for m in notes)/len(notes)
            env=np.minimum(t/1.1,1)*np.minimum(np.maximum(duration-t,0)/1.8,1)
            s*=env
        elif voice=='pluck':
            f=440*2**((notes[0]-69)/12)
            s=(np.sin(2*np.pi*f*t)+.20*np.sin(2*np.pi*2*f*t)+.045*np.sin(2*np.pi*3*f*t))*np.minimum(t/.009,1)*np.exp(-t*5.2)
        elif voice=='bass':
            f=440*2**((notes[0]-69)/12)
            s=(np.sin(2*np.pi*f*t)+.15*np.sin(2*np.pi*2*f*t))*np.minimum(t/.022,1)*np.minimum(np.maximum(duration-t,0)/.2,1)*np.exp(-t*.7)
        elif voice=='kick':
            phase=2*np.pi*(47*t+75*.025*(1-np.exp(-t/.025)))
            s=np.sin(phase)*np.minimum(t/.003,1)*np.exp(-t*14)
        elif voice=='hat':
            noise=rng.standard_normal(n)
            s=(noise-np.concatenate(([0],noise[:-1])))*np.minimum(t/.002,1)*np.exp(-t*58)*.22
        elif voice=='rim':
            s=(np.sin(2*np.pi*1250*t)+.4*np.sin(2*np.pi*1720*t))*np.minimum(t/.0015,1)*np.exp(-t*80)
        else:raise ValueError(voice)
        left=math.sqrt((1-pan)/2);right=math.sqrt((1+pan)/2)
        at=round(start*RATE);mix[at:at+n]+=gain*s[:,None]*np.array([left,right])
        score.append({'instrument':voice,'start':round(start,4),'duration':duration,'midi':list(notes),'gain':gain,'pan':pan})
    chords=[([62,66,69,73,76],38),([61,64,69,73,76],33),([59,64,66,71,76],40),([59,62,66,69,73],35)]
    for bar in range(30):
        start=bar*4*BEAT
        chord,bass=chords[(bar//2)%4] if bar<28 else chords[0]
        if bar%2==0:add('pad',start,min(6.4,DURATION-start),chord,.165,(-.12 if bar%4 else .12))
        # Gradual arrangement: space for branding, lighter percussion under subtitles.
        if bar>=3 and bar<29:
            add('bass',start,1.8,[bass],.19)
            add('bass',start+2*BEAT,.9,[bass],.12)
        if 3<=bar<27:
            for beat in (0,2):add('kick',start+beat*BEAT,.45,gain=.17 if bar<13 else .115)
            for beat in (1,3):add('rim',start+beat*BEAT,.09,gain=.025,pan=.22)
            for beat in range(4):add('hat',start+(beat+.5)*BEAT,.10,gain=.026 if bar<13 else .018,pan=(-.35 if beat%2 else .35))
        if bar>=1:
            pattern=[0,2,4,1,3,2,4,2]
            for j,index in enumerate(pattern):
                if (bar+j)%7==0 or bar==29 and j>2:continue
                if bar<3 and j%2:continue
                add('pluck',start+j*.5*BEAT,.85,[chord[index]+12],.075 if bar<27 else .060,(-.35 if j%2 else .35))
    # Short, quiet stereo echoes are derived solely from this synthesized score.
    original=mix.copy()
    for delay,gain in [(.3125,.13),(.625,.065)]:
        d=round(delay*RATE);mix[d:]+=original[:-d,::-1]*gain
    t=np.arange(len(mix))/RATE
    envelope=np.sin(np.pi/2*np.minimum(t/2.1,1))**2
    envelope*=np.sin(np.pi/2*np.minimum((DURATION-t)/4.0,1))**2
    mix*=envelope[:,None]
    mix*=.84/max(np.max(np.abs(mix)),1e-9)
    raw=a.output/'ULecture-music-premaster.wav'
    with wave.open(str(raw),'wb') as f:
        f.setnchannels(2);f.setsampwidth(2);f.setframerate(RATE);f.writeframes(np.round(mix*32767).astype('<i2').tobytes())
    first=subprocess.run(['ffmpeg','-hide_banner','-i',str(raw),'-af','loudnorm=I=-20:TP=-2:LRA=7:print_format=json','-f','null','-'],capture_output=True,text=True,check=True)
    measurements=json.JSONDecoder().raw_decode(first.stderr[first.stderr.rfind('{'):])[0]
    filt='loudnorm=I=-20:TP=-2:LRA=7:linear=true:print_format=json:'+':'.join(f'{key}={measurements[value]}' for key,value in [('measured_I','input_i'),('measured_TP','input_tp'),('measured_LRA','input_lra'),('measured_thresh','input_thresh'),('offset','target_offset')])
    final=a.output/'ULecture-music.wav'
    second=subprocess.run(['ffmpeg','-y','-hide_banner','-i',str(raw),'-af',filt,'-ar',str(RATE),'-c:a','pcm_s24le',str(final)],capture_output=True,text=True,check=True)
    final_measurement=json.JSONDecoder().raw_decode(second.stderr[second.stderr.rfind('{'):])[0]
    (a.output/'music-score.json').write_text(json.dumps({'title':'Connections','author':'ULecture contributors','duration':DURATION,'sampleRate':RATE,'bpm':BPM,'seed':20261005,'instruments':['sine pad','sine pluck','sine bass','synthesized kick','noise hi-hat','sine rim'],'voices':False,'samples':False,'events':score},indent=2)+'\n')
    (a.output/'music-loudness.json').write_text(json.dumps({'targetLUFS':-20,'targetTruePeakDBTP':-2,'premaster':measurements,'master':final_measurement,'masterSHA256':digest(final),'scriptSHA256':digest(Path(__file__))},indent=2)+'\n')
    print(final)
if __name__=='__main__':main()
