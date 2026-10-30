#!/usr/bin/env python3
"""Build/sign current clean HEAD and package an explicitly unnotarized preview; no upload."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
SOURCE_COMMIT = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
NAME = 'Nightwing-0.3.0-b3-DEVELOPER-PREVIEW-UNNOTARIZED.zip'

def run(*args, check=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout}')
    return result

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def inventory(directory):
    return {str(p.relative_to(directory)): (('link', str(p.readlink())) if p.is_symlink()
            else ('file', sha(p), p.stat().st_mode & 0o777))
            for p in directory.rglob('*') if p.is_symlink() or p.is_file()}

require(not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=ROOT),
        'Preview builds require a clean committed tree')
DIST.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='nightwing-preview-', dir='/private/tmp') as temporary:
    work = Path(temporary)
    package = work / 'Nightwing-Developer-Preview'
    package.mkdir()
    archive = work / 'Nightwing.xcarchive'
    build = run('xcodebuild', '-project', str(ROOT / 'Nightwing.xcodeproj'),
                '-scheme', 'Nightwing macOS', '-configuration', 'Release',
                '-derivedDataPath', str(work / 'DerivedData'), '-archivePath', str(archive),
                'DEVELOPMENT_TEAM=6G8K3FNTVJ',
                'CODE_SIGN_IDENTITY=Developer ID Application: Ray Zhu (6G8K3FNTVJ)',
                'CODE_SIGN_STYLE=Manual', 'ENABLE_CODE_COVERAGE=NO', 'CLANG_COVERAGE_MAPPING=NO',
                'DEAD_CODE_STRIPPING=YES', 'ONLY_ACTIVE_ARCH=NO', 'ARCHS=arm64 x86_64', 'archive', check=False)
    (DIST / 'DEVELOPER-PREVIEW-BUILD.log').write_text(build.stdout)
    require(build.returncode == 0, 'Archive failed; see dist/DEVELOPER-PREVIEW-BUILD.log')
    app = work / 'Nightwing.app'
    run('ditto', str(archive / 'Products/Applications/Nightwing macOS.app'), str(app))
    run('/usr/libexec/PlistBuddy', '-c', f'Add :NightwingSourceCommit string {SOURCE_COMMIT}',
        str(app / 'Contents/Info.plist'))
    run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign',
        'Developer ID Application: Ray Zhu (6G8K3FNTVJ)', str(app))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    require((info['CFBundleShortVersionString'], info['CFBundleVersion'], info['NightwingSourceCommit'],
             info['LSMinimumSystemVersion']) == ('0.3.0', '3', SOURCE_COMMIT, '26.0'), 'Unexpected app identity')
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    signature = run('codesign', '-dvv', str(app)).stdout
    require('Authority=Developer ID Application: Ray Zhu (6G8K3FNTVJ)' in signature
            and 'TeamIdentifier=6G8K3FNTVJ' in signature and '(runtime)' in signature
            and 'Timestamp=' in signature, 'Unexpected signing state')
    run('lipo', str(app / 'Contents/MacOS/Nightwing macOS'), '-verify_arch', 'arm64', 'x86_64')
    require(not (app / 'Contents/Resources/yt-dlp').exists(), 'Unexpected bundled downloader')
    # Verify all five bundled documents against the clean build commit.
    for name in ('INSTALL.md', 'RELEASE_NOTES.md', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE.txt'):
        expected = subprocess.check_output(['git', 'show', f'{SOURCE_COMMIT}:docs/Public/{name}'], cwd=ROOT)
        require((app / 'Contents/Resources/Public' / name).read_bytes() == expected,
                f'Bundled document differs from build commit: {name}')
    gatekeeper = run('spctl', '--assess', '--type', 'execute', '--verbose=4', str(app), check=False)
    require(gatekeeper.returncode != 0 and 'Unnotarized Developer ID' in gatekeeper.stdout,
            f'Unexpected Gatekeeper result: {gatekeeper.stdout}')
    staple = run('xcrun', 'stapler', 'validate', str(app), check=False)
    require(staple.returncode != 0 and 'does not have a ticket stapled' in staple.stdout,
            f'Unexpected staple result: {staple.stdout}')
    run('ditto', str(app), str(package / 'Nightwing.app'))
    shutil.copytree(ROOT / 'docs/Public', package / 'Documentation')
    read_first = '''# Nightwing 0.3.0 (3) — Developer Preview

GitHub-only opt-in prerelease, NOT a production release. Developer ID signed by Ray Zhu
(team 6G8K3FNTVJ), NOT notarized; no stapled ticket. Gatekeeper first-open blocking is expected.
Requires macOS 26.0+; universal arm64/x86_64. Physical Intel hardware was not tested.

Read Documentation/INSTALL.md BEFORE opening or replacing an installed app. It contains the
System Settings > Privacy & Security > Open Anyway first-open procedure, prerequisites,
backup/recovery, known limits and support path. Do not disable Gatekeeper or remove quarantine.

IMPORTANT: Nightwing.app was rebuilt from the clean source commit recorded in CANDIDATE.json,
then Developer ID signed. Bundled and external guides both describe this unnotarized preview.
No notarization is claimed. The earlier historical RC is NOT the released app.

See CANDIDATE.json for the embedded source commit (0.3.0 build 3).
Check the preview ZIP with its adjacent .sha256 file.

Core local playback/imports work offline. Online downloads require separately installed yt-dlp,
ffmpeg/ffprobe and supported JavaScript runtime (Deno recommended); these are NOT bundled.
Read Documentation/PRIVACY.md before online search, lyrics, downloads, OAuth or optional
model/runtime provisioning. Back up the application-support directory and original music first.

No automatic updater. Best-effort non-sensitive issues: https://github.com/rayzhudev/nightwing/issues
Never post credentials, full library data, private paths, playlists or audio in public issues.
'''
    (package / 'READ-FIRST.md').write_text(read_first)
    identity = dict(version='0.3.0', build='3', channel='GitHub-only Developer Preview',
                    sourceCommit=SOURCE_COMMIT, buildFromCleanHEAD=True,
                    architectures=['arm64', 'x86_64'], minimumMacOS='26.0',
                    signature='Developer ID Application: Ray Zhu (6G8K3FNTVJ); hardened runtime; timestamped',
                    notarized=False, stapled=False, gatekeeper='rejected: Unnotarized Developer ID',
                    sealedAppUnchanged=True, bundledDocumentation='matches build source commit and external Documentation',
                    physicalIntel='not tested', quarantinedFinderFirstOpen='not tested', publication='not performed')
    (package / 'CANDIDATE.json').write_text(json.dumps(identity, indent=2) + '\n')
    result = DIST / NAME
    run('ditto', '-c', '-k', '--keepParent', str(package), str(result))
    extracted = work / 'verify'
    run('ditto', '-x', '-k', str(result), str(extracted))
    delivered = extracted / package.name
    require(inventory(app) == inventory(delivered / 'Nightwing.app'), 'Packaged app bytes/modes changed')
    require(inventory(package) == inventory(delivered), 'Package extraction differs')
    run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(delivered / 'Nightwing.app'))
    checksum = sha(result)
    (DIST / (NAME + '.sha256')).write_text(f'{checksum}  {NAME}\n')
    identity.update(previewZIP=NAME, previewZIP_SHA256=checksum,
                    verification='clean HEAD build, identity, signature, universal slices, bundled docs, exact extracted bytes/modes and current external docs passed')
    (DIST / 'DEVELOPER-PREVIEW-VERIFICATION.json').write_text(json.dumps(identity, indent=2) + '\n')
    require(subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() == SOURCE_COMMIT,
            'HEAD changed during packaging')
    require(not subprocess.check_output(['git', 'status', '--porcelain', '--untracked-files=normal'], cwd=ROOT),
            'Working tree changed during packaging')
    body = (ROOT / 'docs/GITHUB_PREVIEW_RELEASE.md').read_text()
    body = body.replace('<!-- GENERATED_IDENTITY -->',
                        f'- SHA-256: `{checksum}`\n- App source commit: `{SOURCE_COMMIT}`.')
    (DIST / 'GITHUB-PREVIEW-RELEASE.md').write_text(body)
    print(json.dumps(identity, indent=2))
