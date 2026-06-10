# ARW QuickLook

Fast Quick Look previews and Finder thumbnails for Sony **ARW** files on macOS.

Instead of developing the raw sensor data (what Apple's built-in handler does → ~2 s
per image), the JPEG preview embedded in every ARW is used (**~20 ms**). The full
resolution then loads immediately in the background and swaps in without changing
the framing — moving to another image cancels it.

## How it works

| Path | Method | Measured (A7 IV, 33 MP) |
|------|--------|-------------------------|
| Preview (instant) | `CGImageSourceCreateThumbnailAtIndex` → embedded JPEG (1616 px) | ~20 ms (first image ~240 ms, one-time codec load) |
| Full resolution (background) | `CIRAWFilter` (GPU) → IOSurface | ~560 ms warm |

Flow in the preview panel (`PreviewViewController`):

1. Show the embedded preview instantly, fit to the window.
2. Start the full-resolution decode in the background right away (non-blocking).
3. Swap the sharp image in — same zoom/scroll position, it just gets sharper.
4. Moving to another image cancels the pending decode (decodes are serialized
   through an actor; a queued decode whose task was cancelled never starts).
5. The status chip (bottom left) names what's on screen (Preview / Loading… /
   Full) and toggles between the cached embedded and full versions on click.

Zoom and pan like Preview.app: pinch to zoom (floor = fit-to-window, so no
letterbox borders), free two-finger panning in any direction.

The full-res render is nudged toward Sony's in-camera look (the embedded JPEG):
`lookExposure` / `lookShadowBoost` in `ARWImageLoader.swift`. Apple's RAW engine
only honors white balance from the file's metadata and ignores Sony's Creative
Look / DRO settings, so its neutral default renders darker than the camera JPEG.

## Build & install

Requirements: Xcode, `brew install xcodegen`.

```sh
./build.sh
```

The script generates the project, builds (ad-hoc signed, no Apple Developer
account needed), installs to `/Applications`, registers the extensions, and
resets Quick Look.

Then **enable both extensions**:
System Settings › General › Login Items & Extensions › **Quick Look** →
turn on `ARWThumbnail` and `ARWPreview`.

## Layout

```
project.yml                         XcodeGen definition (app + 2 extensions)
Sources/Shared/ARWImageLoader.swift embedded preview + full decode
Sources/Thumbnail/                  QLThumbnailProvider (Finder icons)
Sources/Preview/                    QLPreviewingController (spacebar preview)
Sources/App/                        minimal host app
Support/*.plist, *.entitlements     extension configuration & sandbox
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
- The first full decode per process is slow (Metal pipeline warm-up), ~130 ms
  after that.
- Ad-hoc signature loads locally only. For proper signing set `DEVELOPMENT_TEAM`
  in `project.yml` and `CODE_SIGN_IDENTITY` to "Apple Development".
