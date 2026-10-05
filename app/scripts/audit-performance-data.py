"""Independent read-only SQLite and byte audit of a completed fictional performance replay."""
import sqlite3,pathlib,json,hashlib,sys,datetime
p=pathlib.Path(sys.argv[1]).resolve();identity=json.loads((p/'identity.json').read_text());fixture=json.loads((p/'workspace/performance-fixture.json').read_text());base=p/'workspace/Transcripts'/fixture['course']/fixture['classroom']
library=sqlite3.connect(f'file:{p}/workspace/Workspace/library.sqlite?mode=ro',uri=True)
session=sqlite3.connect(f'file:{base}/session.sqlite?mode=ro',uri=True)
def records(db,collection):
 return {r[0]:json.loads(r[1]) for r in db.execute('SELECT id,json FROM records WHERE collection=? AND owner_id=?',(collection,fixture['classroom']))}
meta={k:json.loads(v) if k in ['session','text_publication'] else v for k,v in session.execute('SELECT key,value FROM metadata')}
rows=records(session,'transcripts');clouds=records(session,'cloud-state');classes=records(session,'classrooms');classroom=classes[fixture['classroom']]
checks={c:records(library,c)==records(session,c) for c in ['transcripts','cloud-state','classrooms','recordings','gaps']}
assert all(checks.values()),checks
ordered=sorted(rows.values(),key=lambda r:(r['startMS'],r['id']))
translations={}
for state in clouds.values():
 for job in state['jobs']:
  t=job.get('translation')
  if job['status']=='completed' and t and t['segmentID'] in rows and t['sourceRevision']==rows[t['segmentID']]['revision'] and t['targetLanguage']==classroom['targetLanguage'] and job['targetLanguage']==classroom['targetLanguage']:
   translations[t['segmentID']]=t['text'].replace('\r\n','\n').replace('\r','\n')
def time(ms):
 return f'{ms//3600000:02d}:{ms//60000%60:02d}:{ms//1000%60:02d}.{ms%1000:03d}'
results={}
for bilingual,filename in [(False,'transcript.txt'),(True,'transcript-bilingual.txt')]:
 blocks=[]
 for row in ordered:
  text=row['text'].replace('\r\n','\n').replace('\r','\n')
  if bilingual and row['id'] in translations:text+='\n'+translations[row['id']]
  blocks.append(f'[{time(row["startMS"])} – {time(row["endMS"])}]\n'+text)
 expected=(meta['session']['title']+'\n\n'+'\n\n'.join(blocks)+'\n').encode('utf-8')
 actual=(base/filename).read_bytes();actual.decode('utf-8');sha=hashlib.sha256(actual).hexdigest()
 assert actual==expected,filename
 assert meta['text_publication']['hashes'][filename]==sha,filename
 results[filename]={'bytes':len(actual),'sha256':sha,'matchesAllCommittedRecords':True,'matchesPublicationReceipt':True}
assert meta['text_publication']['published'] is True
assert len(rows)==identity['count'] and len(rows)>0 and len(translations)==len(rows)
assert len(records(session,'recordings'))==identity['recordings']
report={'utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'passed':True,'boundary':'Independent read-only SQLite/UTF-8 byte audit of the completed fictional replay; wall-clock duration, capture coverage, sleep observations and real device/cloud tests are separate requirements.','confirmedSourceCount':len(rows),'correctRevisionTranslationCount':len(translations),'recordingCount':len(records(session,'recordings')),'centralAndSessionRecordsEqual':checks,'publishedPair':True,'generation':meta['text_publication']['generation'],'files':results}
(p/'independent-data-audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2));print(json.dumps(report,ensure_ascii=False,indent=2))
