#!/usr/bin/env python3
"""
shared_stage.py

Reference implementation of the FilmLab shared film-simulation stage (spec v2,
Section 2) plus the preview-path input decode. Curves, gamut math, .cube I/O and
trilinear interpolation are imported from bake_applelog_to_fuji.py, which stays
the ground truth for color math.

    scene-linear Rec.2020
      -> exposure (linear gain, 2^EV)
      -> Rec.2020 -> F-Gamut (identity, kept explicit)
      -> clip negatives, F-Log2 encode, clamp 0..1
      -> 3D LUT (trilinear)
      -> Rec.709 display-referred, clamped 0..1
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from bake_applelog_to_fuji import (  # noqa: E402
    D65,
    FGAMUT_PRIMARIES,
    REC2020_PRIMARIES,
    apply_cube,
    applelog_decode,
    flog2_decode,
    flog2_encode,
    gamut_matrix,
    identity_grid,
    rgb_to_xyz_matrix,
)

# Spec step 3 clips negatives before the F-Log2 encode. The bake script does not
# (it relies on the final clamp). Keep this in sync with
# FilmEngine/Shaders.metal and ColorScience/SharedStageReference.swift.
CLIP_NEGATIVES_BEFORE_ENCODE = True

REC709_PRIMARIES = ((0.640, 0.330), (0.300, 0.600), (0.150, 0.060))


def rec2020_to_fgamut():
    return gamut_matrix(REC2020_PRIMARIES, FGAMUT_PRIMARIES)


def rec2020_to_rec709():
    return gamut_matrix(REC2020_PRIMARIES, REC709_PRIMARIES)


def rec709_to_rec2020():
    return gamut_matrix(REC709_PRIMARIES, REC2020_PRIMARIES)


def xyz_to_rec2020():
    return np.linalg.inv(rgb_to_xyz_matrix(REC2020_PRIMARIES, D65))


def bt709_oetf(l):
    l = np.clip(np.asarray(l, dtype=np.float64), 0.0, None)
    return np.where(l < 0.018, 4.5 * l, 1.099 * np.power(l, 0.45) - 0.099)


def bt709_inverse_oetf(v):
    v = np.clip(np.asarray(v, dtype=np.float64), 0.0, None)
    return np.where(v < 0.081, v / 4.5, np.power((v + 0.099) / 1.099, 1.0 / 0.45))


def to_flog2(lin_rec2020, exposure_stops=0.0):
    lin = np.asarray(lin_rec2020, dtype=np.float64) * (2.0 ** exposure_stops)
    lin = lin @ rec2020_to_fgamut().T
    if CLIP_NEGATIVES_BEFORE_ENCODE:
        lin = np.maximum(lin, 0.0)
    return np.clip(flog2_encode(lin), 0.0, 1.0)


def shared_stage(lin_rec2020, table, dmin=np.zeros(3), dmax=np.ones(3), exposure_stops=0.0):
    flog = to_flog2(lin_rec2020, exposure_stops)
    return np.clip(apply_cube(flog, table, dmin, dmax), 0.0, 1.0)


def neutral_table(n=33):
    """Built-in "Neutral" simulation as a LUT in the F-Log2 domain:
    F-Log2 -> linear F-Gamut (= Rec.2020) -> Rec.709 primaries -> clip -> BT.709 OETF."""
    grid = identity_grid(n)
    lin = flog2_decode(grid) @ np.linalg.inv(rec2020_to_fgamut()).T
    lin709 = np.clip(lin @ rec2020_to_rec709().T, 0.0, 1.0)
    return bt709_oetf(lin709)


# --------------------------------------------------------------------------
# Preview path: Y'CbCr (BT.2020 non-constant luminance) -> R'G'B' -> linear
# --------------------------------------------------------------------------
BT2020_KR, BT2020_KB = 0.2627, 0.0593


def ycbcr_to_rgb(y_code, cb_code, cr_code, bits=10, full_range=False, kr=BT2020_KR, kb=BT2020_KB):
    y_code = np.asarray(y_code, dtype=np.float64)
    cb_code = np.asarray(cb_code, dtype=np.float64)
    cr_code = np.asarray(cr_code, dtype=np.float64)
    scale = 2 ** (bits - 8)
    mid = 2 ** (bits - 1)
    if full_range:
        y = y_code / (2 ** bits - 1)
        cb = (cb_code - mid) / (2 ** bits - 1)
        cr = (cr_code - mid) / (2 ** bits - 1)
    else:
        y = (y_code - 16 * scale) / (219 * scale)
        cb = (cb_code - mid) / (224 * scale)
        cr = (cr_code - mid) / (224 * scale)
    kg = 1.0 - kr - kb
    r = y + 2.0 * (1.0 - kr) * cr
    b = y + 2.0 * (1.0 - kb) * cb
    g = (y - kr * r - kb * b) / kg
    return np.stack([r, g, b], axis=-1)


def applelog_ycbcr_to_linear(y_code, cb_code, cr_code, bits=10, full_range=False):
    return applelog_decode(ycbcr_to_rgb(y_code, cb_code, cr_code, bits, full_range))
