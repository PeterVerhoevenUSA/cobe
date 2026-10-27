# Cobe open-source parts

Cobe (Apple TV) uses the open-source parts below. This folder holds the complete source of every part that Cobe changed, as the LGPL asks, so anyone can study, change and rebuild them.

| Part | Version | Licence | Changed by Cobe | Source |
| --- | --- | --- | --- | --- |
| AetherEngine | 7.36.0 | LGPL 3.0 with App Store exception | Yes | [AetherEngine/](AetherEngine/) here; original: [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine/tree/7.36.0) |
| SMBClient | 0.3.1 | MIT | Yes | [SMBClient/](SMBClient/) here (without its large test files); original: [kishikawakatsumi/SMBClient](https://github.com/kishikawakatsumi/SMBClient/tree/0.3.1) |
| FFmpeg (through FFmpegBuild), with dav1d, zimg and libzvbi | FFmpegBuild 3.7.1 | LGPL 2.1 or later (dav1d BSD 2-Clause, zimg WTFPL, libzvbi LGPL 2.0 or later) | No | [superuser404notfound/FFmpegBuild 3.7.1](https://github.com/superuser404notfound/FFmpegBuild/tree/3.7.1) (build script, patches and licence texts) |
| LibDTSX | 1.0.1 | Apache 2.0 | No | [superuser404notfound/LibDTSX](https://github.com/superuser404notfound/LibDTSX/tree/1.0.1) |
| LibTrueHD | 2.3.1 | MIT and Apache 2.0 | No | [superuser404notfound/LibTrueHD](https://github.com/superuser404notfound/LibTrueHD/tree/2.3.1) |
| LibDovi | 2.1.0 | MIT | No | [superuser404notfound/LibDovi](https://github.com/superuser404notfound/LibDovi/tree/2.1.0) |

FFmpeg and its companions are inside Cobe as separate dynamic frameworks (`Frameworks/AetherLib*.framework`), so they can be replaced with another build. The full licence texts are in the app under Settings > About > Licence Texts.

## What Cobe changed

**AetherEngine** ([patches/aether-cobe.patch](patches/aether-cobe.patch)):
- `LiveTimestampRebaser.swift` (new): some live streams resend their last seconds after a reconnect with a restarted clock. The rebaser recognises the repeated pictures and restores their timestamps, so the existing replay guard drops them instead of showing them twice.
- `LiveStuckClipWatch.swift` (new): spots a live stream that sends the same clip on every connection and tells the app, so it can switch to another copy.
- `HLSSegmentProducer.swift`, `LiveReplayPacketReader.swift`: use the two above.
- `AVIOReader.swift`: one log line also names the stream file.
- `Package.swift`: uses Cobe's own copy of SMBClient (`../SMBClient`).
- Tests for the above (`LiveTimestampRebaserTests`, `LiveStuckClipWatchTests`, `RealResetClockReplayTests`).

**SMBClient** ([patches/smb-cobe.patch](patches/smb-cobe.patch)):
- `Connection.swift`: reads whole framed packets from a buffer. The original read the 4-byte length from whatever a single TCP read returned and could crash on a short read.

## Rebuilding

The folders here are the originals at the versions above with the patches applied (`patch -p1 < ../patches/<name>.patch`). Put `AetherEngine` and `SMBClient` next to each other and open `AetherEngine/Package.swift` in Xcode, or run `swift build` in `AetherEngine` on a Mac.

Questions: peter.verhoeven@xlamediagroup.com
