#!/usr/bin/env python3
"""Mask only a synthetic workspace-path row in the original native UI capture.
Uses lossless RGB H.264; verifies every pixel outside that documented rectangle.
The path was fictional, not a user's course or home directory. Never masks UI
controls, caption text, or content used by the final promotional edit.
"""
import argparse,hashlib,json,subprocess
from pathlib import Path
import numpy as np
W,H,FPS=1920,1080,30
START,END=38*FPS,68*FPS
X,Y,WIDTH,HEIGHT=390,363,1290,35
COLOUR=(236,237,239)

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def decode(path):
    return subprocess.Popen(['ffmpeg','-v','error','-threads','1','-i',str(path),'-f','rawvideo','-pix_fmt','rgb24','-'],stdout=subprocess.PIPE)
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--report',required=True,type=Path)
    parser.add_argument('--verify-only',action='store_true')
    args=parser.parse_args()
    if args.input.resolve()==args.output.resolve():parser.error('Input and output must be separate files')
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0','-show_entries','stream=width,height,r_frame_rate,nb_frames','-of','json',str(args.input)]))['streams'][0]
    if (probe['width'],probe['height'],probe['r_frame_rate'],int(probe['nb_frames']))!=(W,H,'30/1',2250):parser.error('Expected the reviewed 75-second 1080p30 native capture')
    if not args.verify_only:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        original=decode(args.input)
        encoder=subprocess.Popen(['ffmpeg','-y','-v','error','-f','rawvideo','-pix_fmt','rgb24','-s','1920x1080','-r','30','-i','-','-c:v','libx264rgb','-crf','0','-preset','medium','-threads','2','-movflags','+faststart','-metadata','title=ULecture fictional native UI capture — demo workspace path redacted',str(args.output)],stdin=subprocess.PIPE)
        try:
            for i in range(2250):
                raw=original.stdout.read(W*H*3)
                if len(raw)!=W*H*3:raise RuntimeError('Source ended early')
                if START<=i<END:
                    frame=np.frombuffer(raw,dtype=np.uint8).reshape((H,W,3)).copy()
                    frame[Y:Y+HEIGHT,X:X+WIDTH]=COLOUR
                    raw=frame.tobytes()
                encoder.stdin.write(raw)
        finally:
            encoder.stdin.close()
        if original.wait()!=0 or encoder.wait()!=0:raise RuntimeError('Capture encoding failed')
    original=decode(args.input);clean=decode(args.output);changed=0
    for i in range(2250):
        a=original.stdout.read(W*H*3);b=clean.stdout.read(W*H*3)
        if len(a)!=W*H*3 or len(b)!=W*H*3:raise RuntimeError('Verification decode ended early')
        if START<=i<END:
            expected=np.frombuffer(a,dtype=np.uint8).reshape((H,W,3)).copy()
            expected[Y:Y+HEIGHT,X:X+WIDTH]=COLOUR
            if expected.tobytes()!=b:raise RuntimeError(f'Unexpected pixel difference in frame {i}')
            changed+=int(a!=b)
        elif a!=b:raise RuntimeError(f'Unmodified frame {i} changed')
    if original.wait()!=0 or clean.wait()!=0:raise RuntimeError('Verification decode failed')
    report={'status':'passed','originalSHA256':sha(args.input),'cleanSHA256':sha(args.output),'scriptSHA256':sha(Path(__file__)),
            'framesVerified':2250,'modifiedFrames':changed,'redaction':{'purpose':'Remove the fictional temporary workspace absolute path from reproducible media inputs','seconds':[38,68],'interval':'start inclusive, end exclusive','rectangleXYWH':[X,Y,WIDTH,HEIGHT],'colourRGB':list(COLOUR)},
            'outsideRectanglePixels':'Every RGB pixel matches original capture exactly in all 2250 frames',
            'finalEditRegions':'Full-frame source 0–26.5 seconds precedes redaction; TXT crop ends at y=361; continuous caption crop begins at y=478. All final-edit source pixels are unchanged.',
            'originalDisposition':'Unredacted capture retained only in a private local recovery directory; not included in public media archive.',
            'boundary':'A labelled privacy edit to a fictional path row, not reconstructed UI or caption behavior.'}
    args.report.parent.mkdir(parents=True,exist_ok=True);args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
if __name__=='__main__':main()
