#!/usr/bin/env python3
"""Exercise exact signed app's media pipeline using disposable profiles/own fixture.
No library/account/configuration files from the real profile are read or changed.
"""
import argparse, functools, http.server, json, os, subprocess, tempfile, threading, wave
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('app',type=Path);parser.add_argument('--evidence',type=Path,required=True);args=parser.parse_args()
app=args.app.resolve(); evidence=args.evidence.resolve();evidence.mkdir(parents=True,exist_ok=True)
binary=app/'Contents/MacOS/Nightwing macOS';tools=app/'Contents/MacOS/MediaTools'
def run(command, environment=None, timeout=120):
    result=subprocess.run([str(x) for x in command],env=environment,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    if result.returncode:raise RuntimeError(result.stdout)
    return result.stdout
with tempfile.TemporaryDirectory(prefix='nightwing-bundled-media-',dir='/private/tmp') as temp:
    root=Path(temp); web=root/'web';web.mkdir()
    # PCM WAV forces the app's extraction fallback and bundled FFmpeg AAC encoding,
    # not a misleading "already downloaded an M4A" success.
    with wave.open(str(web/'fixture.wav'),'wb') as fixture:
        fixture.setnchannels(1);fixture.setsampwidth(2);fixture.setframerate(44100);fixture.writeframes(bytes(44100*2*3))
    handler=functools.partial(http.server.SimpleHTTPRequestHandler,directory=str(web))
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        for arch in ('arm64','x86_64'):
            profile=root/arch;profile.mkdir();home=root/(arch+'-home');home.mkdir()
            env={k:v for k,v in os.environ.items() if not k.startswith(('PYTHON','DYLD_'))}
            env.update(PATH='/usr/bin:/bin',HOME=str(home),NIGHTWING_PROFILE_DIRECTORY=str(profile),XDG_CACHE_HOME=str(home/'cache'))
            log=run(['/usr/bin/arch','-'+arch,binary,'--release-smoke-test','--media-smoke-url',f'http://127.0.0.1:{server.server_port}/fixture.wav'],env,180)
            (evidence/(arch+'.log')).write_text(log)
            report=json.loads((profile/'smoke-result.json').read_text())
            if report['status']!='passed':raise RuntimeError(json.dumps(report))
            downloaded=Path(report['downloadedFixture']);assert downloaded.is_relative_to(profile) if hasattr(downloaded,'is_relative_to') else str(downloaded).startswith(str(profile)+'/')
            probe=run(['/usr/bin/arch','-'+arch,tools/'ffprobe','-v','error','-show_format','-show_streams','-of','json',downloaded])
            (evidence/(arch+'-ffprobe.json')).write_text(probe)
            streams=json.loads(probe)['streams'];assert any(s['codec_name']=='aac' for s in streams)
            (evidence/(arch+'-smoke.json')).write_text(json.dumps(report,indent=2)+'\n')
            # Real HTTPS request using bundled certificate package and isolated CPython.
            # Public yt-dlp test video: no cookies/account use; provider failure is logged separately.
            command=['/usr/bin/arch','-'+arch,str(tools/'yt-dlp'),'--ignore-config','--no-plugin-dirs','--no-update','--no-remote-components','--ffmpeg-location',str(tools),'--no-js-runtimes','--js-runtimes','node:'+str(tools/'node'),'--verbose','--simulate','--socket-timeout','15','--retries','0','https://www.youtube.com/watch?v=jNQXAC9IVRw']
            try:
                online=subprocess.run(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
                (evidence/(arch+'-online.log')).write_text(online.stdout)
                (evidence/(arch+'-online.json')).write_text(json.dumps(dict(exitCode=online.returncode,providerAvailability='passed' if online.returncode==0 else 'provider probe did not complete; inspect log'),indent=2)+'\n')
            except subprocess.TimeoutExpired as error:
                (evidence/(arch+'-online.json')).write_text(json.dumps(dict(timeout=True,providerAvailability='not verified'))+'\n')
    finally:server.shutdown();server.server_close()
print('Isolated media download/extraction/playback passed on arm64 and Rosetta; evidence:',evidence)
