# FilmLab v2 Spec: iPhone Camera with Fujifilm Film Simulations

Version 2. Supersedes the original FilmLab spec. Written for an autonomous coding agent (Devin).

## 0. What changed from v1 and why

The original spec centered on reverse engineering Fujifilm X30 firmware. Since then the color approach has been prototyped and validated on device:

1. Fujifilm publishes official film-simulation 3D LUTs whose input is **F-Log2 / F-Gamut** and whose output is **Rec.709**.
2. Both F-Log2 and Apple Log are fully documented curves, so iPhone data can be converted into the exact input those LUTs expect.
3. A reference script (`research/reference/bake_applelog_to_fuji.py`, provided) bakes Apple Log → linear → F-Gamut → F-Log2 → Fuji LUT into one LUT. On an iPhone 17 Pro in Blackmagic Camera, this produced correct exposure and Classic Chrome character, while applying Fuji's LUT directly to Apple Log was about **1.4 stops too bright** with blown highlights.

So v2 builds the app on that pipeline. Firmware research is moved to an optional future track (Section 12).

This is a **personal-use app**. It is not going to the App Store. Real simulation names (Classic Chrome, Provia, etc.) are fine. Fujifilm LUT files are supplied by the owner and loaded at runtime; do not commit them to the repo.

## 1. v1 Goal

A native iOS camera app for iPhone 17 Pro that:

1. Shows a **live viewfinder with the selected Fujifilm film simulation** applied in real time.
2. Captures a **Bayer RAW DNG** still and keeps it untouched.
3. Renders a **film-simulation JPEG/HEIF** from that DNG using the same color engine.
4. Saves the DNG and the rendered image to Photos as one asset pair.
5. Lets the owner import Fujifilm `.cube` LUTs and switch between simulations.

Everything works offline.

## 2. The color pipeline (core of the app)

Both paths convert their input into **scene-linear Rec.2020** and then run one shared film-simulation stage.

```text
PREVIEW PATH                            STILL PATH
Apple Log 10-bit YCbCr video            Bayer RAW DNG (12MP)
  → YCbCr to R'G'B' (BT.2020 matrix,       → CIRAWFilter, linear output,
    correct range)                            no tone curve, no boost
  → Apple Log decode                       → render to linear Rec.2020, RGBA half float
  → scene-linear Rec.2020                  → scene-linear Rec.2020
            \                               /
             ▼                             ▼
         SHARED FILM SIMULATION STAGE (Metal)
           1. exposure (user EV + per-path anchor), in linear
           2. Rec.2020 → F-Gamut (identity matrix, same primaries; keep the step explicit)
           3. clip negatives, F-Log2 encode, clamp 0..1
           4. sample Fujifilm 3D LUT (trilinear)
           5. output is Rec.709 display-referred
                      │
            ┌─────────┴─────────┐
            ▼                   ▼
        MTKView preview     8-bit JPEG/HEIF export
```

### 2.1 Apple Log decode (Apple Log Profile white paper)

```text
R0 = -0.05641088   Rt = 0.01
c  = 47.28711236   β  = 0.00964052
γ  = 0.08550479    δ  = 0.69336945
Pt = c * (Rt - R0)^2

decode(P):
  P >= Pt : R = 2^((P - δ) / γ) - β
  P <  Pt : R = sqrt(max(P,0) / c) + R0
```

### 2.2 F-Log2 encode (Fujifilm F-Log2 Data Sheet)

```text
a = 5.555556   b = 0.064829   c = 0.245281
d = 0.384316   e = 8.799461   f = 0.092864
cut1 = 0.000889

encode(x):
  x >= cut1 : y = c * log10(a*x + b) + d
  x <  cut1 : y = e*x + f
```

### 2.3 Test vectors (must pass in Swift and Metal)

| Input (scene linear) | Apple Log code | F-Log2 code |
|---|---|---|
| 0.18 (18% gray) | 0.488 ± 0.002 | 0.391 ± 0.002 |
| 0.000889 | n/a | 0.100686 ± 1e-5 |

Round trips (encode then decode) must match within 1e-6 relative error over 1e-4..10.

### 2.4 LUT sampling

- Parse `.cube`: `LUT_3D_SIZE`, optional `DOMAIN_MIN`/`DOMAIN_MAX`, `TITLE`, comments. Red varies fastest.
- Upload as an `MTLTexture` of type `.type3D`, `rgba16Float` or `rgba32Float`.
- Sample with a linear-filter, clamp-to-edge sampler. Map input value v in 0..1 to texture coordinate `(v * (N - 1) + 0.5) / N` per channel so grid points align with texel centers.
- Must match the Python reference `apply_cube` within 1e-3 on 10,000 random inputs (test against values exported from Python as a fixture).

### 2.5 Ground truth

`research/reference/bake_applelog_to_fuji.py` is the reference implementation for the curves, gamut step, LUT parsing and trilinear interpolation. When Swift/Metal and Python disagree, Python wins until proven wrong. Add a second reference script, `research/reference/render_dng.py`, that renders a DNG through the same pipeline using `rawpy` (linear XYZ output, gamma (1,1), no auto-bright, camera WB) then XYZ → linear Rec.2020 → shared stage. Use it to produce golden images for the still path.

## 3. Preview path details

1. Use a **physical** camera device, starting with `.builtInWideAngleCamera` (back). Not a virtual multi-camera device.
2. Find a format whose `supportedColorSpaces` contains `.appleLog`. Set `session.automaticallyConfiguresCaptureDeviceWideColor = false`, then `device.activeColorSpace = .appleLog`.
3. `AVCaptureVideoDataOutput` with a 10-bit 4:2:0 biplanar pixel format. Check whether the delivered buffers are **video range or full range** (pixel format type tells you) and handle both. Convert YCbCr to R'G'B' using the **BT.2020 non-constant-luminance** matrix.
4. Process each frame in a Metal compute or fragment shader via `CVMetalTextureCache`. No CPU pixel work.
5. Target 30 fps or better at preview resolution. Measure and log.

### 3.1 Critical unknown, verify first

It is **not yet confirmed** that one session/format can provide Apple Log video frames **and** Bayer RAW photo capture at the same time. This is the first thing to test on device (Milestone 1).

- If supported: use the Apple Log format for both.
- If not: keep Bayer RAW stills as the priority. Use the best available non-log video format for preview, decode it approximately to linear (treat as the format's tagged transfer function and primaries), apply the same shared stage, and show a small "Preview approx." label in the UI. Optionally switch to Apple Log format only while previewing and reconfigure for capture, if the switch is fast enough (measure it).

Record the outcome in `docs/DEVELOPMENT_LOG.md`.

## 4. Still path details

1. `AVCapturePhotoOutput`. Pick a Bayer format from `availableRawPhotoPixelFormatTypes` using `AVCapturePhotoOutput.isBayerRAWPixelFormat(_:)`. Never silently fall back to ProRAW.
2. Expect **12MP** Bayer RAW. 48MP Bayer RAW is not available to third-party apps; 48MP is only available as ProRAW. ProRAW is out of scope for v1.
3. Lock in the capture settings shown at shutter time: exposure, ISO, white balance values. Store them.
4. Save the DNG bytes from `fileDataRepresentation()` unmodified.
5. Render: `CIRAWFilter(imageData:)`. Disable everything that shapes the image: `boostAmount = 0` (linear response), no local tone mapping, no extended dynamic range boost, sharpening and noise reduction at their minimum or a fixed documented value. Apply `baselineExposure` from the DNG. Render with a `CIContext` whose working and output color space is **extended linear Rec.2020**, into an `rgba16Float` texture. Verify on device that the result is actually linear: an 18% gray card should land near 0.18 after the exposure anchor.
6. Run the shared stage at full resolution. Tile if memory requires it.
7. Export the Rec.709 result as HEIF (default) or JPEG, tagged with the matching color profile. Keep EXIF from the DNG and add simulation name, LUT file name, EV and app version.
8. Save to Photos with `PHAssetCreationRequest`: rendered image as `.photo`, DNG as `.alternatePhoto`, so Photos treats them as a RAW+processed pair.

### 4.1 Exposure anchor

The still and preview paths may disagree on brightness for the same scene. Provide a per-path EV offset constant (`previewAnchorEV`, `stillAnchorEV`), default 0, and a debug screen to tune them by pointing at a gray card. Both paths must be within 1/3 stop of each other on a gray card after tuning.

## 5. Film simulations

- No simulations ship in the repo. On first launch, show an "Import LUTs" screen that opens the Files picker for one or more `.cube` files.
- Copy imported LUTs into the app's Application Support folder. Parse once, cache as 3D textures.
- Display name: derive from the file name, with a simple map for known Fujifilm names (Provia, Velvia, Astia, Classic Chrome, PRO Neg. Std, Classic Neg., Eterna, Eterna Bleach Bypass, Reala Ace, Acros). The owner can rename.
- Store per-simulation metadata in JSON: id, display name, LUT file, expected input (F-Log2 / F-Gamut), output (Rec.709), date imported.
- Also offer a built-in **"Neutral"** simulation: F-Log2 encode then a plain Rec.709 output transform (no Fuji LUT), for A/B comparison.

## 6. UI (v1)

Dark, camera-first, minimal.

- Full-screen viewfinder.
- Bottom: shutter button (large, haptic), last-capture thumbnail (opens a simple review screen), lens picker (only physical lenses that support Bayer RAW).
- Above shutter: horizontal simulation picker with haptic ticks; changes preview instantly.
- Exposure compensation: vertical drag on viewfinder or a slider, applied in the shared stage (linear), range ±2 EV.
- Tap to focus/expose.
- Small status chip: `RAW 12MP` and `Preview: Apple Log` or `Preview approx.`.
- Review screen: show rendered image, switch simulation and re-render from the saved DNG, save.

Out of v1: highlight/shadow/color recipe controls, grain, clarity, histogram, gallery beyond last capture, video recording.

## 7. Architecture

Swift, SwiftUI, AVFoundation, Metal, Core Image (RAW decode only), Photos. Swift structured concurrency. No third-party image-processing SDKs. Keep modules separate so the shared stage is testable without a camera.

```text
FilmLab/
├── AGENTS.md                 (copy of this spec's rules, Section 11)
├── docs/DEVELOPMENT_LOG.md
├── iOS/FilmLab.xcodeproj
├── iOS/FilmLab/
│   ├── App/
│   ├── CameraCore/           session, device/format discovery, Apple Log setup, photo capture
│   ├── ColorScience/         Apple Log, F-Log2, gamut step, .cube parser (pure Swift, unit tested)
│   ├── FilmEngine/           shared stage, Metal shaders, LUT texture cache
│   ├── RAWDevelopment/       CIRAWFilter setup, linear render, tiling
│   ├── PhotoLibrary/         DNG + rendered pair saving, EXIF
│   └── UI/
├── iOS/FilmLabTests/         curve tests, LUT tests vs Python fixtures, golden image tests
├── research/reference/       bake_applelog_to_fuji.py, render_dng.py, fixture generators
└── research/fixtures/        test vectors, small sample DNGs (owner-provided, may be gitignored)
```

Minimum iOS: 18 unless an API requires 26; document the choice.

Useful open-source references (study, check licenses before copying code): RawCam (`github.com/madebysan/rawcam`, MIT, minimal Bayer DNG capture), ManualCameraApp (`github.com/frecklysledge0/ManualCameraApp`, live LUT preview pipeline and RAW development with a LUT), Prism (`Luminoid/Prism`, actor-isolated camera package), CamProc (`adwirth/CamProc`, Metal Bayer processing).

## 8. Milestones

### M1: Capture foundations
- Project scaffold, permissions, session on the back wide camera.
- Enumerate and log: formats with `.appleLog`, Bayer RAW pixel formats, and whether both work together (Section 3.1).
- Plain preview (no simulation).
- Capture Bayer RAW DNG, save to Photos and app storage.
- **Acceptance:** on a real iPhone 17 Pro, capture a DNG that opens in Lightroom or Preview as a 12MP raw; the dev log records the Apple Log + RAW compatibility result.

### M2: Color engine
- `ColorScience` module with curves, gamut step, `.cube` parser. Unit tests pass the Section 2.3 vectors and match Python fixtures.
- Metal shared stage with 3D LUT sampling, matching Python within 1e-3.
- LUT import flow.
- **Acceptance:** all tests pass in Xcode; a fixture image run through the Metal stage matches the Python output within 1e-3 mean absolute error.

### M3: Live film-sim preview
- Apple Log (or fallback) preview through the shared stage at 30+ fps.
- Simulation picker, EV control.
- **Acceptance:** on device, Classic Chrome preview matches the Blackmagic Camera + baked LUT reference visually (owner check), and fps is logged.

### M4: Film-sim stills
- CIRAWFilter linear render, shared stage at full res, HEIF/JPEG export, paired save to Photos.
- Review screen with re-render in another simulation.
- Gray-card anchor tuning screen.
- **Acceptance:** owner shoots a scene, gets a DNG plus a Classic Chrome HEIF in Photos; re-rendering as Velvia works without recapture; the HEIF matches `render_dng.py` output for the same DNG within a documented tolerance.

## 9. Testing

- Unit: curves, round trips, `.cube` parsing (including DOMAIN lines and comments), trilinear sampling edges.
- Fixture parity: Python generates `research/fixtures/*.json` of input/output pairs; Swift and Metal tests load them.
- Golden image: one small DNG fixture rendered by `render_dng.py` vs the app's still path.
- Device: capture, preview fps, memory peak during full-res render, background/foreground, permission denial, Photos save failure.
- Never claim device behavior was tested on the simulator. Camera features need a real iPhone.

## 10. Out of scope for v1

Video recording with the look baked in, ProRAW and 48MP, recipe controls (highlight/shadow/color/grain/clarity), per-lens color calibration, multi-frame burst merge, firmware research, cloud, accounts.

## 11. Rules for the agent

1. Build in milestone order. Each milestone compiles and its tests pass before moving on.
2. The Python reference is the source of truth for color math.
3. Do not invent API behavior. When unsure whether an AVFoundation or Core Image setting does what is assumed, write a device check and log the result.
4. Do not claim the app builds or works on device unless it was actually verified. If no Xcode or device is available, finish the code and automated checks, then give the owner exact steps to verify.
5. Never replace Bayer RAW with ProRAW or processed input without an explicit labeled mode.
6. Keep the original DNG bytes unmodified.
7. Do not commit Fujifilm LUT files or owner photos unless told to.
8. Log decisions, failed attempts and open questions in `docs/DEVELOPMENT_LOG.md`.
9. At the end of each milestone, report what was verified, what needs device testing, and the next step.

## 12. Future tracks (after v1)

- **Per-lens calibration:** shoot a ColorChecker per lens under daylight and tungsten, fit a 3x3 matrix plus small correction LUT from camera RGB to XYZ, apply before the shared stage.
- **Stills vs video LUT correction:** if a Fujifilm body is available, shoot matched scenes and fit a small correction so stills match Fuji JPEGs rather than Fuji video LUT output.
- **Recipe controls:** highlight tone, shadow tone, color, DR modes, grain, implemented in linear or F-Log2 space before the LUT.
- **Burst merge:** capture several Bayer frames and merge for low light, keeping data unprocessed.
- **Video recording** with the look baked in, using the same Apple Log path.
- **X30 firmware research:** optional, as in the original spec, for an X30-era Classic Chrome variant.