#!/usr/bin/env python3
"""Hash-locked payload staging. No Homebrew, pip install, PyInstaller or system writes.
The only source-built dependency is LGPL-only FFmpeg; matching source accompanies it.
"""
import argparse, hashlib, json, os, plistlib, shlex, shutil, subprocess, tarfile, urllib.request, zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
WORK=ROOT/'dist/media-build'; DOWNLOADS=WORK/'downloads'; PAYLOAD=WORK/'payload'
LOCK=json.loads((ROOT/'scripts/media-tools.lock.json').read_text())
def run(*args, cwd=None):
    subprocess.run([str(x) for x in args], cwd=cwd, check=True)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def fetch(entry):
    p=DOWNLOADS/entry['file']
    if not p.exists():
        tmp=p.with_suffix(p.suffix+'.partial'); urllib.request.urlretrieve(entry['url'],tmp); tmp.replace(p)
    if sha(p)!=entry['sha256']: raise RuntimeError('SHA-256 mismatch: '+p.name)
    return p
def unpack(p, dest):
    dest.mkdir(parents=True,exist_ok=True)
    if p.suffix=='.whl':
        with zipfile.ZipFile(p) as z:z.extractall(dest)
    else:
        run('/usr/bin/tar','-xf',p,'-C',dest)
def prepare():
    WORK.mkdir(parents=True,exist_ok=True);DOWNLOADS.mkdir(exist_ok=True)
    for e in LOCK:fetch(e)
    stamp=hashlib.sha256((ROOT/'scripts/media-tools.lock.json').read_bytes()+(ROOT/'scripts/media-launcher.c').read_bytes()+b''.join((ROOT/'scripts'/name).read_bytes() for name in ('rebuild-ffmpeg.sh','node-entitlements.plist','python-entitlements.plist'))+Path(__file__).read_bytes()).hexdigest()
    if (PAYLOAD/'stamp').exists() and (PAYLOAD/'stamp').read_text()==stamp:return
    if PAYLOAD.exists():shutil.rmtree(PAYLOAD)
    PAYLOAD.mkdir(); binary=PAYLOAD/'MacOS/MediaTools';binary.mkdir(parents=True)
    resources=PAYLOAD/'Resources/MediaTools';resources.mkdir(parents=True)
    notices=resources/'Notices';notices.mkdir()
    framework=PAYLOAD/'Frameworks';framework.mkdir(parents=True)
    pkg=WORK/'python-pkg'
    if not pkg.exists():run('pkgutil','--expand-full',DOWNLOADS/'python-3.14.10-macos11.pkg',pkg)
    signature=subprocess.check_output(['pkgutil','--check-signature',str(DOWNLOADS/'python-3.14.10-macos11.pkg')],text=True)
    if 'Developer ID Installer: Python Software Foundation (BMM5U3QVKW)' not in signature:raise RuntimeError('Unexpected CPython installer signer')
    (resources/'CPython-installer-signature.txt').write_text(signature)
    original=pkg/'Python_Framework.pkg/Payload/Versions/3.14'
    shutil.copy2(original/'Python',framework/'libpython3.14.dylib')
    stdlib=resources/'python'
    shutil.copytree(original/'lib/python3.14',stdlib,ignore=shutil.ignore_patterns('__pycache__','*.pyc','site-packages','test','tests','idlelib','tkinter','turtledemo','config-*','ensurepip'))
    # Deliberately exclude unused optional native dependencies: Tcl/Tk, ncurses,
    # SQLite/BerkeleyDB, zstd and libmpdecimal. Their pure-Python fallbacks remain.
    excluded=('_tkinter','_curses','_dbm','_gdbm','_sqlite3','_zstd','_decimal','readline','_test','_ctypes_test','xx','_xxtest','_remote_debugging')
    for p in (stdlib/'lib-dynload').iterdir():
        if p.name.startswith(excluded):p.unlink()
    for p in (stdlib/'lib-dynload').iterdir():shutil.move(str(p),framework/p.name)
    (stdlib/'lib-dynload').rmdir()
    for name in ('libssl.3.dylib','libcrypto.3.dylib'):shutil.copy2(original/'lib'/name,framework/name)
    source=WORK/'Python-3.14.10'
    if not source.exists():unpack(DOWNLOADS/'Python-3.14.10.tar.xz',WORK)
    # Mach-O libraries live under Frameworks, not unsigned caches or user writable dirs.
    macho=[framework/'libpython3.14.dylib',*framework.glob('*.dylib'),*framework.glob('*.so')]
    for p in dict.fromkeys(macho):
        run('codesign','--remove-signature',p)
        out=subprocess.check_output(['otool','-L',str(p)],text=True)
        deps=set(line.strip().split(' (')[0] for line in out.splitlines() if ' (compatibility ' in line)
        for dep in deps:
            if dep.startswith('/Library/Frameworks/Python.framework/'):
                target=framework/('libpython3.14.dylib' if Path(dep).name=='Python' else Path(dep).name)
                if not target.exists():raise RuntimeError('Uninventoried Python dependency: '+dep)
                relative=os.path.relpath(target,p.parent)
                run('install_name_tool','-change',dep,'@loader_path/'+relative,p)
            elif dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):
                raise RuntimeError('External runtime dependency: '+dep)
        if p.suffix=='.dylib':run('install_name_tool','-id','@rpath/'+p.name,p)
    includes=original/'include/python3.14'
    run('clang','-arch','arm64','-arch','x86_64','-mmacosx-version-min=11.0','-I',includes,ROOT/'scripts/media-launcher.c',
        '-L',framework,'-lpython3.14','-Wl,-rpath,@executable_path/../../Frameworks','-o',binary/'yt-dlp')
    packages=resources/'site-packages';packages.mkdir()
    for entry in LOCK:
        if entry['file'].endswith('.whl'):unpack(DOWNLOADS/entry['file'],packages)
    # Preserve complete upstream notices, including EJS's vendored JavaScript notices.
    for p in packages.rglob('*'):
        if p.is_file() and ('license' in p.name.lower() or 'copying' in p.name.lower()):
            destination=notices/'PythonPackages'/p.relative_to(packages);destination.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,destination)
    shutil.copy2(source/'LICENSE',notices/'CPython-LICENSE.txt')
    shutil.copy2(source/'Modules/expat/COPYING',notices/'Expat-COPYING.txt')
    shutil.copytree(source/'Modules/_hacl',notices/'HACL-source-and-notices')
    for e in LOCK:
        if e.get('noticePath'):
            with tarfile.open(fetch(e)) as archive:
                for member in archive.getmembers():
                    if member.name.endswith('/'+e['noticePath']):
                        (notices/(e['file']+'-'+e['noticePath'])).write_bytes(archive.extractfile(member).read())
    nodes=[]
    for arch in ('arm64','x64'):
        name='node-v24.22.2-darwin-'+arch; dest=WORK/name
        if not dest.exists():unpack(DOWNLOADS/(name+'.tar.gz'),WORK)
        nodes.append(dest/'bin/node')
        if arch=='arm64':shutil.copy2(dest/'LICENSE',notices/'Node-LICENSE.txt')
    run('lipo','-create',*nodes,'-output',binary/'node')
    ffsource=WORK/'ffmpeg-8.1.3'
    if not ffsource.exists():unpack(DOWNLOADS/'ffmpeg-8.1.3.tar.xz',WORK)
    ff=[]
    for arch in ('arm64','x86_64'):
        build=WORK/('ffmpeg-'+arch);build.mkdir(exist_ok=True)
        flags=['--arch='+arch,'--cc=clang -arch '+arch,'--disable-autodetect','--disable-gpl','--disable-nonfree',
               '--disable-shared','--enable-static','--disable-x86asm','--disable-doc','--disable-debug','--disable-avdevice','--disable-network',
               '--extra-cflags=-mmacosx-version-min=11.0','--extra-ldflags=-mmacosx-version-min=11.0']
        configured=build/'ffbuild/config.mak'
        actual=next((line.split('=',1)[1] for line in configured.read_text().splitlines() if line.startswith('FFMPEG_CONFIGURATION=')), '') if configured.exists() else ''
        if (build/'ffmpeg').exists() and shlex.split(actual)!=flags:
            shutil.rmtree(build);build.mkdir()
        if not (build/'ffmpeg').exists() or not (build/'ffprobe').exists():
            run(ffsource/'configure',*flags,cwd=build)
            run('make','-j8',cwd=build)
        ff.append(build)
    for name in ('ffmpeg','ffprobe'):run('lipo','-create',*(b/name for b in ff),'-output',binary/name)
    for name in ('COPYING.LGPLv2.1','COPYING.LGPLv3','LICENSE.md'):shutil.copy2(ffsource/name,notices/('FFmpeg-'+name))
    # Carry the exact corresponding FFmpeg source and our complete rebuild recipe
    # with EVERY app, not an unfulfilled future written source offer.
    sources=resources/'CorrespondingSource';sources.mkdir()
    for entry in LOCK:
        if entry['file'].startswith('ffmpeg-') or entry['file'].endswith('.whl'):shutil.copy2(DOWNLOADS/entry['file'],sources/entry['file'])
    for name in ('build-media-tools.py','media-tools.lock.json','media-launcher.c','node-entitlements.plist','python-entitlements.plist','rebuild-ffmpeg.sh'):shutil.copy2(ROOT/'scripts'/name,sources/name)
    (sources/'README.txt').write_text('FFmpeg is unmodified 8.1.3, configured LGPL-only, static, with no non-system external libraries. Exact source archive and build recipe are here. Run ./rebuild-ffmpeg.sh on macOS with Xcode command-line tools; it verifies the source hash and rebuilds both architectures without needing other downloads. The full app build-media-tools.py recipe is also included. No proprietary object is linked with FFmpeg. Python-package wheels include their source (including MPL-2.0 certifi). No GPL PyInstaller combined executable is redistributed.\n')
    shutil.copy2(ROOT/'scripts/media-tools.lock.json',resources/'INPUTS.json')
    (resources/'BUILD.json').write_text(json.dumps(dict(clang=subprocess.check_output(['clang','--version'],text=True),
        xcode=subprocess.check_output(['xcodebuild','-version'],text=True),FFmpegConfigurations={a:next(line for line in (WORK/('ffmpeg-'+a)/'ffbuild/config.mak').read_text().splitlines() if line.startswith('FFMPEG_CONFIGURATION=')) for a in ('arm64','x86_64')}),indent=2)+'\n')
    (PAYLOAD/'stamp').write_text(stamp)
def stage(app, identity):
    app=app.resolve()
    info=app/'Contents/Info.plist'
    if app.suffix!='.app' or not info.is_file() or plistlib.loads(info.read_bytes()).get('CFBundleIdentifier')!='com.rayzhu.nightwing.macos':
        raise RuntimeError('Staging target must be a built Nightwing macOS app')
    prepare()
    previous=app/'Contents/Resources/MediaTools/INVENTORY.json'
    if previous.exists():
        for item in json.loads(previous.read_text())['files']:
            relative=Path(item['path'])
            if len(relative.parts)==2 and relative.parts[0]=='Frameworks' and relative.suffix in ('.so','.dylib'):
                (app/'Contents'/relative).unlink(missing_ok=True)
    for owned in ('Contents/MacOS/MediaTools','Contents/Resources/MediaTools'):
        if (app/owned).exists():shutil.rmtree(app/owned)
    for folder in ('MacOS','Frameworks','Resources'):
        shutil.copytree(PAYLOAD/folder,app/'Contents'/folder,dirs_exist_ok=True)
    binary=app/'Contents/MacOS/MediaTools'; framework=app/'Contents/Frameworks'
    native=[p for p in framework.rglob('*') if p.is_file() and p.suffix in ('.so','.dylib')]+list(binary.iterdir())
    native_evidence=[]
    for p in native:
        args=['codesign','--force','--options','runtime','--timestamp','--sign',identity]
        if p.name in ('node','yt-dlp'):args+=['--entitlements',str(ROOT/'scripts'/('node-entitlements.plist' if p.name=='node' else 'python-entitlements.plist'))]
        run(*args,p);run('lipo',p,'-verify_arch','arm64','x86_64')
        signature=subprocess.check_output(['codesign','-dvv',str(p)],stderr=subprocess.STDOUT,text=True)
        if '(runtime)' not in signature or 'Timestamp=' not in signature or 'TeamIdentifier=6G8K3FNTVJ' not in signature:
            raise RuntimeError('Unexpected nested signing state: '+str(p))
        linked=subprocess.check_output(['otool','-L',str(p)],text=True)
        for line in linked.splitlines():
            if ' (compatibility ' in line:
                dep=line.strip().split(' (')[0]
                if dep.startswith('/') and not dep.startswith(('/usr/lib/','/System/Library/')):raise RuntimeError('External linked dependency: '+dep)
        native_evidence.append(dict(path=str(p.relative_to(app/'Contents')),signature=signature,linkedLibraries=linked))
    resources=app/'Contents/Resources/MediaTools'
    (resources/'NATIVE.json').write_text(json.dumps(native_evidence,indent=2)+'\n')
    inventory=[]
    for root in (binary,framework,resources):
        for p in sorted(root.rglob('*')):
            if p.is_file() and p.name!='INVENTORY.json':inventory.append(dict(path=str(p.relative_to(app/'Contents')),sha256=sha(p),bytes=p.stat().st_size))
    (resources/'INVENTORY.json').write_text(json.dumps(dict(schema=1,versions={'yt-dlp':'2026.10.26','CPython':'3.14.10','FFmpeg':'8.1.3','Node':'24.22.2','yt-dlp-ejs':'0.8.0','certifi':'2026.10.23'},files=inventory),indent=2)+'\n')
def verify(app):
    resources=app/'Contents/Resources/MediaTools'
    inventory=json.loads((resources/'INVENTORY.json').read_text())
    for item in inventory['files']:
        p=app/'Contents'/item['path']
        if not p.is_file() or sha(p)!=item['sha256']:raise RuntimeError('Payload mismatch: '+str(p))
    for name in ('yt-dlp','ffmpeg','ffprobe','node'):
        p=app/'Contents/MacOS/MediaTools'/name
        run('codesign','--verify','--strict',p);run('lipo',p,'-verify_arch','arm64','x86_64')
        for arch in ('arm64','x86_64'):subprocess.run(['/usr/bin/arch','-'+arch,str(p)]+(['--ignore-config','--no-plugin-dirs','--no-update','--version'] if name=='yt-dlp' else ['--version' if name=='node' else '-version']),check=True,timeout=20)
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--stage',type=Path);parser.add_argument('--verify',type=Path);parser.add_argument('--identity',default='Developer ID Application: Ray Zhu (6G8K3FNTVJ)');args=parser.parse_args()
    if args.verify:verify(args.verify)
    elif args.stage:stage(args.stage,args.identity)
    else:prepare()
