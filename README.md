# ARW QuickLook

Fast Quick Look previews and Finder thumbnails for Sony **ARW** files on macOS.

> Not affiliated with, endorsed by or supported by Sony. "Sony" and other product
> names are trademarks of their respective owners and are used here only to
> identify the file format and cameras.

Instead of developing the raw sensor data (what Apple's built-in handler does → ~2 s
per image), the JPEG preview embedded in every ARW is used (**~20 ms**). The full
resolution then loads immediately in the background and swaps in without changing
the framing — moving to another image cancels it.

## How it works

| Path | Method | Measured (A7 IV, 33 MP) |
|------|--------|-------------------------|
| Preview (instant) | `CGImageSourceCreateThumbnailAtIndex` → embedded JPEG (1616 px) | ~20 ms (first image ~240 ms, one-time codec load) |
| Full resolution (background) | full-size camera JPEG from IFD2 (`JpgFromRaw`) → IOSurface | ~35 ms warm (M-size RAW: ~15 ms) |
| Full resolution, fallback | `CIRAWFilter` (GPU) → IOSurface, for files without a full-size JPEG | ~560–670 ms warm |

Newer Sony bodies (e.g. the A7 IV) store, besides the 1616 px preview, a
full-size camera JPEG in the ARW's third IFD — 7008×4672 for full-size RAW,
4608×3072 for M-size. ImageIO's thumbnail API never returns it, so
`ARWImageLoader` walks the TIFF IFD chain itself, picks the largest JPEG
(`0x0201`/`0x0202`), and uses it if it is larger than the 1616 px preview. That
JPEG has no EXIF or ICC of its own: orientation comes from the ARW's IFD0
(`0x0112`), and the colour space from its Exif (`ColorSpace` 1 = sRGB;
Uncalibrated + InteropIndex `R03` = Adobe RGB). Files without one (older
bodies) are developed with `CIRAWFilter` instead.

Trade-off: the full-size JPEG is the camera's own 8-bit render (quality ~79,
4:2:2, in-camera noise reduction and sharpening), so it matches the camera look
exactly — Creative Look, DRO, lens corrections — but shows JPEG compression at
100 % zoom and is not a raw development.

Flow in the preview panel (`PreviewViewController`):

1. Show the embedded preview instantly, fit to the window.
2. Start the full-resolution decode in the background right away (non-blocking).
3. Swap the sharp image in — same zoom/scroll position, it just gets sharper.
4. Moving to another image cancels the pending decode (decodes are serialized
   through an actor; a queued decode whose task was cancelled never starts).
5. The status chip (bottom left) names what's on screen (Preview /
   Full) and toggles between the cached embedded and full versions on click.

Zoom and pan like Preview.app: pinch to zoom (floor = fit-to-window, so no
letterbox borders), free two-finger panning in any direction.

## Focus point overlay

A green frame marks where the camera focused (e.g. the eye picked by Eye-AF).
Sony stores this in plain MakerNote tags — `0x2027 FocusLocation` (image
width/height + X/Y, unrotated sensor frame, top-left origin) and
`0x2037 FocusFrameSize` (frame size in pixels, newer bodies only). Apple's
ImageIO does not parse Sony MakerNotes, so `SonyFocusReader` walks the ARW's
TIFF structure directly (IFD0 → Exif IFD → MakerNote → Sony IFD; newer bodies
like the A7 IV write the IFD without the legacy "SONY DSC" header). The
overlay scales with zoom and is mapped through the EXIF orientation for
portrait shots.

Points and areas are drawn differently:

| Camera recorded | Frame | Drawn as |
|---|---|---|
| Wide, Spot, or a detected face/eye (`0x2021` Face/Eye AF) | square, fitted to the point / eye / face | solid green frame |
| Center, Zone, Flexible Spot | wide rectangle (e.g. 1073×808) — only the *area* is known | white corner brackets |
| Manual focus | image centre (a fallback) | nothing; chip shows "MF" |

The classification uses the frame's shape (areas are non-square, points are
square), because the AF-area setting alone is ambiguous: with Face/Eye AF on in
Center mode the camera stores a square face box when it found a face, else the
zone. Sony does not record whether a detection was an eye or a whole face; the
frame size makes it visible. The AF chip names the area mode ("AF · Wide");
its tooltip adds focus mode and subject detection. Areas can be switched off
separately in Settings ("Show general AF areas").

Toggle it with the **AF chip** in the preview (next to the status chip — the
chip is hidden when a file has no focus data) or in the app under
**ARWQuickLook › Settings**. The state is shared via
`~/Library/Application Support/ARWQuickLook/settings.plist`; App Groups were
deliberately avoided because with ad-hoc signing macOS 15+ re-prompts for
group-container access on every rebuild, so all targets carry a sandbox
temporary-exception for that folder instead.

The `CIRAWFilter` fallback is nudged toward Sony's in-camera look:
`lookExposure` / `lookShadowBoost` in `ARWImageLoader.swift`. Apple's RAW engine
only honors white balance from the file's metadata and ignores Sony's Creative
Look / DRO settings, so its neutral default renders darker than the camera JPEG.
Files with a full-size embedded JPEG don't need this: they show the camera's
own render.

## Build & install

Requirements: macOS 14 or later, Xcode, `brew install xcodegen`. Tested on
macOS 27 with files from a Sony A7 IV.

There are no prebuilt downloads: an ad-hoc signed app from the internet would be
blocked by Gatekeeper, and a notarized build needs a paid Apple Developer ID.
Build it yourself:

```sh
make install
```

This runs `build.sh`, which generates the project, builds (ad-hoc signed, no
Apple Developer account needed), installs to `/Applications`, registers the
extensions, and resets Quick Look.

Other targets (`make` lists them):

| Target | Does |
|---|---|
| `make build` | Debug compile only, nothing signed or installed |
| `make uninstall` | Remove the app from `/Applications` and reset Quick Look |
| `make reset` | Reset Quick Look's generators and cache |
| `make clean` | Remove build output and the generated Xcode project |

Then **enable both extensions**:
System Settings › General › Login Items & Extensions › **Quick Look** →
turn on `ARWThumbnail` and `ARWPreview`.

## Layout

```
project.yml                          XcodeGen definition (app + 2 extensions)
Makefile, build.sh                   build / install / uninstall shortcuts
Sources/Shared/ARWImageLoader.swift  embedded preview + full-size JPEG / raw decode
Sources/Shared/SonyFocusReader.swift focus point from the Sony MakerNote + TIFF reader
Sources/Shared/SharedSettings.swift  app ↔ extension settings (shared plist)
Sources/Thumbnail/                   QLThumbnailProvider (Finder icons)
Sources/Preview/                     QLPreviewingController (spacebar preview)
Sources/App/                         host app with Settings window
Support/*.plist, *.entitlements      extension configuration & sandbox
```

## Diagnostics

```sh
# Which generator serves ARW?
qlmanage -m plugins | grep -i arw
pluginkit -m -p com.apple.quicklook.preview | grep -i arw

# Test a preview
qlmanage -p "/path/to/file.ARW"

# Reset Quick Look after changes
qlmanage -r && qlmanage -r cache && killall -KILL quicklookd
```

## Limitations

- **Files in the Trash cannot be previewed from Finder's Trash window**
  ("No valid extension found for this content"). Finder does not give modern
  sandboxed preview extensions a usable file grant for trashed items — verified:
  the same file previews fine via `qlmanage -p`, and a `~/.Trash` sandbox
  read exception does not help either. This is OS policy, not fixable in the
  extension (legacy `.qlgenerator` plugins ran un-sandboxed, which is why e.g.
  Affinity's worked there). Workaround: drag the file out of the Trash.
- The embedded Sony preview is ~1616 px — slightly soft fullscreen until the
  full-resolution image swaps in.
- **Focus point**: only the single, final focus location is stored — Sony does
  not write the full PDAF point grid, tracking history, or multiple subjects,
  so a Lightroom-style "all AF points" display is impossible. With manual focus
  Sony writes the image centre as a fallback; those shots are recognised by the
  focus mode tag and get no frame. Bodies from
  before ~2015 don't write `FocusLocation` at all (their AF data sits in an
  encrypted MakerNote section); for those the AF chip simply doesn't appear.
- The first full-resolution render per process is slower (Metal pipeline
  warm-up); warm timings are in the table above.
- Ad-hoc signature loads locally only. For proper signing set `DEVELOPMENT_TEAM`
  in `project.yml` and `CODE_SIGN_IDENTITY` to "Apple Development".

## Disclaimer

Use at your own risk. This is a hobby project, provided as is, with no guarantee
that it works for you. The extensions only read your ARW files and never change
them. `build.sh` replaces `/Applications/ARWQuickLook.app` and resets Quick Look's
cache. You are responsible for how you use it; I can't offer support.

## Use of AI

This project was developed with AI assistance, using Anthropic's Claude models in
Claude Code:

- **Claude Opus 4.8:** the research into fast ARW decoding, the first version of
  the app and both extensions, and the thumbnail and window-size fixes.
- **Claude Fable 5:** the speed work on the preview, the focus point overlay, the
  shared settings and the Launch Services fix in the build script.
- **Claude Opus 5.5:** the full-size embedded JPEG path, the glass controls, the
  AF area modes and the loading fixes.
- **Claude Fable 5.2:** a review of the code and the preview's controls.

Testing with my own camera files and all decisions were done by me.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Raphmatt.
