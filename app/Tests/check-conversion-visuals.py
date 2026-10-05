"""Compare real PDF graphics outside translated text, using synthetic fixtures only."""
from pathlib import Path
import json, sys
import numpy as np
from PIL import Image, ImageDraw
import pypdfium2

root = Path(sys.argv[1]); reports=[]; source_checks=[]
for record in sorted((root/'jobs').glob('*/job.json')):
    job=json.loads(record.read_text())
    if job['status']=='completed' and job['mode']=='bilingual' and job['sourceExtension'] in ['pdf','ppt','pptx']:
        source=pypdfium2.PdfDocument(str(record.parent/'normalized.pdf')); target=pypdfium2.PdfDocument(str(record.parent/'translation.pdf'))
        for mapping in job['mapping']:
            original=source[mapping['sourcePage']-1]; imported=target[mapping['outputPages'][0]-1]
            assert original.get_textpage().get_text_range()==imported.get_textpage().get_text_range(), 'bilingual original ToUnicode changed'
            a=np.asarray(original.render(scale=1).to_pil().convert('RGB'),dtype=np.int16); b=np.asarray(imported.render(scale=1).to_pil().convert('RGB'),dtype=np.int16)
            assert a.shape==b.shape and np.abs(a-b).mean()<.1, 'bilingual original graphics changed'
            source_checks.append(dict(job=job['id'],page=mapping['sourcePage'],kind='bilingual-original-text-and-graphics'))
    if job['title'] not in ['complex','rotated'] or job['mode']!='translated' or job['status']!='completed': continue
    source=pypdfium2.PdfDocument(str(record.parent/'normalized.pdf'))
    original=pypdfium2.PdfDocument(str(record.parent/'source.pdf'))
    target=pypdfium2.PdfDocument(str(record.parent/'translation.pdf'))
    for page in job['pages']:
        index=page['number']-1
        output=next(x['outputPages'][0] for x in job['mapping'] if x['sourcePage']==page['number'])-1
        a=source[index].render(scale=2).to_pil().convert('RGB'); b=target[output].render(scale=2).to_pil().convert('RGB')
        original_image=original[index].render(scale=2).to_pil().convert('RGB')
        assert a.size==original_image.size and np.abs(np.asarray(a,dtype=np.int16)-np.asarray(original_image,dtype=np.int16)).mean()<.5, 'normalization changed original page appearance'
        source_checks.append(dict(job=job['id'],page=page['number'],kind='normalization-graphics'))
        assert a.size==b.size, 'source/translated dimensions changed'
        mask=Image.new('1', a.size, 1); draw=ImageDraw.Draw(mask)
        for region in job['regions']:
            if region['page']!=page['number'] or region.get('translation') is None: continue
            (x,y),(w,h)=region['bounds']
            pad=18
            draw.rectangle(((x-pad)*2,(page['height']-y-h-pad)*2,(x+w+pad)*2,(page['height']-y+pad)*2),fill=0)
        keep=np.asarray(mask,dtype=bool); error=np.abs(np.asarray(a,dtype=np.int16)-np.asarray(b,dtype=np.int16))
        mean=float(error[keep].mean()); fraction=float((error.max(axis=2)[keep]>24).mean())
        assert mean < 1.3 and fraction < .012, f'graphics fidelity failed page {page["number"]}: mean={mean} changed={fraction}'
        path=root/f'{job["title"]}-{record.parent.name[:8]}-page{page["number"]}.png';b.save(path)
        reports.append(dict(job=job['id'],sourcePage=page['number'],outputPage=output+1,meanRGBError=mean,changedPixelFraction=fraction,preview=str(path)))
    # The overflow continuation is part of the real output, never cropped.
    for index in range(len(target)):
        assert target[index].get_width()>0 and target[index].get_height()>0
assert reports, 'no complete translated PDF jobs were available'
result=dict(passed=True,pages=reports,sourceChecks=source_checks,realProviderRequests=0)
(root/'visual-fidelity-checks.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
