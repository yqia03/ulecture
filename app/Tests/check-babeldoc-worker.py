#!/usr/bin/env python3
"""Run real BabelDOC against a loopback-only fake model; never uses real keys."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pymupdf

runtime = Path(sys.argv[1]).resolve()
root = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path(tempfile.mkdtemp(prefix='ulecture-babeldoc-check-'))
root.mkdir(parents=True, exist_ok=True)
source = root / 'source.pdf'
doc = pymupdf.open()
for number in range(2):
    page = doc.new_page(width=595, height=842)
    page.draw_rect(pymupdf.Rect(45, 45, 550, 90), color=(0.15, .35, .7), fill=(.92, .95, 1))
    page.insert_text((60, 73), 'Learning outcomes', fontsize=16)
    page.insert_textbox(pymupdf.Rect(60, 115, 535, 215), 'Working memory supports learning and attention. Students use working memory to understand lessons and solve problems. Practice improves learning outcomes.', fontsize=12)
    page.insert_text((60, 245), 'E = mc2', fontsize=12)
    page.draw_rect(pymupdf.Rect(60, 285, 535, 380), color=(.3,.3,.3))
    page.draw_line((60,330),(535,330),color=(.3,.3,.3))
    page.insert_text((75,310), 'Working memory helps students.', fontsize=12)
    page.insert_text((75,357), 'Practice supports learning outcomes.', fontsize=12)
    page.insert_text((60, 800), f'Page {number + 1}', fontsize=10)
doc.save(source)
doc.close()
requests = []
response_status = 200
response_finish = 'stop'
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        request = json.loads(raw)
        requests.append({'path': self.path, 'authorization': self.headers.get('Authorization'), 'body': request})
        if response_status != 200:
            data = json.dumps({'error': {'message': 'fixture-only-secret MUST NEVER LEAK'}}).encode()
        else:
            prompt = request['messages'][-1]['content']
            marker = '## Here is the input:'
            if marker in prompt:
                items = json.loads(prompt.rsplit(marker,1)[1].strip())
                translated = []
                for item in items:
                    text = item['input']
                    for a,b in [('Working memory','工作记忆'),('working memory','工作记忆'),('Learning outcomes','学习成果'),('learning outcomes','学习成果'),('Practice','练习'),('Students','学生')]:
                        text = text.replace(a,b)
                    translated.append({'id':item['id'],'output':text})
                content = json.dumps(translated, ensure_ascii=False)
            else:
                content = '工作记忆帮助学生学习。'
            data = json.dumps({'id':'mock-response','object':'chat.completion','created':1,'model':request['model'], 'choices':[{'index':0,'finish_reason':response_finish,'message':{'role':'assistant','content':content}}], 'usage':{'prompt_tokens':20,'completion_tokens':10,'total_tokens':30}}).encode()
        self.send_response(response_status)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)))
        self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
checks=[]
def run(mode, name=None, endpoint=None):
    name=name or mode
    request={'schema':1,'inputPDF':str(source),'outputDirectory':str(root/name),'cacheDirectory':str(root/(name+'-cache')), 'sourceLanguage':'en','targetLanguage':'zh-Hans','mode':mode, 'model':'fixture-selected-model','baseURL':endpoint or f'http://127.0.0.1:{server.server_port}/v1','apiKey':'fixture-only-secret', 'domain':'education','terms':[{'source':'Working memory','translation':'工作记忆','note':'Use this exact course term.'}]}
    result=subprocess.run([str(runtime/'runtime/bin/python3'),'-I','-B','-u',str(runtime/'worker.py')],input=json.dumps(request).encode(),capture_output=True,timeout=180)
    assert b'fixture-only-secret' not in result.stdout + result.stderr, result.stdout
    events=[json.loads(line) for line in result.stdout.splitlines()]
    (root/(name+'-events.json')).write_text(json.dumps(events,ensure_ascii=False,indent=2))
    return result,events
for mode in ('translated','bilingual'):
    before=len(requests)
    process,events=run(mode)
    assert process.returncode == 0, events
    result=events[-1]
    assert result['type']=='result' and result['engineVersion']=='0.6.4', result
    output=pymupdf.open(result['outputPath'])
    assert len(output)==(2 if mode=='translated' else 4)
    text='\n'.join(page.get_text() for page in output)
    assert '工作记忆' in text, text
    assert result['inputTokens']>0 and result['outputTokens']>0
    assert len(requests)>before
    assert all(r['path']=='/v1/chat/completions' and r['authorization']=='Bearer fixture-only-secret' and r['body']['model']=='fixture-selected-model' for r in requests[before:])
    assert any('工作记忆' in json.dumps(r['body'],ensure_ascii=False) for r in requests[before:])
    assert any(e['type']=='progress' for e in events)
    output[0 if mode=='translated' else 1].get_pixmap(matrix=pymupdf.Matrix(1,1)).save(root/(mode+'-preview.png'))
    output.close()
    assert not any(p.name.startswith('work-') for p in (root/(mode+'-cache')).iterdir())
    checks.append(mode+' real BabelDOC rendered Chinese and preserved expected page count; model/auth/terminology verified')
response_status=401
process,events=run('translated','authentication')
assert process.returncode!=0 and events[-1]=={'type':'error','code':'authentication'}, events
checks.append('provider failure returns safe code without secret or successful partial artifact')
response_status=200;response_finish='length'
process,events=run('translated','truncated')
assert process.returncode!=0 and events[-1]=={'type':'error','code':'malformedResponse'}, events
checks.append('truncated model completion cannot become a successful translated document')
before=len(requests)
process,events=run('translated','invalid-endpoint','https://user:secret@example.com/v1')
assert process.returncode!=0 and events[-1]=={'type':'error','code':'invalidConfiguration'} and len(requests)==before
checks.append('invalid endpoint rejected before external request')
server.shutdown()
report={'passed':True,'checks':checks,'fakeModelRequests':len(requests),'realProviderRequests':0,'evidenceDirectory':str(root)}
(root/'babeldoc-worker-checks.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
