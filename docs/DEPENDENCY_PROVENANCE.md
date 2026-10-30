## 0.3.0 Developer Preview packaging boundary

The signed preview app contains the Xcode-built universal Swift executable, Info.plist/signature material, project app/icon resources, and the five docs/Public documents. The Developer Preview wrapper additionally includes current external Documentation/, READ-FIRST.md and CANDIDATE.json without altering the newly signed app. Bundled and external guides match the release source commit; the historical RC is not redistributed. See [DEVELOPER_PREVIEW.md](DEVELOPER_PREVIEW.md) for exact hashes and `scripts/package-developer-preview.py` for wrapper verification. There are no configured Swift packages, Pods or Carthage modules. `scripts/verify-candidate.sh` captures the actual linked libraries with otool, checks byte-for-byte documentation against source, and rejects a bundled yt-dlp. Apple's SDK/system frameworks are not redistributed as standalone component payloads.

The owner has not declared an open-source app licence. The public licence-positioning document states that limitation and does not apply a new open-source licence to third-party materials or claim rights to music/artwork supplied by users or services. The app's existing icon assets remain project assets; no new artwork or unverified third-party art was added for this beta.

### Historical downloader: identified, excluded, preserved

The previously tracked Shared/Resources/yt-dlp was the upstream `yt-dlp_macos` 2026.08.19 universal PyInstaller binary. Its local SHA-256, `0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202`, matches the GitHub release asset digest for https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19 . Its reported version also matched.

Upstream's versioned README explicitly states that PyInstaller-bundled executables contain GPLv3+ code and are GPLv3+ combined works, despite the core repository's Unlicense: https://github.com/yt-dlp/yt-dlp/blob/2026.08.19/README.md#licensing . A full exact corresponding-source package / valid written source offer was not present locally. Adding only a core Unlicense notice would not resolve that.

The smallest release-safe packaging change was to remove that executable from the current source tree and macOS Resources phase, remove helper-copy/quarantine-clearing code, and use the existing separately installed-tool discovery path. This avoids assuming source-offer obligations on the owner's behalf. A local copy of the historical helper and old 0.2.0 ZIP/checksum were preserved in /private/tmp/nightwing-previous-release (not public distribution). Git history was not rewritten. Online downloads are optional and now explicitly require user-installed tools. Restoring a bundled helper requires a fresh licence/corresponding-source review for the exact payload.

### Optional runtime boundary

See docs/Public/THIRD_PARTY_NOTICES.md for directly requested components, pinned versions/hashes/revision, upstream links and known dependency families. These payloads are downloaded after user action or supplied by the user's existing installation; none is in the ZIP. uv's managed Python and caches are scoped to the Nightwing runtime directory. QA mode does not probe/reuse external Python candidates or the user's Hugging Face cache. Runtime install commands/output are retained locally in an append-only runtime-install.log; test/candidate evidence records the actual environment used. This is not a claim of a fully locked transitive graph, nor a blanket LGPL/GPL conclusion about arbitrary installed ffmpeg/PyAV builds.

### Reverification

Run the isolated suite, build with the existing Developer ID/notary pipeline from a clean commit, and run `scripts/verify-candidate.sh dist/Nightwing-macOS.zip --provision` against the exact final ZIP. Recheck the inventory if adding any third-party binary, package, font, asset or model to the app bundle. Do not publish a pre-notary candidate.
