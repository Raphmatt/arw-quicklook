# Findings and learnings

How ARW QuickLook came to work the way it does. Two rounds of work: 2026-06-10 and 2026-06-28 (macOS 26.5, Xcode 26.5, Swift 6.3, as recorded on 06-10), and 2026-11-14 on macOS 27.2. All test files came from a Sony A7 IV (33 MP, 7008×4672). Timings are wall-clock on an M1 Max. Claims marked *vendor* or *source* come from documentation, forum posts or other people's code and were not reproduced here.

## 1. The goal

Pressing space on an ARW in Finder should show the photo at once, and Finder icons should show the photo too. Zoom and pan should feel like Preview.app. Full resolution should follow without blocking navigation. No raw editing, no colour grading.

## 2. Why the existing handlers were dropped

| Handler | Result | Why it was not kept |
| --- | --- | --- |
| Affinity (legacy `.qlgenerator` and app extension) | "Really slow" (not timed) | Switched off |
| macOS's built-in RAW handler | Still about 2 s per image with Affinity off | It fully develops the raw every time. There is no setting to make it use the embedded JPEG (*source:* Apple and MacRumors forum threads) |
| Raw Right Away | Not tested | Site offline, project appears dead (*source*) |

macOS has no "pick the handler for this type" setting. You can only switch competitors off in System Settings › General › Login Items & Extensions › Quick Look. Camera RAW types are not locked to the system handler, which is why Affinity could take over ARW and why our extension can too.

### 2.1 Decoder research (*source*, not benchmarked here)

| Candidate | Claimed speed | Notes |
| --- | --- | --- |
| Embedded JPEG via ImageIO | ~10–30 ms | No sensor decode at all |
| RawSpeed v3 (C++, SIMD) | 20–40 % faster than v1, ~2× on A7R IV ARW | Decode only, no demosaic; reachable through LibRaw |
| QuickRaw (Rust, integer-only) | 3–4× faster than LibRaw | Low precision; fine for previews; early-stage |
| LibRaw | Baseline | Full pipeline, LGPL, CPU-only |
| rawler / dnglab (Rust) | n/a | Broad Sony support, API not stable yet |

No GPU ARW decoder was found; Sony's compression is sequential Huffman/delta. Decision: do not decode the sensor for the instant view, and use Apple's own engine (`CIRAWFilter`) as the full-resolution fallback.

### 2.2 chromaforge / lightcraft (investigated 2026-11-14, not used)

- github.com/emmertex/chromaforge is a fork of github.com/storytold/lightcraft. Pure Rust with their own decoders and a wgpu pipeline. Licences: MIT OR Apache-2.0, and MIT OR GPL-3.0.
- Their "camera preview" look-fit aligns 96 px proxies and fits a 3×3 chromaticity matrix, a tone curve, a chroma curve and hue/sat on 2/3 of the pixels, holding 1/3 out.
- *Source:* ΔE drops from 17–26 to 3–10, and 7 of 10 fits are accepted.
- They read Sony DRO (MakerNote 0xb025) only to remove it. Creative Style is never read.
- Neither project reproduces the in-camera render. The full-size camera JPEG (5.2) is exact and faster.

Other options weighed and dropped: tuning `CIRAWFilter` (one fixed look cannot follow per-shot settings), a per-image fitted LUT, and LibRaw (LGPL, CPU-only, not closer to Sony's look).

## 3. How an A7 IV ARW is laid out

An ARW is a TIFF file. The parts this project reads:

| Where | Tag | Content |
| --- | --- | --- |
| IFD0 | 0x0112 | Orientation |
| IFD0 → 0x8769 Exif IFD | 0xA001 | ColorSpace: 1 = sRGB, 0xFFFF = Uncalibrated |
| Exif IFD → Interop IFD | 0x0001 | InteropIndex; "R03" with 0xFFFF = Adobe RGB |
| Exif IFD | 0x927C | MakerNote (Sony IFD) |
| IFD chain | 0x0201 / 0x0202 | JPEG offset / length (PreviewImage, JpgFromRaw) |
| Sony MakerNote | 0x2027, 0x2037, 0x201B, 0x201C, 0x2021 | Focus data, see 5.5 |

Embedded images in an A7 IV file:

- A 1616×1080 preview (about 290 KB). This is what `exiftool -PreviewImageSize` reports and what ImageIO returns.
- A full-size JPEG in IFD2 (JpgFromRaw): 7008×4672 for full-size RAW, 4608×3072 for M-size RAW. Present in every sampled file. Baseline, about quality 79, 4:2:2, with no EXIF and no ICC profile.

The Quick Look type identifier is `com.sony.arw-raw-image`.

## 4. Dead ends

### 4.1 Believing Sony embeds only 1616 px

The June research said Sony embeds only about 1616 px (*source*), and only `exiftool -PreviewImageSize` was checked, which reports 1616×1080. `-JpgFromRaw` was never queried. ImageIO's `CGImageSourceCreateThumbnailAtIndex` agrees: it only ever returns the 1616 px preview, even with `kCGImageSourceThumbnailMaxPixelSize` 8000. So June shipped a `CIRAWFilter` full decode. The full-size JPEG in IFD2 was only found in November by walking the IFD chain ourselves.

### 4.2 The "fast" raw decode that was lazy

A first spike measured a full `CIRAWFilter` decode at 133 ms warm (5,248 ms cold). That was wrong. A later spike showed `CIContext.createCGImage` returning a lazily rendered image: the "decode" finished in 0.5 ms and the real render ran on the main thread when the image was first drawn. That is why moving to the next image froze until the render was done, and why cancelling the task did nothing.

- Fix: render eagerly off the main thread (`deferred: false`, later straight into an IOSurface).
- Real cost, measured: 1,228 ms for the first file, 574–579 ms warm.
- A per-process lock in the RAW codec was also suspected. The spike meant to test it (embedded preview 23.7 ms "during" a decode, 22.9 ms idle) is void: its decode was the lazy one, so nothing was rendering at the time.

### 4.3 The slow embedded/full toggle (~600 ms)

The status chip toggled between the cached embedded and full images. The user measured about 600 ms per click by screen recording, in both directions. Three rounds of fixes did not cure it:

| Change | Reason given at the time (inferred) | Result |
| --- | --- | --- |
| `NSImageView` → two `CALayer`s | `NSImageView` redraws its backing store, sized to 7008×4672 points | Still slow |
| `isHidden` → `zPosition`, plus a same-URL guard in `preparePreviewOfFile` | Core Animation drops textures of hidden layers; Quick Look might re-prepare the same file | Still slow |
| Full render into an IOSurface (zero-copy) | WindowServer re-uploads 131 MB per flip | Still slow |

Before the third round, logging measured click-to-commit at 3–6 ms, so our code was not the bottleneck. The IOSurface change was built on that, and the delay was still there. It was never explained. The chase was stopped; the instrumentation was removed, the IOSurface and `zPosition` design stayed. Commit 09c7216.

### 4.4 Reading the Trash

Finder's Trash window shows "No valid extension found for this content" for ARWs. The same file previews fine through `qlmanage -p`, and thumbnails work. A read-only temporary-exception for `~/.Trash/` did not help, nor did `killall Finder`. Conclusion (inferred): Finder gives sandboxed preview extensions no usable file grant for trashed items. Legacy `.qlgenerator` plugins ran outside the sandbox, which is why Affinity's worked. Verified on macOS 26.5 only.

### 4.5 Brightening the CIRAWFilter render

Apple's RAW engine honours white balance from the file but ignores Sony's Creative Look and DRO; ImageIO does not parse Sony MakerNotes at all. Our render was checked to match Apple's default render, so the darker look is not a bug. A fixed nudge (exposure +0.25, shadow boost 1.3; `lookExposure` / `lookShadowBoost`) was added and is still used for the fallback. It cannot follow per-shot settings, which is why 5.2 replaced it.

### 4.6 Smaller dead ends

- **Disabled buttons.** A click on a disabled `NSButton` falls through to the Quick Look panel, which opens the file in its default app. All buttons stay enabled and swallow clicks they don't want.
- **Status chip text.** Changing text (Preview / Loading… / Full), a spinner and a capsule whose width changed all drew the eye on every image flip. The spinner and "Loading…" were removed.
- **`qlmanage -m plugins`** lists only legacy `.qlgenerator` plugins, not app extensions. `pluginkit -m -p com.apple.quicklook.thumbnail` does not list ours either.
- **FocalPlaneAFPointLocation** (grid 640×428), mapped linearly, did not line up with the focus frame. Not used; the mapping is unknown.

## 5. What works

### 5.1 Instant preview

`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageIfAbsent` (not `…FromImageAlways`, which would decode) and `…WithTransform` for orientation. Measured on A7 IV files, June:

| Case | Time |
| --- | --- |
| First file in a process (RAW codec load) | 224–240 ms |
| Following files | 20–27 ms |
| Old Quick Look path (built-in handler) | about 2 s |

### 5.2 Full resolution from the camera JPEG

`ARWImageLoader` walks the TIFF IFD chain, takes the largest JPEG (0x0201/0x0202) that starts with an SOI marker, and uses it when it is larger than the 1616 px preview. Orientation comes from IFD0 0x0112. Colour space comes from ExifIFD 0xA001 and InteropIndex (section 3). All 4,053 local ARWs from 2026 are sRGB; Adobe RGB was tested on an exiftool-edited copy.

It matches the camera look exactly: Creative Look, DRO, lens corrections. The trade-off is 8-bit JPEG compression at 100 %, and no raw development.

| Measurement (2026-11-14) | Time |
| --- | --- |
| Full decode, warm CLI test | 32–35 ms |
| `openSource` (cold) | about 50 ms |
| Render at scale 0.4 / 0.73 / 1.0, warm, to GPU submit | 8–14 ms |
| First render, cold | about 110 ms |
| `CIRAWFilter` fallback (files without a full-size JPEG) | 560–665 ms |

### 5.3 Rendering at display resolution

BGRA is 4 bytes per pixel, so one full surface is 131 MB at 33 MP and 245 MB at 61 MP (computed). Before 47be85e one full surface was held per open preview and kept after close.

Now the source (camera JPEG or raw) is opened once and rendered at magnification × backing scale. A sharper render is requested when the current one would be upscaled by more than 10 %, with 30 % headroom, snapping to native at 0.85 or more. It is never downgraded while visible and is released in `viewWillDisappear`. Computed sizes: fit on a 5K display about 69 MB, scale 0.4 about 21 MB.

Decodes run through an actor. A queued decode whose task was cancelled never starts; a generation counter keeps cancelled decodes from touching the UI. A running render cannot be aborted and is discarded.

### 5.4 Viewer details

| Problem | Cause | Fix |
| --- | --- | --- |
| Pans locked to one axis | `usesPredominantAxisScrolling` defaults to true | Set to false |
| Zoom out past fit, black borders | `minMagnification` 0.02 | Floor = fit magnification |
| Black letterbox | Views painted black | Transparent views, Quick Look's own background |
| Stutter near fit | CPU resampling of 33 MP (inferred) | Layer-backed views |
| Thumbnail in the bottom-left quarter | Drew a point-sized rect into a pixel-sized Retina context (¼ = 1/scale²) | Draw into `ctx.width` × `ctx.height` |
| Panel only ~80 % of the screen | Fit into a fixed 1400×1000 box, never upscaled | Fit the aspect into the screen's `visibleFrame` × 0.92 |

### 5.5 Focus point from the Sony MakerNote

Path: IFD0 → Exif IFD (0x8769) → MakerNote (0x927C) → Sony IFD. Value offsets are absolute. Older bodies prefix a 12-byte "SONY DSC" or "SONY CAM" header; the A7 IV starts the IFD directly. The first parser assumed the header and returned nothing for every file. After the fix it matched exiftool on 97 files with zero mismatches.

| Tag | Name | Values (ExifTool 13.55 Sony.pm) |
| --- | --- | --- |
| 0x2027 | FocusLocation | width, height, x, y in the unrotated frame |
| 0x2037 | FocusFrameSize | w, h, flag 0x101 |
| 0x201B | FocusMode | 0 MF, 2 AF-S, 3 AF-C, 4 AF-A, 6 DMF |
| 0x201C | AFAreaModeSetting (ILCE) | 0 Wide, 1 Center, 3 Flexible Spot, 11 Zone, 12 Expanded Flexible Spot, 13 Custom |
| 0x2021 | AFTracking | 0 Off, 1 Face tracking, 2 Lock-On AF |

Library scan of 4,053 ARWs:

| AF setting | Files |
| --- | --- |
| Wide + Face tracking | 1986 |
| Center + Off | 1029 |
| Wide + Off | 741 |
| Center + Face tracking | 267 |
| Flexible Spot | 30 |

- Area frames are non-square: Center 1073×808 or 706×531, Flexible Spot 745×594.
- Points and detections are square: Wide without a subject about 153×156; detected eyes and faces 101–483 px. By eye, 101 and 153 px frames sat on an eye, 216 and 438 px frames on a whole face.
- No tag tells eye from face. AFTracking only says the feature was on: five Center + Face tracking files still store the 1073×808 zone. So point vs. area is decided by shape: aspect deviation above 8 % = area (drawn as corner brackets), otherwise a point (green box).
- Manual focus stores the image centre as a fallback; 0x201B = 0 suppresses the frame.
- Only the single final location is stored: no PDAF grid, no tracking history, no multiple subjects. Pre-2015 bodies keep AF data in an encrypted MakerNote section (*source*); they get no AF chip.

### 5.6 Controls

- `NSGlassEffectView` on macOS 26+ (`effectIsInteractive` is 27+), an `NSVisualEffectView` HUD before that.
- Since 2026-11-14 (087168c): two fixed-size icon buttons (embedded/full, AF) on one capsule. State is brightness only; details live in tooltips. The capsule is invisible at rest, fades in on real pointer movement (the screen position is compared with the last one seen, so an image flipped in under a resting pointer doesn't reveal it) and fades out after 1.5 s.
- A view at alpha 0 still receives clicks in AppKit, so the hidden capsule returns nil from `hitTest`.

### 5.7 Diagnostics

- Registration: `pluginkit -mAvv | grep -A1 -i "arwquicklook\."` (`+` = enabled).
- Test: `qlmanage -p <file>`; reset: `qlmanage -r && qlmanage -r cache && killall -KILL quicklookd`.
- Debug-level `os.log` output from the extension shows in `log stream`, not in `log show`.
- After an install, old extension processes can keep serving the previous build until killed.

## 6. Sandbox, signing and packaging

- **Settings sharing.** App Groups were avoided: with ad-hoc signing, macOS 15+ re-prompts for group-container access on every rebuild (*source:* mjtsai.com, Eclectic Light; not tried here). Instead a plist in `~/Library/Application Support/ARWQuickLook/` is shared through `com.apple.security.temporary-exception.files.home-relative-path.read-write`. Only the App and Preview targets carry it; the Thumbnail target has none.
- **Duplicate entry in System Settings.** Launch Services also registered the build product inside the project's `build/` folder, so Login Items & Extensions listed the app twice. `build.sh` now runs `lsregister -u` on the build product (2dab24a); `make build` keeps it out too. Two "Quick Look" labels per row are normal: one per extension.
- **Stray build copies (2026-11-14).** Compile checks with `xcodebuild -derivedDataPath <scratch dir>` left five more registered copies of the app (each unsigned). System Settings listed three ARW entries and the preview didn't load until all copies outside `/Applications` were removed with `lsregister -u`. Only `make build` (which unregisters its product) is used for compile checks now.
- **Bundle IDs** moved to `io.github.raphmatt.arwquicklook*`. A new ID registers disabled, and Quick Look then shows "Extension io.github.raphmatt.arwquicklook.preview not found" (seen 2026-11-14). `build.sh` now enables both with `pluginkit -e use -i <id>`, the same as the System Settings toggle.
- **Signing.** Ad-hoc only, so the build loads on the building Mac only. No prebuilt download: Gatekeeper would block it, and notarisation needs a paid Developer ID.

## 7. Learnings

1. **Don't decode what the camera already rendered.** Both speed wins (the 1616 px preview and the full-size JPEG) came from skipping the sensor decode.
2. **Check what is there, not what one tag reports.** One exiftool tag and ImageIO's thumbnail API both pointed at 1616 px; the full-size JPEG was one IFD away. Walk the file yourself.
3. **Time the work, not the call.** The 133 ms decode was a lazy image; the real 575 ms ran later on the main thread.
4. **Measure before the first fix.** Two toggle fixes were built on explanations before the 3–6 ms commit time showed our code was not the bottleneck.
5. **Shape beats labels.** AF settings say what was enabled, not what happened. The frame's aspect says what was found.
6. **Disabled is not inert.** In Quick Look a disabled button passes the click on, and the panel opens the file.
7. **Anything that moves draws the eye.** Text and width changes in a status chip were noticed on every image flip.
8. **Sizes add up per surface.** A 33 MP BGRA surface is 131 MB; render what the screen can show.

## 8. Open questions

- Memory inside the extension has not been measured (footprint / vmmap pending). The MB figures above are computed.
- Whether the RAW codec serialises work per process (the June test was void, see 4.2).
- What caused the ~600 ms embedded/full toggle delay. Only the 3–6 ms commit is known. It is not known whether it still happens with the display-resolution renders.
- The mapping of FocalPlaneAFPointLocation (640×428 grid) to image coordinates.
- Whether the Trash limitation still holds on macOS 27.
- Bodies other than the A7 IV: whether they have a full-size JPEG in IFD2, use the same MakerNote layout and the same AF value tables.
- Adobe RGB was tested only on one exiftool-edited file, not on a real camera file.
- Whether `mouseMoved` reaches the preview extension's remote view at all. If it doesn't, the controls never appear; `controlsAlwaysVisible = true` in the settings plist keeps them at half strength.
