#!/usr/bin/env python3
"""Loopback model fixture for the real Swift -> Python -> BabelDOC pipeline."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

harness, runtime, output, source = map(Path, sys.argv[1:5])
output.mkdir(parents=True, exist_ok=True)
source_copy = output / 'source.pdf'
if source.resolve() != source_copy.resolve():
    shutil.copyfile(source, source_copy)
requests = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        authorization = self.headers.get('Authorization', '')
        requests.append({'path': self.path, 'model': body.get('model'), 'hasFixtureBearer': authorization.startswith('Bearer swift-bridge-fixture-'), 'hasGlossary': '工作记忆' in json.dumps(body,ensure_ascii=False)})
        prompt = body['messages'][-1]['content']
        marker = '## Here is the input:'
        if marker in prompt:
            items = json.loads(prompt.rsplit(marker, 1)[1].strip())
            values = []
            for item in items:
                translated = item['input']
                for before, after in [('Working memory','工作记忆'),('working memory','工作记忆'),('Learning outcomes','学习成果'),('learning outcomes','学习成果'),('Practice','练习'),('Students','学生')]:
                    translated = translated.replace(before, after)
                values.append({'id': item['id'], 'output': translated})
            content = json.dumps(values, ensure_ascii=False)
        else:
            content = '工作记忆帮助学生学习。'
        data = json.dumps({'id':'mock-response','object':'chat.completion','created':1,'model':body['model'],'choices':[{'index':0,'finish_reason':'stop','message':{'role':'assistant','content':content}}],'usage':{'prompt_tokens':20,'completion_tokens':10,'total_tokens':30}}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    command = [str(harness.resolve()), str(output.resolve()), str(runtime.resolve()), f'http://127.0.0.1:{server.server_port}/v1', str(source_copy.resolve())]
    completed = subprocess.run(command, capture_output=True, timeout=240)
    (output / 'harness.stdout.txt').write_bytes(completed.stdout)
    (output / 'harness.stderr.txt').write_bytes(completed.stderr)
    if completed.returncode:
        raise SystemExit('Swift bridge failed; see ' + str(output / 'harness.stderr.txt'))
    assert len(requests) >= 2
    assert all(r['path'] == '/v1/chat/completions' and r['model'] == 'fixture-swift-selected-model' and r['hasFixtureBearer'] for r in requests)
    assert any(r['hasGlossary'] for r in requests)
    report = {'passed':True,'checks':['actual Swift BabelDOCBridge launched real engine using stripped environment and private HOME','chosen model, scoped credential and glossary verified at loopback HTTP boundary','both output PDFs published only after native verification and process cleanup'],'fakeModelRequests':len(requests),'realProviderRequests':0,'requestAudit':requests}
    (output / 'server-results.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
    print(completed.stdout.decode().strip())
    print('Loopback model assertions passed:',len(requests),'requests; zero real-provider traffic')
finally:
    server.shutdown()
