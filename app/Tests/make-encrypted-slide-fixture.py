"""Encrypt only our synthetic slide and verify its decrypted bytes.

Test-only deps: msoffcrypto-tool 5.4.2 and olefile 0.47, installed under the
project scratch directory. Neither library is shipped or used by ULecture.
API: https://msoffcrypto-tool.readthedocs.io/en/latest/#encryption-ooxml-only-experimental
"""
from pathlib import Path
import hashlib, io, json, sys
fixture=Path(sys.argv[1])
import msoffcrypto
from msoffcrypto.format.ooxml import OOXMLFile
original=(fixture/'lesson.pptx').read_bytes()
encrypted=io.BytesIO();OOXMLFile(io.BytesIO(original)).encrypt('fixture-password',encrypted)
encrypted.seek(0);check=msoffcrypto.OfficeFile(encrypted);assert check.is_encrypted()
check.load_key(password='fixture-password',verify_password=True);decrypted=io.BytesIO();check.decrypt(decrypted,verify_integrity=True)
assert decrypted.getvalue()==original
(fixture/'encrypted.pptx').write_bytes(encrypted.getvalue())
result=dict(sourceSHA256=hashlib.sha256(original).hexdigest(),encryptedSHA256=hashlib.sha256(encrypted.getvalue()).hexdigest(),roundTripVerified=True,dependencies={'msoffcrypto-tool':'5.4.2','olefile':'0.47'},purpose='Synthetic input rejection fixture only')
(fixture/'encrypted-fixture.json').write_text(json.dumps(result,indent=2));print(json.dumps(result))
