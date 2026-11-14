# ARW QuickLook

Quick Look preview and Finder thumbnail extensions for Sony ARW files on macOS. See README.md for purpose, usage and the user-facing design, and docs/FINDINGS.md for how each mechanism was found, the dead ends and the measurements. Read FINDINGS.md before changing how files are parsed, rendered or how the preview's controls behave. Everything in this project is English: code, UI strings, docs.

## Architecture

XcodeGen project (`project.yml`): a host app plus two app extensions, Swift 5 mode, macOS 14+.

- `Sources/Shared/ARWImageLoader.swift`
  - `embeddedPreview`: the camera's ~1616 px preview via ImageIO.
  - `openSource` → `FullSource`: the full-size camera JPEG from IFD2 (`JpgFromRaw`), oriented and colour-space tagged from the ARW, or the raw for the `CIRAWFilter` fallback. It holds compressed data only.
  - `render(_:scale:)`: renders a source at a fraction of native size into an IOSurface.
- `Sources/Shared/SonyFocusReader.swift`
  - `SonyFocusInfo`: focus frame, area/focus/tracking modes, point-vs-area classification by frame shape.
  - `TIFFReader`: the bounds-checked IFD walker, shared with the loader.
- `Sources/Shared/SharedSettings.swift`: app ↔ extension settings in `~/Library/Application Support/ARWQuickLook/settings.plist`. Keys: `showFocusPoint`, `showFocusZones`, `controlsAlwaysVisible`.
- `Sources/Preview/PreviewViewController.swift`: the `QLPreviewingController`.
  - It shows the embedded preview instantly.
  - It renders the full image at display resolution (`neededScale` = magnification × backing scale ÷ source pixels per canvas point), re-renders on zoom-in or resize, and releases it in `viewWillDisappear`.
  - `ImageCanvasView` keeps the embedded preview's coordinates for the life of a file; every render stretches into the same frame.
  - `FullResDecoder` (actor) serializes renders; `fileGeneration` drops stale results.
- `Sources/Preview/ControlsCapsule.swift`: the bottom-left icon buttons (embedded/full, AF) and `PreviewRootView`, which reveals them on real pointer movement.
- `Sources/Thumbnail/ThumbnailProvider.swift`: Finder icons from the embedded preview.
- `Sources/App/ARWQuickLookApp.swift`: the host app with the Settings window.

## Rules

- **Never push, create the GitHub repo or publish.** The owner does that. Commit only when asked, as `Raphmatt <71792812+Raphmatt@users.noreply.github.com>`.
- **Don't run `make install` / `build.sh` unprompted.** They replace `/Applications/ARWQuickLook.app` and reset Quick Look. Use `make build` for compile checks.
- **Nothing may visibly change in the preview while flipping through images.** No spinners, no changing text, no controls that resize or appear and disappear per file. State is shown by brightness; details go in tooltips.
- **Never disable a button in the preview.** A disabled NSButton lets the click fall through to Quick Look, which opens the file in its default app. Dim it and make the action a no-op instead.
- **Never render more pixels than the panel shows.** Upgrade on zoom-in or resize, never downgrade while visible, free on close.
- **Every read from an ARW is bounds-checked** (untrusted input in a sandboxed extension). Cap value counts and IFD chain length, and guard against cycles.
- **Settings are shared through the plist, not App Groups.** With ad-hoc signing, macOS 15+ re-prompts for group containers on every rebuild. The App and Preview targets carry a temporary-exception for that folder; Thumbnail needs none.
- **Bundle IDs are `io.github.raphmatt.arwquicklook*`.** Changing them means re-enabling both extensions in System Settings.

## Verified facts (macOS 27.2, Sony A7 IV, 2026-11-14)

- **Full-size JPEG in IFD2:** 7008×4672 (full RAW) or 4608×3072 (M RAW), about q79, 4:2:2, no EXIF/ICC.
  - ImageIO's thumbnail API never returns it.
  - Orientation comes from IFD0 `0x0112`. Colour space comes from ExifIFD `0xA001`: 1 = sRGB; 0xFFFF plus Interop `R03` = Adobe RGB.
- **Render cost:** about 8–14 ms warm per render (GPU submit), about 50 ms to open a source cold. The `CIRAWFilter` fallback takes 560–670 ms.
- **Memory:** the surface is 4 B/px. 33 MP native is 131 MB; fit on 5K is about 69 MB.
- **Sony MakerNote:**
  - `0x2027` FocusLocation (unrotated frame); `0x2037` FocusFrameSize (flag 0x101).
  - `0x201B` focus mode, `0x201C` AF area setting, `0x2021` tracking (only "feature enabled").
  - No eye-vs-face tag exists.
  - Area frames are non-square (1073×808, 706×531, 745×594); points and detections are square.
  - MF stores the image centre.
- **Diagnostics:** `qlmanage -m plugins` doesn't list app extensions; use `pluginkit -mAvv`.

## Checks

```sh
make build                                   # Debug compile, nothing installed
make install                                 # owner only: build, install, register, reset Quick Look
pluginkit -mAvv | grep -i -A1 "arwquicklook\."
log stream --level debug --predicate 'subsystem == "io.github.raphmatt.arwquicklook"'
pgrep -fl ARWPreview; footprint <pid>        # memory of the preview extension
```

There are no automated tests. Preview behaviour needs a manual run in Quick Look after `make install`: flipping with arrow keys, pinch zoom, the controls' reveal and fade, and the AF overlay.

## Open

- The extension's real memory (`footprint`) before and after this rework hasn't been measured.
- It's unverified whether `mouseMoved` reaches the extension's remote view. If not, set `controlsAlwaysVisible`.
- The `CIRAWFilter` fallback hasn't been tested with a real older body (no local files).
- Output is 8-bit sRGB, so Adobe RGB files clip on wide-gamut displays.
- Swift 6 language mode, hardened runtime, Developer ID signing and notarization are still to do.
