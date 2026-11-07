# FilmLab

Personal iOS camera: live Fujifilm film-simulation viewfinder, untouched Bayer RAW DNG capture, and a
film-simulation HEIF/JPEG rendered from that DNG. Only the render goes to Photos; the DNG stays in the app for re-rendering. The
pipeline is Apple Log -> scene-linear -> F-Gamut/F-Log2 -> Fujifilm's official F-Log2 `.cube` LUT.
Full spec: [`AGENTS.md`](AGENTS.md). Decisions and device results: [`docs/DEVELOPMENT_LOG.md`](docs/DEVELOPMENT_LOG.md).

## Build

```sh
brew install xcodegen
cd iOS && xcodegen generate
open FilmLab.xcodeproj     # set your signing team, run on an iPhone
```

Tests (color math + Metal, simulator):

```sh
xcodebuild -project iOS/FilmLab.xcodeproj -scheme FilmLab \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

## Python reference

```sh
python3 -m venv .venv && . .venv/bin/activate && pip install numpy rawpy pillow
python research/reference/bake_applelog_to_fuji.py --selftest
python research/reference/make_fixtures.py          # regenerates research/fixtures
python research/reference/render_dng.py photo.dng --lut ClassicChrome.cube --out ref.png
```

## LUTs

Not committed. To build them into the app, follow [`docs/INSTALL_LUTS.md`](docs/INSTALL_LUTS.md), which an
agent can run start to finish. It installs Fujifilm's official F-Log2 LUTs into
`iOS/FilmLab/Resources/LUTs/` and they load on first launch. Without them, the app's first-run screen
lets you import `.cube` files from Files, and the `+` at the end of the simulation picker adds more.
