from pathlib import Path
import hashlib,os,subprocess,sys,importlib.util,shutil
source=Path(__file__).resolve().parents[1]/'macos/CredentialHelper/main.swift'
spec=importlib.util.spec_from_file_location('sign',Path.home()/'f1nb0-launcher/scripts/sign.py');sign=importlib.util.module_from_spec(spec);spec.loader.exec_module(sign)
cache=Path.home()/'.local/share/f1nb0-signing/credential-helpers'
cache.mkdir(mode=0o700,exist_ok=True)
key=hashlib.sha256(source.read_bytes()).hexdigest()
exe=cache/key/'SquareMailCredentials'
if not exe.exists():
    exe.parent.mkdir(mode=0o700)
    sign.run(['swiftc','-O','-module-name','SquareMailCredentials',str(source),'-o',str(exe)])
    # Sign a standalone tool without an application Info.plist.
    import json,shlex,fcntl
    d=sign.identity()
    with (sign.ROOT/'sign.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        search=shlex.split(sign.run(['security','list-keychains','-d','user']).decode())
        try:
            sign.run(['security','unlock-keychain','-p',d['password'],d['keychain']])
            sign.run(['security','list-keychains','-d','user','-s',d['keychain'],*search])
            rule='=designated => identifier "com.finwarman.squaremail.credentials" and certificate leaf = H"'+d['sha1']+'"'
            sign.run(['codesign','--force','--sign',d['sha1'],'--keychain',d['keychain'],'--identifier','com.finwarman.squaremail.credentials','--timestamp=none','--requirements',rule,str(exe)])
        finally:sign.run(['security','list-keychains','-d','user','-s',*search])
    sign.run(['codesign','--verify','--strict',str(exe)])
output=Path(sys.argv[1]);output.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(exe,output)
print('Copied stable credential helper',key[:12])
