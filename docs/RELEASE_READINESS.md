## 0.3.1 (4) local bundled-media candidate readiness

**Local candidate preparation only. Not published, not notarized, no GitHub release asset replacement.** Existing 0.3.0 preview is unchanged. Publication needs a separate explicit instruction.

### Scope and evidence

The new payload uses a repository C launcher plus PSF CPython and pure yt-dlp/EJS/certifi source wheels, universal source-built LGPL-only FFmpeg/ffprobe, and official Node architecture binaries merged into universal code. The historical GPLv3+ PyInstaller binary is not restored. Complete required source accompanies the tools instead of an unsubstantiated source offer. See DEPENDENCY_PROVENANCE.md and THIRD_PARTY_NOTICES.md for the exact inventory/licensing boundary.

Universal Swift compilation and the isolated regression suite pass: 20 XCTest plus 23 Swift Testing tests. Final clean-commit packaging and exact-artifact media acceptance are recorded in the generated dist reports and the final evidence section below. Each helper/native module is individually Developer ID signed with hardened runtime; Node and the CPython launcher have JIT plus unsigned executable memory for V8/system-libffi trampolines on Intel/Rosetta. Library validation is not disabled. The outer app is signed last. This is not Apple notarization.

Online execution ignores user configurations/plugins, never substitutes Homebrew tools or the transcription engine, uses bundled Node/EJS and FFmpeg absolute paths, and scopes media/cache to Nightwing's profile. Settings shows the immutable bundled versions; updates require replacing the whole app. The media fixture exercises real download, forced WAV-to-AAC extraction, import and audio-engine progression in disposable profiles with PATH limited to /usr/bin:/bin. No existing library, accounts or original audio are used.

### Remaining acceptance boundaries

Physical Intel hardware, quarantined Finder/Open Anyway interaction, real provider OAuth/revocation and every device/codec remain unverified. Public provider extraction can be blocked or changed independently of a working bundled toolchain; exact probe results are recorded, not converted into a blanket online-availability claim. Optional transcription/runtime/model acceptance from earlier releases is historical, not freshly rerun here. Provider terms and media rights still apply. No unresolved matching-source block is identified for this deliberately limited payload, but this is an engineering licence inventory, not a legal opinion or guarantee about unrelated optional builds.

### README and system-accent follow-up

Feature descriptions now use direct functional labels, identify Whisper Small (Systran/faster-whisper-small) and LRCLIB accurately, and keep provider/rightsholder terms in the linked setup/legal sections. The previous system-accent option approximated private preference integers and new profiles defaulted to blue. macOS now uses AppKit’s dynamic controlAccentColor by default; explicit saved custom colours remain intact. Isolated tests compare the default with AppKit and preserve green/purple overrides. The app's dark backgrounds are unchanged; no light/dark system-theme claim is made.
