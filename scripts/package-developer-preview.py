#!/usr/bin/env python3
"""Locally wrap the fixed signed candidate with external preview disclosures; no signing/upload."""
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / 'dist'
SOURCE = DIST / 'Nightwing-0.3.0-b3-UNNOTARIZED-RC.zip'
SOURCE_SHA = 'f84713bc6621c3863e74093a5b2362316cf45b6d721a22df0374c581e027de11'
SOURCE_COMMIT = '4fbd91edb888c477eecd57f5a3c4fefd5fa3546f'
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

require(sha(SOURCE) == SOURCE_SHA, 'Original candidate checksum changed; review required')
with tempfile.TemporaryDirectory(prefix='nightwing-preview-', dir='/private/tmp') as temporary:
    work = Path(temporary)
    original = work / 'original'
    package = work / 'Nightwing-Developer-Preview'
    package.mkdir()
    run('ditto', '-x', '-k', str(SOURCE), str(original))
    app = original / 'Nightwing.app'
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
    # Preserve all five signed documents exactly as recorded in the original source commit.
    for name in ('INSTALL.md', 'RELEASE_NOTES.md', 'PRIVACY.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE.txt'):
        expected = subprocess.check_output(['git', 'show', f'{SOURCE_COMMIT}:docs/Public/{name}'], cwd=ROOT)
        require((app / 'Contents/Resources/Public' / name).read_bytes() == expected,
                f'Original bundled document changed: {name}')
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

IMPORTANT: Nightwing.app is the unchanged signed candidate. Its bundled Privacy & Help install
guide describes an intended notarized beta and is obsolete for this Developer Preview.
Documentation/INSTALL.md and this notice supersede that wording. No notarization is claimed.

The app embedded source commit is 4fbd91edb888c477eecd57f5a3c4fefd5fa3546f (0.3.0 build 3).
Original candidate ZIP SHA-256: f84713bc6621c3863e74093a5b2362316cf45b6d721a22df0374c581e027de11
See CANDIDATE.json for the package identity. Check the OUTER preview ZIP with its adjacent
.sha256 file; the original candidate hash above is not the outer ZIP's checksum.

Core local playback/imports work offline. Online downloads require separately installed yt-dlp,
ffmpeg/ffprobe and supported JavaScript runtime (Deno recommended); these are NOT bundled.
Read Documentation/PRIVACY.md before online search, lyrics, downloads, OAuth or optional
model/runtime provisioning. Back up the application-support directory and original music first.

No automatic updater. Best-effort non-sensitive issues: https://github.com/rayzhudev/nightwing/issues
Never post credentials, full library data, private paths, playlists or audio in public issues.
'''
    (package / 'READ-FIRST.md').write_text(read_first)
    identity = dict(version='0.3.0', build='3', channel='GitHub-only Developer Preview',
                    sourceCommit=SOURCE_COMMIT, originalCandidate=SOURCE.name,
                    originalCandidateSHA256=SOURCE_SHA,
                    architectures=['arm64', 'x86_64'], minimumMacOS='26.0',
                    signature='Developer ID Application: Ray Zhu (6G8K3FNTVJ); hardened runtime; timestamped',
                    notarized=False, stapled=False, gatekeeper='rejected: Unnotarized Developer ID',
                    sealedAppUnchanged=True, bundledDocumentation='historical; external Documentation supersedes install/release wording',
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
                    verification='source hash, identity, signature, universal slices, original docs, exact extracted bytes/modes and current external docs passed')
    (DIST / 'DEVELOPER-PREVIEW-VERIFICATION.json').write_text(json.dumps(identity, indent=2) + '\n')
    print(json.dumps(identity, indent=2))
