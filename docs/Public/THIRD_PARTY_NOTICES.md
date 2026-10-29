## Components and attribution

### Included in this distributable

Nightwing's Swift source and app/icon resources are built with Apple's Xcode SDK and link Apple's operating-system frameworks (SwiftUI, AppKit, AVFoundation, MediaPlayer, Security, Network, CommonCrypto and system libraries). No Swift Package Manager, CocoaPods or Carthage dependencies are configured. Apple's system frameworks are not copied into the app as third-party libraries. This inventory does not assert independent provenance or a licence grant for the app's icon artwork; the app owner must retain the rights to its own project assets.

**No yt-dlp, Python, ffmpeg, JavaScript runtime, model weights, uv or Python packages are bundled in 0.3.0.** The release pipeline rejects a stale bundled yt-dlp. This is an intentional public-beta packaging change.

### Optional, separately installed or downloaded components

- **yt-dlp**, https://github.com/yt-dlp/yt-dlp : downloader invoked as a separate process when installed by the user. Core source is Unlicense, but upstream's macOS PyInstaller binary is a GPLv3+ combined work with additional components. It must NOT be described as merely Unlicense. See upstream LICENSE and THIRD_PARTY_LICENSES.txt for your exact installed version. Nightwing does not redistribute that binary in this beta.
- **FFmpeg / ffprobe**, https://ffmpeg.org : separately installed conversion tools. Licence depends on build options (LGPL/GPL and potentially other restrictions); inspect the installed build's licence, not a blanket Nightwing claim.
- **Deno / Node**, https://deno.com / https://nodejs.org : separately installed JavaScript runtime usable by yt-dlp. Their own notices apply.
- **uv 0.11.16**, https://github.com/astral-sh/uv : runtime bootstrap downloaded on demand; upstream dual Apache-2.0 / MIT, plus its own third-party notices. Both architecture archives are SHA-256 pinned in source.
- **Managed CPython 3.12**, downloaded by uv from python-build-standalone: Python Software Foundation licence plus bundled-library notices. The exact patch/build is resolved by uv, not pinned by Nightwing. The installation carries its notices; it is not part of this app ZIP.
- **faster-whisper 1.2.1**, https://github.com/SYSTRAN/faster-whisper : MIT. Installed from PyPI with dependency resolution limited to releases before 2026-07-11. Transitive dependencies can include CTranslate2 (MIT), PyAV (BSD-3-Clause, linked FFmpeg with build-dependent terms), tokenizers (Apache-2.0), huggingface-hub (Apache-2.0), onnxruntime (MIT), NumPy (BSD-3-Clause), and their dependencies. This is not a fixed lockfile or an exhaustive claim about arbitrary reused Python environments. Inspect installed *.dist-info metadata/licences and the runtime install log for the actual resolved graph.
- **Systran/faster-whisper-small**, https://huggingface.co/Systran/faster-whisper-small : optional Whisper-derived model, upstream model card declares MIT; revision 536b0662742c02347bc0e980a01041f333bce120 and per-file SHA-256 values are pinned in source. OpenAI Whisper authors and SYSTRAN are credited. Upstream model card: https://huggingface.co/Systran/faster-whisper-small/blob/main/README.md .
- **LRCLIB**, https://lrclib.net : online lyrics data service. API access does not grant ownership or blanket redistribution rights to third-party lyrics.
- **YouTube / YouTube Music (Google)** and **Spotify**: external discovery/playlist services, not sponsors or bundled SDKs. Account access, media and artwork remain governed by provider and rightsholder terms.

Optional software is obtained by the user or the runtime installer directly from its upstream host, not distributed inside Nightwing's ZIP. If a future release bundles any of it, a new exact binary/dependency inventory, notices and any corresponding-source obligations must be fulfilled before distribution. Merely linking this notice is not a substitute for required corresponding source.
