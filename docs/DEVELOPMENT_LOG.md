# FilmLab development log

Newest entries at the top. "Verified" means actually run; anything camera-related is **not verified**
until it has been run on a real iPhone and the result is written here.

## 2026-11-05: Initial implementation (M1-M4 code), simulator/host verification only

### Environment
- macOS host, Xcode 26.6 (17F113), iPhone 17 Pro **simulator**, XcodeGen 2.46.0.
- Python 3.12, NumPy 2.x, rawpy 0.28, Pillow.
- No physical iPhone was available. Nothing in the camera, RAW, Photos or preview-FPS paths has been
  run on device.

### Verified (automated)
- `bake_applelog_to_fuji.py --selftest`: Apple Log gray 0.488, F-Log2 gray 0.391, naive Fuji LUT
  exposure error +1.37 stops, Rec.2020 -> F-Gamut matrix is identity.
- `make_fixtures.py` regenerates `research/fixtures/` deterministically (seed 20261105).
- Xcode unit tests on the simulator (`FilmLabTests`), all passing:
  - Section 2.3 vectors in Swift and in Metal (Apple Log 0.488, F-Log2 0.391, F-Log2(0.000889) =
    0.100686), round trips, Python curve parity.
  - `.cube` parsing: comments, `TITLE`, `DOMAIN_MIN/MAX`, `LUT_3D_INPUT_RANGE`, CRLF, 1D rejection,
    wrong entry count, edge/clamp sampling.
  - Metal LUT sampling vs Python `apply_cube` on 10,000 random inputs: max abs error ~7e-7.
  - Fixture image through the Metal shared stage vs Python: MAE ~2e-8 (spec limit 1e-3), for EV 0,
    +0.7, -1.3 and the Neutral simulation.
  - Preview YCbCr decode (10-bit video range and full range) vs Python: max rel. error ~1.5e-6.
  - JPEG export tagged ITU-R 709 with simulation/LUT/EV/app version in TIFF/EXIF; HEIF encode;
    capture store keeps DNG bytes byte-identical.
- App target builds for the simulator with no warnings in FilmLab sources.

### Decisions
- **Manual trilinear interpolation in Metal instead of the hardware linear sampler (deviation from
  spec 2.4).** With the spec's sampler approach (`(v*(N-1)+0.5)/N`, linear filter, clamp-to-edge) the
  10,000-sample test measured max error 2.7e-3 on the simulator (the simulator GPU used rgba16Float
  because fp32 filtering is unsupported; hardware filter weights are also low precision). That fails
  the 1e-3 requirement. The shader now reads the 8 neighbouring texels from an rgba32Float 3D texture
  and interpolates in fp32, which is exactly Python's `apply_cube` (max error 7e-7). Cost: 8 reads per
  pixel instead of 1 filtered fetch; check preview FPS on device. If FPS is short, an option is the
  hardware path with rgba32Float where `supports32BitFloatFiltering` is true, re-measured on device.
- Gamut step Rec.2020 -> F-Gamut is computed from primaries at runtime and kept as an explicit
  multiply even though it is identity, so a future F-Gamut correction is a data change.
- Negative linear values are clipped to 0 before F-Log2 encoding, matching the Python reference.
- Out-of-range LUT inputs are clamped to the domain (same as Python).
- Still path: `CIRAWFilter` with `boostAmount = 0`, `boostShadowAmount = 0`, local tone map 0, EDR 0,
  sharpness/detail/contrast 0, luminance/color NR 0, moire 0, gamut mapping off, exposure 0;
  `baselineExposure` left at the value CIRAWFilter reads from the DNG. Rendered into an rgba16Float
  texture with `extendedLinearITUR_2020` as the destination color space. The full set of applied
  values is logged per render.
- Full-resolution stage runs untiled: 12MP rgba16Float (~96 MB) + rgba8 output (~48 MB). Tiling to be
  added only if device memory measurements require it.
- Output: 8-bit Rec.709 (BT.709 OETF, as Fuji's LUT outputs), tagged with the ITU-R 709 color space.
  HEIF by default, JPEG selectable in Debug; if HEIF encoding fails the app falls back to JPEG and logs it.
- Photos: one `PHAssetCreationRequest` with the rendered image as `.photo` and the original DNG bytes
  as `.alternatePhoto`. "Add only" Photos permission.
- App storage: `Application Support/Captures/<uuid>/original.dng` (bytes from
  `fileDataRepresentation()`, unmodified), `info.json` (locked exposure/ISO/WB/lens values, RAW format,
  baseline exposure, last render metadata) and the latest render. Review re-renders from this DNG.
- Exposure anchor: `previewAnchorEV` and `stillAnchorEV` (UserDefaults, default 0), tuned in the Debug
  screen. The preview meter and the still path both report mean scene-linear Rec.2020 of the centre
  32x32 patch before EV/anchor; Debug shows the anchor that would put each at 0.18.
- Camera session (spec 3.1): for each format whose `supportedColorSpaces` contains `.appleLog`
  (largest photo size first, then ~1080p video), set the format and `activeColorSpace = .appleLog`,
  commit, then check `availableRawPhotoPixelFormatTypes` for a Bayer type. If one is found, both run
  from that format. Otherwise use the `.photo` preset with sRGB, keep Bayer RAW, and decode the
  preview approximately as BT.709 ("Preview approx." chip). Every attempt is logged. ProRAW is
  explicitly disabled and never used.
- RAW size: largest `supportedMaxPhotoDimensions` at or below ~12.6 MP.
- Lens picker: physical back lenses only; a lens is hidden once a configuration attempt finds no
  Bayer RAW for it (remembered in UserDefaults).

### Open questions / needs device testing
Each item: run on an iPhone 17 Pro, read the in-app log (Debug -> Share log), record the result here.

1. **Apple Log + Bayer RAW in one format (spec 3.1).** Launch; the log prints either
   `Apple Log + Bayer RAW OK: ...` or a list of `Apple Log format without Bayer RAW` followed by
   `Fallback preset .photo`. Status chip shows `Preview: Apple Log` or `Preview approx.`.
2. **DNG validity (M1 acceptance).** Capture; AirDrop the DNG from Photos and open in Lightroom or
   Preview. Expect a 12 MP Bayer raw. Log line `Captured Bayer DNG WxH (fmt)` gives size/format.
3. **Preview FPS (M3).** Debug -> Camera shows FPS and GPU ms; also logged every ~5 s. Target 30+.
4. **Preview buffer range.** Debug shows the video pixel format (`x420` video range vs `xf20` full
   range, or 8-bit `420v`/`420f` in fallback). Decode handles all four; confirm which is delivered.
5. **CIRAWFilter linearity (4.5).** Fill frame with an 18% gray card, Debug -> Meter, capture, open
   Debug: "Last still linear" should be near 0.18 after the still anchor. Record the raw value and the
   chosen anchors. Also confirm `boostAmount = 0` gives a linear response (compare a 2-stop exposure
   bracket: linear values should differ by ~4x).
6. **Orientation.** The photo connection uses `videoRotationAngle = 90`; confirm the rendered HEIF is
   upright and matches the DNG's orientation in Lightroom.
7. **Anchor agreement (4.1).** After tuning, preview and still within 1/3 stop on a gray card.
8. **Photos pairing.** Answered: see "Photos showed the RAW" below. The pair is no longer used.
9. **Golden image (M4).** Render the same DNG with `research/reference/render_dng.py --lut ...` and
   compare with the app's `rendered.heic` (copy from the app container or Photos). Tolerance TBD;
   rawpy's AHD demosaic and Apple's demosaic will differ in detail, so compare a blurred/downsampled
   mean error. No DNG fixture is committed (owner photos are not committed per spec rule 7).
10. Memory peak during full-res render, background/foreground, permission denial, Photos denial.
11. Lens switch reconfigure time (logged as `Configured ... ms`).
12. Tap-to-focus coordinate mapping through aspect-fill + rotation.

### Not done / known gaps
- No golden-DNG automated test (needs an owner DNG, kept out of the repo).
- No live-switching between an Apple Log preview format and a RAW capture format if they cannot
  coexist (spec 3.1 "optionally"); decide after item 1.

### Built-in LUTs (owner decision, 2026-11-05)
The owner did not want a manual import step. `.cube` files placed in `iOS/FilmLab/Resources/LUTs/` are
copied into the app bundle and installed on first launch (`installBundledLUTsIfNeeded`), with Classic
Chrome selected. They stay gitignored (spec rule 7), so a fresh clone has none and shows the import
screen as before. `FLog2-709` and `WDR-709` are left out because they are not film simulations.

### First device run: launch crash (iPhone 17 Pro, iOS 27, 2026-11-05)
The session aborted in `commitConfiguration` with "ProRes Raw format only supports rotation angle of 0."
ProRes RAW formats list Apple Log in `supportedColorSpaces`, and the photo-size sort picked one.
`appleLogFormats` now keeps only formats whose native subtype `PreviewRenderer` can decode.
Item 1 under "Open questions" (Apple Log + Bayer RAW together) still needs reading from the status chip.

### Photos save: PHPhotosErrorDomain 3300 (iPhone 17 Pro, iOS 27, 2026-11-05)
`addResource(with:data:options:)` for the HEIC + DNG pair failed with `changeNotSupported` (3300). An
on-device test of the same request using `addResource(with:fileURL:options:)` succeeded, so
`savePair` now writes temporary copies and passes file URLs.

### Photos showed the RAW instead of the render (iPhone 17 Pro, iOS 27, 2026-11-06)
With a `.photo` HEIC + `.alternatePhoto` DNG pair, the owner saw the unfiltered RAW in Photos, even though
`rendered.heic` in the app's capture folder had the simulation applied. **Decision, differing from spec 4.8:**
save the HEIC and the DNG as two separate assets in one change block, so the filtered photo is what appears
(later replaced: see "Photos gets the render only" below). The cost is two items per shot in the library. DNG bytes are still unmodified. Pairing could come back if a way
is found to make Photos display the HEIC half; that was not investigated.

### Viewfinder vs saved photo (iPhone 17 Pro, iOS 27, 2026-11-06)
Measured with paired viewfinder frames and stills, phone propped still.
- **Spec 3.1 answered: no.** Apple Log formats (native `x422`, plus ProRes RAW `btp2`) offer no Bayer RAW with the
  session running, so the preview uses the fallback ("Preview approx."). The negative result is remembered per
  lens and iOS version, because testing takes about 2.3 s. Switching to Apple Log only for preview and
  reconfiguring at the shutter was not tried; it would add shutter lag.
- **Framing:** the old full-screen aspect fill showed 61% of the saved width. The viewfinder is now 3:4. Edge
  correlation with the still is 0.82 at full frame and 0.21 with a 5% crop.
- **Tone:** the preview decodes Apple's already tone-mapped video, so it has lifted shadows compared with the DNG.
  Turning video HDR off on the active lens barely changed it.
- **Decision:** `stillAnchorEV` defaults to +1.5. In Classic Chrome on one window-lit interior, the 5/25/50/75/95
  luma percentiles went from 0.02/0.08/0.31/0.56/0.88 to 0.08/0.25/0.61/0.80/0.94 against the viewfinder's
  0.10/0.25/0.58/0.73/0.84, and mean abs error from 0.166 to 0.055. This is a match to the viewfinder from a small
  number of scenes, not the gray-card tuning in spec 4.1. A tighter framing of the same room still fell short at
  +1.5 (median 0.43 vs 0.53). Stills now sit further from `render_dng.py`.
- **Raised to +2.0 (2026-11-06):** the owner still found +1.5 too dark. Three later shots at +1.5 had median luma
  about 0.39, 25th percentile about 0.11 and no clipped pixels. +2.0 is a judgment call and hasn't been measured.
- `baselineExposure` in the DNG is applied by `CIRAWFilter` (setting it to 0 halves the output at 1.01) and varied
  from 0.0 to 2.0 across scenes. Whether it drives shot-to-shot mismatch is not settled.
- **Digital zoom:** a center crop of the preview and the rendered photo, up to 4x. The DNG stays full frame.

### Open: stills are brighter than the Python reference (2026-11-06)
On three owner shots, `rendered.heic` is clearly brighter than `render_dng.py` with lifted shadows (mean abs
error 0.11-0.17, far from any useful tolerance). `render_dng.py` does not apply everything Apple's RAW decoder
does, so which is right is unresolved. Also unchecked: whether stills match the live preview (spec 4.1).

### Photos gets the render only (owner decision, 2026-11-06)
Only the HEIC/JPEG goes to Photos. This differs from spec 4.8. The DNG stays unmodified in the app's capture folder
for Review re-renders, about 10 MB per shot, and nothing prunes it yet.

### Flash (iPhone 17 Pro, iOS 27, 2026-11-06)
Top-bar control cycling auto, on and off, defaulting to auto and remembered. The button hides if the lens has no
flash. Tested on device with Bayer RAW: `on` fired, `off` did not, and `auto` did not fire in a bright scene. `auto`
firing in the dark is untested. The flash DNG had `baselineExposure` 0 (0.77 without flash). At the +2.0 anchor it
did not blow out in a bright backlit scene (8.8% of pixels clipped, against 12.7% without flash). A close subject
in a dark room is untested and may need a lower anchor for flash shots.
