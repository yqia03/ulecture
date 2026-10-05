#!/usr/bin/env python3
"""Generate all preview artwork from the final encoded film."""
import argparse,json,subprocess
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);a=p.parse_args()
    video=a.output/'ULecture-introduction.mp4'
    def grab(t,dest):
        subprocess.run(['ffmpeg','-y','-v','error','-filter_threads','1','-filter_complex_threads','1','-threads','1','-ss',str(t),'-i',str(video),'-frames:v','1','-threads','1',str(dest)],check=True)
    for name,t in [('ULecture-cover.jpg',3.5),('workspace.jpg',10),('notes.jpg',28),('captions.jpg',42.5)]:grab(t,a.output/name)
    command=['ffmpeg','-y','-v','error','-filter_threads','1','-filter_complex_threads','1','-threads','1','-ss','38.5','-t','12','-i',str(video),'-filter_complex','fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4','-threads','1','-loop','0',str(a.output/'ULecture-preview.gif')]
    subprocess.run(command,check=True)
    sheet=Image.new('RGB',(1920,1512),(18,20,23));draw=ImageDraw.Draw(sheet)
    review=a.output/'review-frames';review.mkdir(exist_ok=True)
    times=[3.5,10,18,28,33,40,42,44,55,63,70,74]
    for i,t in enumerate(times):
        dest=review/f'frame-{t:04.1f}.jpg';grab(t,dest)
        x=(i%3)*640;y=(i//3)*378;sheet.paste(Image.open(dest).resize((640,360)),(x,y));draw.text((x+12,y+361),f'{t:.1f}s',fill=(235,235,235))
    sheet.save(a.output/'film-contact-sheet.jpg',quality=93)
    print('Generated cover, 12-second 960×540 GIF, screenshots and contact sheet.')
if __name__=='__main__':main()
