#!/usr/bin/env python3
"""Objective validation of the final music film. Does not claim human listening."""
import argparse,datetime,hashlib,json,re,subprocess
from pathlib import Path
import numpy as np
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]

def run(args):return subprocess.run(args,check=True,capture_output=True)
def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def loudness(p):
    result=run(['ffmpeg','-hide_banner','-threads','1','-i',str(p),'-vn','-af','loudnorm=I=-20:TP=-2:LRA=7:print_format=json','-f','null','-']).stderr.decode()
    return json.JSONDecoder().raw_decode(result[result.rfind('{'):])[0]
def samples(p):
    raw=run(['ffmpeg','-v','error','-filter_threads','1','-threads','1','-i',str(p),'-vn','-ar','48000','-ac','2','-f','f32le','-']).stdout
    return np.frombuffer(raw,dtype='<f4').reshape((-1,2))
def caption_frames(p,start,filter):
    process=subprocess.Popen(['ffmpeg','-v','error','-filter_threads','1','-threads','1','-ss',str(start),'-i',str(p),'-frames:v','600','-vf',filter+',scale=171:56:flags=lanczos','-threads','1','-pix_fmt','rgb24','-f','rawvideo','-'],stdout=subprocess.PIPE)
    return process

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);p.add_argument('--capture',type=Path,required=True);a=p.parse_args()
    video=a.output/'ULecture-introduction.mp4';music=a.output/'ULecture-music.wav'
    probe=json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(video)]).stdout)
    v=next(x for x in probe['streams'] if x['codec_type']=='video');audio=next(x for x in probe['streams'] if x['codec_type']=='audio')
    assert (v['width'],v['height'],v['r_frame_rate'],int(v['nb_frames']))==(1920,1080,'30/1',2250)
    assert abs(float(probe['format']['duration'])-75)<.01
    assert int(audio['sample_rate'])==48000 and audio['channels']==2
    decode=run(['ffmpeg','-v','error','-filter_threads','1','-threads','1','-i',str(video),'-f','null','-'])
    assert not decode.stderr
    manifest=json.loads((a.output/'render-manifest.json').read_text())
    for key,path in [('videoSHA256',video),('musicSHA256',music),('nativeCaptureSHA256',a.capture),('renderScriptSHA256',ROOT/'media/render-video.py'),('timelineSHA256',ROOT/'media/timeline.json')]:assert digest(path)==manifest[key]
    encoded=samples(video);original=samples(music);n=min(len(encoded),len(original));encoded=encoded[:n];original=original[:n]
    assert n==75*48000
    correlation=float(np.corrcoef(original.reshape(-1),encoded.reshape(-1))[0,1]);assert correlation>.995
    adjacent_step=np.abs(np.diff(encoded,axis=0))
    boundary_steps={str(second):float(np.max(adjacent_step[round(second*48000)-48:round(second*48000)+48])) for second in [7.5,15,25,32.5,52.5,59.5,67.5]}
    measurement=loudness(video);assert -21<float(measurement['input_i'])<-19 and float(measurement['input_tp'])<-1.5
    assert np.max(np.abs(encoded))<1
    windows=[]
    for start,end in [(0,.1),(0,1),(1,2),(2,3),(35,36),(70,71),(72,73),(73,74),(74,75),(74.9,75)]:
        s=encoded[round(start*48000):round(end*48000)];windows.append({'seconds':[start,end],'rmsDBFS':float(20*np.log10(max(1e-12,np.sqrt(np.mean(s*s)))) )})
    assert windows[-1]['rmsDBFS']<-65 and windows[0]['rmsDBFS']<-60
    source=caption_frames(a.capture,45,'format=rgb24,crop=1620:530:150:478')
    final=caption_frames(video,32.5,'format=rgb24,crop=1710:559:105:340')
    errors=[];motions=[];previous=None;last=None
    for i in range(600):
        size=171*56*3;x=source.stdout.read(size);y=final.stdout.read(size)
        assert len(x)==len(y)==size
        sx=np.frombuffer(x,dtype=np.uint8).astype(np.float32);sy=np.frombuffer(y,dtype=np.uint8).astype(np.float32)
        errors.append(float(np.mean(np.abs(sx-sy))))
        if previous is not None:motions.append(float(np.mean(np.abs(sx-previous))))
        previous=sx
    assert source.wait()==0 and final.wait()==0
    assert np.mean(errors[7:])<2 and max(errors[7:])<3
    timeline=json.loads((ROOT/'media/timeline.json').read_text());cues=[]
    for scene in timeline['scenes']:cues.extend(timeline['subtitleDetails'] if scene['kind']=='captions' else [scene])
    from importlib.machinery import SourceFileLoader
    renderer=SourceFileLoader('renderer',str(ROOT/'media/render-video.py')).load_module()
    for language in ['zh','en','bilingual']:
        lines=[]
        for i,cue in enumerate(cues):
            wording='\n'.join([cue['zh'],cue['en']]) if language=='bilingual' else cue[language]
            lines.append(f'{i+1}\n{renderer.stamp(cue["start"])} --> {renderer.stamp(cue["end"])}\n{wording}')
        assert (a.output/f'ULecture-{language}.srt').read_text()=='\n\n'.join(lines)+'\n'
    assert all(cues[i]['end']==cues[i+1]['start'] for i in range(len(cues)-1))
    gif=Image.open(a.output/'ULecture-preview.gif');gifms=0;unique=set()
    for i in range(gif.n_frames):gif.seek(i);gifms+=gif.info['duration'];unique.add(hashlib.sha256(gif.convert('RGB').tobytes()).hexdigest())
    assert gif.size==(960,540) and gif.n_frames==144 and len(unique)>100
    artifacts={}
    for name in ['ULecture-introduction.mp4','ULecture-music.wav','ULecture-cover.jpg','ULecture-preview.gif','ULecture-zh.srt','ULecture-en.srt','ULecture-bilingual.srt']:
        file=a.output/name;artifacts[name]={'sha256':digest(file),'bytes':file.stat().st_size}
    report={'schemaVersion':2,'checkedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'objective_checks_passed_playback_and_subjective_audition_pending','artifacts':artifacts,'checks':{'fullDecode':{'status':'passed','videoFrames':2250,'seconds':75,'dimensions':[1920,1080],'fps':30,'audioChannels':2,'sampleRate':48000},'inputOutputIdentity':'passed','audio':{'status':'passed','sampleCount':n,'aacToMasterCorrelation':correlation,'measuredIntegratedLUFS':float(measurement['input_i']),'measuredTruePeakDBTP':float(measurement['input_tp']),'samplePeakDBFS':float(20*np.log10(np.max(np.abs(encoded)))),'fullScaleSamples':int(np.sum(np.abs(encoded)>=1)),'maximumAdjacentSampleStep':float(np.max(adjacent_step)),'sceneBoundaryMaximumSteps':boundary_steps,'loopMethod':'Single continuously synthesized 75-second score; no repeated external audio segment or splice','windowRMS':windows,'vocalContent':'None by synthesis construction; no vocal or sample inputs','listeningVerified':False},'continuousCaptions':{'status':'passed','framesCompared':600,'finalSeconds':[32.5,52.5],'nativeSeconds':[45,65],'meanAbsoluteRGBError':float(np.mean(errors[7:])),'maximumFrameMeanError':max(errors[7:]),'transitionFramesExcludedFromErrorStatistics':7,'sourceFrameChangesOver0_1':sum(x>.1 for x in motions),'method':'Compare all consecutive RGB source/final crops downsampled to 171×56. Preserved chronological mapping; no retiming or repeated stills.'},'subtitles':{'status':'passed','languages':['zh-Hans','en'],'independentFiles':3,'cues':len(cues),'coverageSeconds':75,'method':'All UTF-8 SRT content and timing exactly match bilingual timeline; contiguous positive-duration cues.'},'gif':{'status':'passed','dimensions':list(gif.size),'frames':gif.n_frames,'distinctFrames':len(unique),'milliseconds':gifms},'musicRights':{'status':'documented_original_score','license':'AGPL-3.0-only','notice':'media/music-license.md'}},'remainingChecks':['Complete native player playback with observed start and end.','Human subjective full audition: the tools do not provide hearing to this reviewer.','Anonymous public links after publication.']}
    (a.output/'media-validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    (a.output/'video-probe.json').write_text(json.dumps(probe,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'result':report['status'],'lufs':measurement['input_i'],'truePeak':measurement['input_tp'],'captionMAE':np.mean(errors[7:]),'audioCorrelation':correlation}))
if __name__=='__main__':main()
