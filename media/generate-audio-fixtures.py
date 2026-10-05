#!/usr/bin/env python3
"""Generate fictional English/Japanese ASR test speech, never promotional audio."""
import argparse, hashlib, json, re, urllib.request
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--language', choices=['en', 'ja'], default='ja')
    parser.add_argument('--cache', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True,
                        help='Separate output directory; committed test audio is not overwritten')
    parser.add_argument('--sample', action='store_true', help='Generate only the first sentence for a quick synthesis check')
    parser.add_argument('--offline', action='store_true', help='Require all locked model inputs to exist locally; never download')
    args = parser.parse_args()
    lock_name = 'fixture-voice-en-model.lock.json' if args.language == 'en' else 'fixture-voice-model.lock.json'
    model_name = 'kokoro-v1_1-zh.pth' if args.language == 'en' else 'kokoro-v1_0.pth'
    pipeline_language = 'a' if args.language == 'en' else 'j'
    lock = json.loads((ROOT/'media'/lock_name).read_text())
    fixture_name = f'fictional-lecture-{args.language}'
    text_path = ROOT/'app/Tests/Fixtures/Audio'/f'{fixture_name}.txt'
    if args.output.resolve() == text_path.parent.resolve():
        parser.error('Use a separate output directory; committed test fixtures must stay unchanged')
    fixtures = json.loads((text_path.parent/'manifest.json').read_text())
    if hashlib.sha256(text_path.read_bytes()).hexdigest() != fixtures['files'][text_path.name]:
        raise RuntimeError('Fictional source text does not match its committed manifest')
    text = text_path.read_text(encoding='utf-8').strip()
    if args.sample:
        text = re.split(r'(?<=[。.!?])\s*', text, maxsplit=1)[0]
        fixture_name += '-sample'
    for name, item in lock['files'].items():
        path = args.cache/name
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            if args.offline: raise FileNotFoundError('Offline model input missing: '+name)
            partial = path.with_suffix(path.suffix+'.partial')
            urllib.request.urlretrieve(f'https://huggingface.co/{lock["repository"]}/resolve/{lock["revision"]}/{name}', partial)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != item['sha256']:
                raise RuntimeError('Fixture voice download checksum mismatch: '+name)
            partial.replace(path)
        if hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Fixture voice checksum mismatch: '+name)
    import numpy as np
    import soundfile as sf
    import torch
    from kokoro import KModel, KPipeline
    torch.set_num_threads(3)
    torch.manual_seed(1)
    model = KModel(repo_id=lock['repository'], config=str(args.cache/'config.json'), model=str(args.cache/model_name)).eval()
    pipeline = KPipeline(lang_code=pipeline_language, repo_id=lock['repository'], model=model)
    pieces = [result.audio.numpy() for result in pipeline(text, voice=str(args.cache/f'voices/{lock["voice"]}.pt'), speed=0.96)]
    if not pieces: raise RuntimeError('No generated fixture audio')
    audio = np.concatenate(pieces)
    args.output.mkdir(parents=True, exist_ok=True)
    destination = args.output/f'{fixture_name}.flac'
    sf.write(destination, audio, 24000, subtype='PCM_16')
    (args.output/f'{fixture_name}.txt').write_text(text+'\n',encoding='utf-8')
    report = {'purpose':'ASR regression fixture only; excluded from the promotional film and media archive',
              'language':args.language, 'sampleOnly':args.sample, 'offline':args.offline, 'modelLock':lock_name,'modelRevision':lock['revision'],
              'voice':lock['voice'],'rate':24000,'samples':len(audio),'seconds':len(audio)/24000,
              'outputSHA256':hashlib.sha256(destination.read_bytes()).hexdigest(),
              'note':'FLAC container bytes may vary by encoder version. Compare decoded PCM as well as the pinned source inputs.'}
    (args.output/f'{fixture_name}-generation.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report))
if __name__ == '__main__': main()
