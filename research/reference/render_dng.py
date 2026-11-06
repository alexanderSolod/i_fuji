#!/usr/bin/env python3
"""
render_dng.py

Golden-image reference for the FilmLab still path. Renders a Bayer DNG through
the same shared stage the app uses:

    DNG --rawpy--> linear XYZ (gamma 1,1; no auto-bright; camera WB)
        -> linear Rec.2020 -> exposure -> F-Log2 -> 3D LUT -> Rec.709

Usage
-----
    python render_dng.py photo.dng --lut Fuji_FLog2_ClassicChrome.cube
    python render_dng.py photo.dng --neutral --ev 0.3 --out golden.png
    python render_dng.py photo.dng --lut x.cube --baseline-exposure 0.5 --npy

Dependencies: numpy, rawpy, Pillow  (pip install numpy rawpy pillow)

Notes
-----
* rawpy/LibRaw does not apply the DNG BaselineExposure tag. Pass the value the
  app logged for the capture (CIRAWFilter.baselineExposure) with
  --baseline-exposure so the two renders are comparable. This is added to --ev.
* LibRaw's XYZ output is D65-referred, which matches Rec.2020's white.
* The app's demosaic (CIRAWFilter) differs from LibRaw's (AHD here), so expect
  small per-pixel differences at edges. Compare mean absolute error on a
  downscaled image, not per-pixel maxima.
"""

import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from bake_applelog_to_fuji import read_cube  # noqa: E402
from shared_stage import neutral_table, shared_stage, xyz_to_rec2020  # noqa: E402


def dng_to_linear_rec2020(path, half_size=False):
    import rawpy

    with rawpy.imread(path) as raw:
        xyz = raw.postprocess(
            output_color=rawpy.ColorSpace.XYZ,
            gamma=(1, 1),
            no_auto_bright=True,
            use_camera_wb=True,
            output_bps=16,
            half_size=half_size,
            demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,
        )
    xyz = xyz.astype(np.float64) / 65535.0
    return xyz @ xyz_to_rec2020().T


def main():
    ap = argparse.ArgumentParser(description="Render a DNG through the FilmLab shared stage.")
    ap.add_argument("dng")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--lut", help="Fujifilm F-Log2 film-simulation .cube")
    g.add_argument("--neutral", action="store_true", help="use the built-in Neutral simulation")
    ap.add_argument("--ev", type=float, default=0.0, help="exposure in stops (user EV + stillAnchorEV)")
    ap.add_argument("--baseline-exposure", type=float, default=0.0,
                    help="DNG BaselineExposure in stops, as logged by the app")
    ap.add_argument("--half-size", action="store_true", help="faster, half-resolution demosaic")
    ap.add_argument("--out", help="output PNG (default: <dng>_<sim>.png)")
    ap.add_argument("--npy", action="store_true", help="also write float32 .npy of the Rec.709 result")
    a = ap.parse_args()

    if a.neutral:
        table, dmin, dmax = neutral_table(33), np.zeros(3), np.ones(3)
        sim = "Neutral"
    else:
        table, dmin, dmax = read_cube(a.lut)
        sim = os.path.splitext(os.path.basename(a.lut))[0]

    lin = dng_to_linear_rec2020(a.dng, a.half_size)
    h, w, _ = lin.shape
    cy, cx = h // 2, w // 2
    patch = lin[cy - 16:cy + 16, cx - 16:cx + 16].mean(axis=(0, 1))
    print(f"Linear Rec.2020 center patch (before EV): {patch.round(4)}")

    out = shared_stage(lin, table, dmin, dmax, a.ev + a.baseline_exposure).astype(np.float32)

    from PIL import Image

    out_path = a.out or f"{os.path.splitext(a.dng)[0]}_{sim}.png"
    Image.fromarray(np.round(out * 255.0).astype(np.uint8), "RGB").save(out_path)
    print(f"Wrote {out_path} ({w}x{h})")
    if a.npy:
        np.save(os.path.splitext(out_path)[0] + ".npy", out)


if __name__ == "__main__":
    sys.exit(main())
