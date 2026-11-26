# Dewrinkle

A macOS app for taking wrinkles out of clothing in a photograph without sanding off the cloth. It is aimed at a fashion and product photographer who shoots a Nikon Z8, grades in Capture One, and wants the weave, the topstitching, and the intentional drape of a hijab, abaya, or gown to survive.

The edit is frequency separation, not a beauty blur. A wide Gaussian splits the frame into a low layer (tone, shading, creases) and a high layer (weave and thread). Only the low layer is flattened, and only inside a mask. Seams, stitches, and buttons are held back by a thin edge mask. Denoise, when you turn it on, runs first.

The processing core was tested on Linux. GitHub Actions builds the Mac app (Xcode 16, ad-hoc signature, arm64) and, on `main`, attaches `Dewrinkle-macOS.zip` to the rolling [latest release](https://github.com/saufisulaiman91-arch/dewrinkle/releases/latest). The window itself has not been launched from this repository.

## Download

An Apple Silicon Mac on macOS Sonoma 14 or later is enough. You do not need Xcode or a paid Apple Developer account.

1. Download `Dewrinkle-macOS.zip` from the [latest release](https://github.com/saufisulaiman91-arch/dewrinkle/releases/latest).
2. Double-click the zip. macOS expands it to `Dewrinkle.app`.
3. Drag `Dewrinkle.app` into Applications and open it.

The app is signed to run locally (`codesign` identity `-`). Sequoia quarantines that signature when the zip comes from the internet, so the first open is blocked until you allow it:

- System Settings → Privacy & Security → **Open Anyway**, or
- in Terminal: `xattr -dr com.apple.quarantine /Applications/Dewrinkle.app`

Then open Dewrinkle again. You only do this once per download. A pull request also uploads the same zip as an Actions artifact if you need a build before it is merged.

## What you can do

- Open TIFF, JPEG, and PNG. A 16-bit TIFF stays 16-bit on the way out. An 8-bit JPEG is promoted to 32-bit float before any filter runs, so the smoothing does not posterize it.
- Export 16-bit TIFF (LZW), JPEG, or 16-bit PNG. The ICC profile is written back (sRGB, Display P3, Adobe RGB, or whatever the file carried). EXIF, IPTC, GPS, and the TIFF dictionary are copied, and the orientation tag is set to upright because the pixels are stored upright.
- The default export matches the file you opened: JPEG in, JPEG out; TIFF in, 16-bit TIFF out; PNG in, 16-bit PNG out. Change it in the Output section. JPEG quality defaults to 92.
- Zoom, pan, hold `\` for the original, and split the view.
- Paint the effect in, or paint it back out. Size, hardness, and opacity. Option-drag restores. Undo and redo are per stroke.
- Detect a garment with Vision (person segmentation, or the foreground if nobody is in the frame), then subtract the face and smooth skin. The brush fixes the rest.
- Sliders: Strength (default 70), Fine wrinkles, Coarse wrinkles. They update a downscaled preview. Export renders the full file.
- Noise reduction, separate and off by default: Luminance, Colour, Detail, and an option to limit it to the mask.

## How the wrinkles come out

Three Gaussians of the encoded RGB (the file’s numbers, not a second color conversion):

| Band | What it holds | Z8 short side (5504 px) |
| --- | --- | --- |
| High, above the detail radius | Weave, thread, gingham | detail radius about 8 px, and this band is never edited |
| Fine | Small creases | about 66 px |
| Coarse | Broader folds | about 165 px |
| Base, below the coarse radius | Light and the drape of the garment | kept |

Strength mixes the corrected cloth onto the original. Fine and Coarse choose how much of each wrinkle band to remove. A bilateral or edge-preserving blur is not the smoother: that kind of blur keeps the crease edge, which is the thing we want to lose. The edge mask is only there to protect stitches and buttons, and it is dilated by a pixel because a one-pixel thread lights up on its shoulders, not on its center.

Radii are fractions of the short side, so the 2048 px preview and the 45 MP export agree in cycles-per-picture. Noise is the exception. Grain is a per-pixel problem, and a downscaled preview has already averaged a lot of it away. Judge luminance and colour noise on the export, or accept that the preview understates it.

On a Z8 frame the coarse radius is about 165 px. A fold wider than that, the fall of a hijab or the sweep of a skirt, stays in the base and is not flattened. Turning Coarse to 100 still will not iron the pose out of the cloth. If a particular crop needs a different reach, open Custom radii. Those numbers are full-resolution pixels.

## Noise reduction

Off until Luminance or Colour is above zero. The order is fixed: denoise, then de-wrinkle, so the high layer that gets added back is weave rather than grain.

- Luminance uses Core Image’s `CINoiseReduction` on a luma image. Detail maps to that filter’s sharpness: higher keeps edges.
- Colour is a Gaussian on a quarter-resolution chroma plane, then the original luma is put back.
- Limit to mask blends the denoised pixels back to the original outside the garment mask. Leave it off and the whole frame is denoised.

The tested reference implementation in `DewrinkleCore` is an edge-aware bilateral on Y and the same quarter-res chroma blur. The Mac path follows the same controls (`NoiseReductionParameters.resolved`) but is not pixel-identical to that reference. `CIGaussianBlur`’s radius is passed the same number as the reference sigma; confirm that against a flat field and a known sine the first time you run it on a Mac.

### A later Core ML denoiser

Assign `DenoiseSlot.shared.model` to any object that adopts `MLDenoiseModel`. When the noise panel is active, preview and export call that model on the working image **before** de-wrinkle, then apply the mask limit themselves, so the model can be a global denoiser. The model must not hop to the main thread: the render waits for it on a background queue. With no model installed, the classical path runs and the slot stays empty.

## Build and run

The downloadable app is produced by `.github/workflows/build-macos.yml` with Xcode 16.4. The workflow runs `swift test`, builds the Release app for arm64 with `CODE_SIGN_IDENTITY="-"`, zips `Dewrinkle.app` with `ditto`, and uploads the zip. It uses the macOS 15 Intel runner (`macos-15-intel`) because GitHub’s arm64 macOS pool was not assigning runners, and still emits an arm64 app. Pushes to `main` replace the `latest` GitHub Release.

To build it yourself you need an Apple Silicon Mac, macOS 14 or later, and Xcode 15 or 16.

1. Open `Dewrinkle.xcodeproj`.
2. Scheme: **Dewrinkle**. Destination: My Mac.
3. Run. Signing is already “Sign to Run Locally” (no development team).

The project is also described by `project.yml`. If you change the file list and you have [XcodeGen](https://github.com/yonaskolb/XcodeGen) installed:

```bash
xcodegen generate
```

`Scripts/generate_xcodeproj.py` rewrites the checked-in project if you would rather not install XcodeGen. The app statically links `DewrinkleCore` from `Sources/DewrinkleCore`, so the finished app is one signed executable. The same sources are a Swift package, so the core can be tested without Xcode:

```bash
swift test
```

On a Mac, Product → Test runs `DewrinkleCoreTests` against that static library.

A build-phase script, `Scripts/compile-kernel.sh`, compiles `App/Shaders/Dewrinkle.metal` into a Core Image metallib with `metal -fcikernel`. If that step does not run, the app compiles the matching kernel source in `KernelSources.swift` at launch. Keep those two in sync. The high-frequency term (`image - detail`) is added back unchanged in both.

The deployment target is macOS 14 and the architectures setting is arm64 only.

## Sign it for your own machine

The app is not sandboxed. Hardened runtime is on. That is deliberate: a sandboxed app cannot read and write a Capture One TIFF anywhere on disk unless you add the user-selected file entitlement, and Edit With wants to overwrite the file Capture One just created.

The checked-in project signs ad hoc: Signing Certificate is **Sign to Run Locally**, the team is blank, and `CODE_SIGN_IDENTITY` is `-`. That is the same signature the GitHub Release uses. If you have a free Apple ID and would rather use your Personal Team, switch the Dewrinkle target to Automatically manage signing and pick that team.

Do not turn App Sandbox on unless you also add User Selected File Read/Write. The entitlements file is intentionally empty.

The first launch of a downloaded copy needs System Settings → Privacy & Security → Open Anyway, or `xattr -dr com.apple.quarantine` on the app. A copy you just built in Xcode usually opens with a right-click → Open.

## Capture One, TIFF

This is the round trip the 16-bit path is for.

1. In Capture One, set the Edit With recipe (or a process recipe) to 16-bit TIFF, no resizing, and the color space you actually grade in. Embed the camera profile, Adobe RGB, or ProPhoto. LZW or uncompressed both open here; Dewrinkle writes LZW on the way out.
2. Right-click the variant → Edit With → Dewrinkle. Capture One writes a TIFF and opens it. You can also export the TIFF yourself and use Open.
3. Paint or detect the garment. Strength starts at 70. Fine takes the small creases; Coarse takes the broader ones and leaves the drape.
4. Save (⌘S) writes back over that TIFF when the output format is still 16-bit TIFF. That is the file Capture One is watching. Export (⌘E) writes a new file if you want to keep the intermediate.
5. Switch back to Capture One. It picks the change up when the file’s modification date moves; quitting Dewrinkle makes that reliable on older Capture One versions. The TIFF comes back as the edited variant, still 16-bit, still carrying the profile and the EXIF block.

Save asks before it overwrites. If you have switched the output format so the extension would change, Save writes a sibling (`name_dewrinkle.jpg`) instead of replacing the TIFF.

## JPEG

JPEG is a normal input, not a fallback.

- A client JPEG, or a Capture One JPEG recipe (sRGB, Display P3, or Adobe RGB), opens like a TIFF. The 8-bit codes are expanded to float immediately. The filters never run in 8-bit.
- Because the file was a JPEG, the Output section starts on JPEG at quality 92. Switch it to 16-bit TIFF if you want a master.
- Export writes a JPEG at the quality you set, with the same ICC profile the file had (or sRGB if it was untagged) and the EXIF, IPTC, and GPS dictionaries ImageIO exposed. Orientation is stored as upright.
- The canvas is still the 2048 px proxy. The JPEG you export is full resolution.

A JPEG has already thrown away a lot of tone. De-wrinkle will not invent 16-bit smoothness that was never in the file, but it will not add banding on top of the edit.

## Controls

| Action | How |
| --- | --- |
| Open | ⌘O, or drop a file on the window |
| Save over the opened file | ⌘S, confirms |
| Export a new file | ⌘E |
| Hold the original | `\` |
| Lock the original | the Before button, or ⌘\\ |
| Split | Y |
| Mask overlay | M |
| Detect garment | A, or the Auto button |
| Paint / restore | B / E, or Option-drag to restore while painting |
| Brush size | `[` and `]` |
| Fit / actual pixels | ⌘0 / ⌘1 |
| Pan | scroll, or hold Space and drag |
| Zoom | pinch, or ⌘-scroll |

Actual pixels means one image pixel per screen pixel. The percentage in the status bar is that ratio.

De-wrinkle does nothing until the mask has some paint or a detection. Noise does, unless Limit to mask is on and the mask is empty.

## Where a SAM 2 model would go

`ClickSelecting` in `SubjectMasking.swift` is the seam. `UninstalledSAM2Selector` is the placeholder: it throws, and it says why. A commercially licensed SAM 2 model compiled to Core ML adopts that protocol, takes include and exclude points in normalized top-left coordinates, and returns a `MaskBuffer`. The brush, the undo stack, and the frequency engine do not change.

Do not plug in clothing parsers trained on non-commercial data (SCHP, `mattmdjaga/segformer_b2_clothes`, CRHD-3K). The Vision path that ships is Apple’s person and foreground segmentation, which is what the auto button calls, followed by `GarmentMaskRefinement`:

- smooth skin, in YCbCr, is subtracted
- a tight weave is not, because the test is local contrast rather than a Sobel (a checker cancels a Sobel)
- face rectangles from `VNDetectFaceRectanglesRequest` are expanded slightly and feathered out

Beige abayas and hands will sometimes be wrong. That is what the brush is for.

## Layout

```
Sources/DewrinkleCore     frequency separation, blur, brush, noise, export defaults
Tests/DewrinkleCoreTests  the tests that ran on Linux
App                       SwiftUI, AppKit canvas, Core Image, Vision, ImageIO
App/Shaders/Dewrinkle.metal
project.yml               XcodeGen
Dewrinkle.xcodeproj       open this
```

`ImagePipeline` in the core is the order the app uses: denoise, then de-wrinkle. The app’s GPU graph is `CIGraph` in `App/Engine/CIPipeline.swift`.

## Tested here

The processing tests below passed on Linux with `swift test`. macOS CI runs those plus the orientation round trip:

- 8-bit and 16-bit quantize round trip, and EXIF orientation 6
- Gaussian energy and symmetry
- Bands recombine to the original when nothing is removed
- A Nyquist weave survives with Fine and Coarse at 100; a fine sine does not
- A coarse band is removed; a drape wider than the coarse radius is kept
- Strength 0 and an empty mask match the input exactly
- Z8 radii land near 8 / 66 / 165 px, and the preview scale matches
- A stitch is protected (after a one-pixel dilate) and a soft wrinkle is not
- Brush paint, restore, undo, redo
- Skin and face removal, and a textured checker kept
- Noise off is an identity; chroma oscillation drops without moving luma; high Detail keeps a step better than low Detail; Limit to mask leaves the other half alone
- The pipeline runs denoise then de-wrinkle, and the Core ML hook is skipped while noise is off
- JPEG opens default to JPEG at 0.92; TIFF opens default to 16-bit TIFF

## Not tested, because this machine cannot build a Mac app

- Launch, and every control in the window. The GitHub Actions workflow compiles the Release app and ad-hoc signs it; it does not open the window
- Core Image and the Metal kernel against the CPU reference, including whether `CIGaussianBlur`’s radius matches the reference sigma
- `CIContext.render(toBitmap:)` is probed at launch so the first bitmap row matches the top of the upright photo. The canvas is a flipped view and draws with `respectFlipped`, so the photo, the mask, and a top-left brush stroke share that corner. `OrientationTests` checks load, display, export, and EXIF orientation 6
- Memory and time on an 8256×5504 16-bit TIFF. The editor holds a 2048 px proxy; the full frame is decoded at export. Expect on the order of a gigabyte of float buffers during that export
- Vision on real hijab, abaya, bridal, and product shots. Auto mask cuts faces and hands out with Vision rectangles, landmarks, and hand pose. It does not use the skin-color score, because pink satin is read as skin
- ImageIO’s 16-bit LZW TIFF and JPEG writers against a real Capture One file: profile, EXIF, MakerNote, DPI
- JPEG quality 92 as measured by a client file, and Display P3 specifically
- Trackpad pan direction, brush cursor size, and mask alignment. If the red overlay is flipped relative to the cloth, the mask upload in `CGBridge.grayImage` is the place to flip
- The metallib build script on your Xcode
- The Core ML denoise slot and the SAM 2 protocol, beyond the “not installed” and “model was called” tests

If the first real TIFF looks right in the split view and the exported file opens in Capture One with the same profile and the weave still there, the untested GPU path is doing the job the CPU tests describe.
