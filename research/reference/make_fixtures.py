#!/usr/bin/env python3
"""
make_fixtures.py

Writes the JSON/.cube fixtures that the Swift and Metal tests compare against.
Run from anywhere:  python research/reference/make_fixtures.py

Outputs (research/fixtures/):
  test_lut_17.cube        synthetic, non-trivial 17^3 LUT (not a Fujifilm LUT)
  curves.json             Apple Log / F-Log2 encode and decode pairs
  lut_samples.json        10,000 random inputs and apply_cube outputs
  stage_image.json        48x32 scene-linear image through the shared stage
  neutral_lut_samples.json  neutral simulation table spot checks
  preview_ycbcr.json      10-bit Y'CbCr codes -> scene-linear Rec.2020
"""

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from bake_applelog_to_fuji import (  # noqa: E402
    apply_cube,
    applelog_decode,
    applelog_encode,
    flog2_decode,
    flog2_encode,
    identity_grid,
    read_cube,
    write_cube,
)
from shared_stage import (  # noqa: E402
    applelog_ycbcr_to_linear,
    bt709_oetf,
    neutral_table,
    rec2020_to_rec709,
    shared_stage,
)

OUT = os.path.join(HERE, "..", "fixtures")
SEED = 20261105


def r(a):
    return np.round(np.asarray(a, dtype=np.float64), 9).tolist()


def synthetic_look_table(n=17):
    """A smooth but clearly non-identity look in the F-Log2 domain, so trilinear
    interpolation errors are visible: cross-channel mixing, desaturation, an
    S-curve and a warm split tone, then BT.709 OETF."""
    grid = identity_grid(n)
    lin = flog2_decode(grid)
    lin709 = lin @ rec2020_to_rec709().T
    luma = lin709 @ np.array([0.2126, 0.7152, 0.0722])
    sat = 0.75
    lin709 = luma[..., None] + sat * (lin709 - luma[..., None])
    lin709 = lin709 * np.array([1.04, 1.0, 0.93]) + 0.01 * np.sin(6.0 * grid[..., ::-1])
    lin709 = np.maximum(lin709, 0.0)
    tone = lin709 / (lin709 + 0.6) * 1.6  # simple filmic shoulder
    return np.clip(bt709_oetf(np.clip(tone, 0.0, 1.0)), 0.0, 1.0)


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(SEED)

    # 1. synthetic LUT, round-tripped through .cube text so Swift parses the same values
    lut_path = os.path.join(OUT, "test_lut_17.cube")
    write_cube(lut_path, synthetic_look_table(17), "FilmLab synthetic test LUT")
    table, dmin, dmax = read_cube(lut_path)

    # 2. curves
    lin = np.concatenate([np.geomspace(1e-4, 10.0, 200), [0.000889, 0.01, 0.18, 0.0, -0.01, -0.05]])
    al_codes = np.linspace(0.0, 1.0, 101)
    json.dump(
        {
            "linear": r(lin),
            "applelog_encode": r(applelog_encode(lin)),
            "flog2_encode": r(flog2_encode(lin)),
            "applelog_codes": r(al_codes),
            "applelog_decode": r(applelog_decode(al_codes)),
            "flog2_codes": r(al_codes),
            "flog2_decode": r(flog2_decode(al_codes)),
        },
        open(os.path.join(OUT, "curves.json"), "w"),
    )

    # 3. LUT sampling, 10,000 random inputs plus exact edges
    inputs = rng.random((10000, 3))
    inputs[:8] = np.array([[i & 1, (i >> 1) & 1, (i >> 2) & 1] for i in range(8)], dtype=float)
    json.dump(
        {"lut": "test_lut_17.cube", "inputs": r(inputs), "outputs": r(apply_cube(inputs, table, dmin, dmax))},
        open(os.path.join(OUT, "lut_samples.json"), "w"),
    )

    # 4. stage image: Apple Log-like distribution of scene-linear values (incl. negatives)
    w, h = 48, 32
    img = applelog_decode(rng.random((h, w, 3)))
    img[0, :, :] = np.linspace(-0.05, 1.0, w)[:, None]  # gray ramp row
    img[1, 0, :] = 0.18
    stage = {"lut": "test_lut_17.cube", "width": w, "height": h, "input": r(img.reshape(-1, 3))}
    for ev in (0.0, 0.7, -1.3):
        stage[f"output_ev{ev:+.1f}"] = r(shared_stage(img, table, dmin, dmax, ev).reshape(-1, 3))
    neutral = neutral_table(33)
    stage["output_neutral_ev+0.0"] = r(shared_stage(img, neutral).reshape(-1, 3))
    json.dump(stage, open(os.path.join(OUT, "stage_image.json"), "w"))

    # 5. neutral table spot checks (Swift builds the same table in code)
    idx = rng.integers(0, 33, size=(64, 3))
    json.dump(
        {"size": 33, "indices_rgb": idx.tolist(), "values": r(neutral[idx[:, 2], idx[:, 1], idx[:, 0]])},
        open(os.path.join(OUT, "neutral_lut_samples.json"), "w"),
    )

    # 6. preview Y'CbCr decode, 10-bit, both ranges
    yv = rng.integers(64, 941, size=256)
    cbv = rng.integers(64, 961, size=256)
    crv = rng.integers(64, 961, size=256)
    yf = rng.integers(0, 1024, size=256)
    cbf = rng.integers(0, 1024, size=256)
    crf = rng.integers(0, 1024, size=256)
    json.dump(
        {
            "video_range": {"y": yv.tolist(), "cb": cbv.tolist(), "cr": crv.tolist(),
                            "linear": r(applelog_ycbcr_to_linear(yv, cbv, crv, 10, False))},
            "full_range": {"y": yf.tolist(), "cb": cbf.tolist(), "cr": crf.tolist(),
                           "linear": r(applelog_ycbcr_to_linear(yf, cbf, crf, 10, True))},
        },
        open(os.path.join(OUT, "preview_ycbcr.json"), "w"),
    )
    print("Wrote fixtures to", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
