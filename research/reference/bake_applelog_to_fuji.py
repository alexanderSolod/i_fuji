#!/usr/bin/env python3
"""
bake_applelog_to_fuji.py

Builds a 3D LUT that lets you use a Fujifilm F-Log2 film-simulation LUT
correctly on iPhone Apple Log footage:

    Apple Log  ->  scene linear  ->  (Rec.2020 -> F-Gamut)  ->  F-Log2
               ->  Fujifilm film-sim LUT  ->  Rec.709 output

It also writes a "naive" LUT: the Fuji LUT resampled to the same grid size,
applied straight to Apple Log with no conversion. That is what most people do,
and it is your A/B comparison.

Usage
-----
    python bake_applelog_to_fuji.py path/to/Fuji_FLog2_ClassicChrome.cube
    python bake_applelog_to_fuji.py fuji.cube --size 33 --exposure 0 --out-dir out
    python bake_applelog_to_fuji.py --selftest

Only dependency: numpy  (pip install numpy)

Sources for the math
--------------------
Apple Log:  Apple "Apple Log Profile" white paper (encoding constants below).
F-Log2:     Fujifilm "F-Log2 Data Sheet" (encoding constants below).
Gamuts:     Apple Log uses Rec.2020 primaries; F-Gamut is specified with the
            same primaries as Rec.2020, D65 white. So the gamut step should be
            identity. It is computed from primaries anyway so you can edit them
            if a data sheet says otherwise.
"""

import argparse
import os
import sys

import numpy as np

# --------------------------------------------------------------------------
# Apple Log (Apple Log Profile white paper)
# --------------------------------------------------------------------------
AL_R0 = -0.05641088
AL_RT = 0.01
AL_C = 47.28711236
AL_BETA = 0.00964052
AL_GAMMA = 0.08550479
AL_DELTA = 0.69336945
AL_PT = AL_C * (AL_RT - AL_R0) ** 2  # encoded value at the curve's breakpoint


def applelog_encode(r):
    r = np.asarray(r, dtype=np.float64)
    low = AL_C * (np.clip(r, AL_R0, None) - AL_R0) ** 2
    high = AL_GAMMA * np.log2(np.maximum(r, AL_RT) + AL_BETA) + AL_DELTA
    return np.where(r >= AL_RT, high, np.where(r >= AL_R0, low, 0.0))


def applelog_decode(p):
    p = np.asarray(p, dtype=np.float64)
    high = 2.0 ** ((p - AL_DELTA) / AL_GAMMA) - AL_BETA
    low = np.sqrt(np.clip(p, 0.0, None) / AL_C) + AL_R0
    return np.where(p >= AL_PT, high, low)


# --------------------------------------------------------------------------
# Fujifilm F-Log2 (F-Log2 Data Sheet)
# --------------------------------------------------------------------------
FL2_A = 5.555556
FL2_B = 0.064829
FL2_C = 0.245281
FL2_D = 0.384316
FL2_E = 8.799461
FL2_F = 0.092864
FL2_CUT1 = 0.000889   # scene-linear breakpoint
FL2_CUT2 = 0.100686   # encoded breakpoint


def flog2_encode(x):
    x = np.asarray(x, dtype=np.float64)
    log_branch = FL2_C * np.log10(np.maximum(FL2_A * x + FL2_B, 1e-10)) + FL2_D
    lin_branch = FL2_E * x + FL2_F
    return np.where(x >= FL2_CUT1, log_branch, lin_branch)


def flog2_decode(y):
    y = np.asarray(y, dtype=np.float64)
    log_branch = (10.0 ** ((y - FL2_D) / FL2_C) - FL2_B) / FL2_A
    lin_branch = (y - FL2_F) / FL2_E
    return np.where(y >= FL2_CUT2, log_branch, lin_branch)


# --------------------------------------------------------------------------
# Gamut conversion, built from primaries
# --------------------------------------------------------------------------
D65 = (0.3127, 0.3290)
REC2020_PRIMARIES = ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046))
FGAMUT_PRIMARIES = ((0.708, 0.292), (0.170, 0.797), (0.131, 0.046))  # same as Rec.2020


def rgb_to_xyz_matrix(primaries, white):
    def xy_to_xyz(xy):
        x, y = xy
        return np.array([x / y, 1.0, (1.0 - x - y) / y])

    p = np.stack([xy_to_xyz(c) for c in primaries], axis=1)
    s = np.linalg.solve(p, xy_to_xyz(white))
    return p * s


def gamut_matrix(src_primaries, dst_primaries, white=D65):
    return np.linalg.inv(rgb_to_xyz_matrix(dst_primaries, white)) @ rgb_to_xyz_matrix(
        src_primaries, white
    )


# --------------------------------------------------------------------------
# Video range helpers (10-bit legal range 64..940)
# --------------------------------------------------------------------------
def legal_to_full(v):
    return (np.asarray(v) * 1023.0 - 64.0) / 876.0


def full_to_legal(v):
    return (np.asarray(v) * 876.0 + 64.0) / 1023.0


# --------------------------------------------------------------------------
# .cube I/O and interpolation
# --------------------------------------------------------------------------
def read_cube(path):
    size = None
    dmin = np.zeros(3)
    dmax = np.ones(3)
    rows = []
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tok = s.split()
            key = tok[0].upper()
            if key == "LUT_3D_SIZE":
                size = int(tok[1])
            elif key == "LUT_1D_SIZE":
                raise ValueError("This is a 1D LUT; a 3D LUT is required.")
            elif key == "DOMAIN_MIN":
                dmin = np.array([float(t) for t in tok[1:4]])
            elif key == "DOMAIN_MAX":
                dmax = np.array([float(t) for t in tok[1:4]])
            elif key == "LUT_3D_INPUT_RANGE":
                dmin[:] = float(tok[1])
                dmax[:] = float(tok[2])
            elif key == "TITLE":
                continue
            else:
                try:
                    rows.append([float(t) for t in tok[:3]])
                except ValueError:
                    continue
    if size is None:
        raise ValueError("No LUT_3D_SIZE found in " + path)
    data = np.array(rows, dtype=np.float64)
    if data.shape[0] != size ** 3:
        raise ValueError(f"Expected {size**3} entries, found {data.shape[0]}")
    # In .cube files red changes fastest, so the table is indexed [b, g, r].
    return data.reshape(size, size, size, 3), dmin, dmax


def write_cube(path, table, title):
    n = table.shape[0]
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f'TITLE "{title}"\n')
        fh.write(f"LUT_3D_SIZE {n}\n")
        fh.write("DOMAIN_MIN 0.0 0.0 0.0\n")
        fh.write("DOMAIN_MAX 1.0 1.0 1.0\n")
        for r, g, b in table.reshape(-1, 3):
            fh.write(f"{r:.6f} {g:.6f} {b:.6f}\n")


def apply_cube(rgb, table, dmin, dmax):
    """Trilinear interpolation. rgb: (..., 3), table indexed [b, g, r]."""
    n = table.shape[0]
    x = (np.asarray(rgb) - dmin) / (dmax - dmin) * (n - 1)
    x = np.clip(x, 0.0, n - 1)
    i0 = np.minimum(np.floor(x).astype(int), n - 2)
    f = x - i0
    r0, g0, b0 = i0[..., 0], i0[..., 1], i0[..., 2]
    fr, fg, fb = f[..., 0:1], f[..., 1:2], f[..., 2:3]

    def t(db, dg, dr):
        return table[b0 + db, g0 + dg, r0 + dr]

    c00 = t(0, 0, 0) * (1 - fr) + t(0, 0, 1) * fr
    c01 = t(0, 1, 0) * (1 - fr) + t(0, 1, 1) * fr
    c10 = t(1, 0, 0) * (1 - fr) + t(1, 0, 1) * fr
    c11 = t(1, 1, 0) * (1 - fr) + t(1, 1, 1) * fr
    c0 = c00 * (1 - fg) + c01 * fg
    c1 = c10 * (1 - fg) + c11 * fg
    return c0 * (1 - fb) + c1 * fb


def identity_grid(n):
    g = np.linspace(0.0, 1.0, n)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")
    return np.stack([r, gg, b], axis=-1)  # indexed [b, g, r], values (r, g, b)


# --------------------------------------------------------------------------
# The pipeline
# --------------------------------------------------------------------------
def applelog_to_flog2(rgb, exposure_stops=0.0, input_range="full", fuji_range="full"):
    v = np.asarray(rgb, dtype=np.float64)
    if input_range == "legal":
        v = legal_to_full(v)
    lin = applelog_decode(v) * (2.0 ** exposure_stops)
    lin = lin @ gamut_matrix(REC2020_PRIMARIES, FGAMUT_PRIMARIES).T
    flog = np.clip(flog2_encode(lin), 0.0, 1.0)
    if fuji_range == "legal":
        flog = full_to_legal(flog)
    return flog


def bake(fuji_path, size, exposure, input_range, fuji_range, out_dir):
    table, dmin, dmax = read_cube(fuji_path)
    grid = identity_grid(size)

    combined = np.clip(
        apply_cube(applelog_to_flog2(grid, exposure, input_range, fuji_range), table, dmin, dmax),
        0.0,
        1.0,
    )
    naive = np.clip(apply_cube(grid, table, dmin, dmax), 0.0, 1.0)

    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(fuji_path))[0]
    ev = f"_{exposure:+.1f}EV" if exposure else ""
    combined_path = os.path.join(out_dir, f"B_combined_AppleLog_{stem}{ev}_{size}.cube")
    naive_path = os.path.join(out_dir, f"A_naive_{stem}_{size}.cube")
    write_cube(combined_path, combined, f"B combined AppleLog to {stem}")
    write_cube(naive_path, naive, f"A naive {stem}")

    print(f"Fuji LUT: {fuji_path}  ({table.shape[0]}^3, domain {dmin} to {dmax})")
    print(f"Wrote: {combined_path}")
    print(f"Wrote: {naive_path}")
    report()


def report():
    gray_al = float(applelog_encode(0.18))
    gray_fl = float(flog2_encode(0.18))
    print("\nSanity checks (18% gray card):")
    print(f"  Apple Log code value: {gray_al:.3f}")
    print(f"  F-Log2 code value:    {gray_fl:.3f}")
    print("  The naive LUT reads Apple Log gray as if it were F-Log2, which is about")
    stops = np.log2(float(flog2_decode(gray_al)) / 0.18)
    print(f"  {stops:+.2f} stops off before the look is even applied.")
    m = gamut_matrix(REC2020_PRIMARIES, FGAMUT_PRIMARIES)
    print(f"  Rec.2020 to F-Gamut matrix is identity: {np.allclose(m, np.eye(3), atol=1e-9)}")


# --------------------------------------------------------------------------
# Self test (no Fuji LUT needed)
# --------------------------------------------------------------------------
def selftest():
    x = np.concatenate([np.linspace(-0.05, 0.02, 200), np.geomspace(0.02, 10.0, 400)])
    assert np.allclose(applelog_decode(applelog_encode(x)), x, atol=1e-7), "Apple Log round trip"
    y = np.geomspace(1e-4, 10.0, 500)
    assert np.allclose(flog2_decode(flog2_encode(y)), y, rtol=1e-6), "F-Log2 round trip"
    assert abs(flog2_encode(FL2_CUT1) - FL2_CUT2) < 1e-5, "F-Log2 continuity"
    assert abs(applelog_encode(0.18) - 0.488) < 0.002, "Apple Log 18% gray"
    assert abs(flog2_encode(0.18) - 0.391) < 0.002, "F-Log2 18% gray"

    # With an identity "Fuji LUT", the combined LUT must equal the curve conversion.
    n = 33
    ident = identity_grid(65)
    grid = identity_grid(n)
    combined = apply_cube(applelog_to_flog2(grid), ident, np.zeros(3), np.ones(3))
    expected = applelog_to_flog2(grid)
    assert np.allclose(combined, expected, atol=1e-9), "identity LUT pipeline"

    # Write/read round trip
    tmp = "_selftest.cube"
    write_cube(tmp, ident, "identity")
    back, _, _ = read_cube(tmp)
    os.remove(tmp)
    assert np.allclose(back, ident, atol=1e-6), ".cube round trip"

    print("Self test passed.")
    report()


def main():
    ap = argparse.ArgumentParser(description="Bake Apple Log -> F-Log2 -> Fuji film-sim LUT.")
    ap.add_argument("fuji_lut", nargs="?", help="Fujifilm F-Log2 film-simulation .cube file")
    ap.add_argument("--size", type=int, default=33, help="output grid size (default 33)")
    ap.add_argument("--exposure", type=float, default=0.0, help="exposure offset in stops")
    ap.add_argument("--input-range", choices=["full", "legal"], default="full",
                    help="how the camera app hands Apple Log to the LUT")
    ap.add_argument("--fuji-range", choices=["full", "legal"], default="full",
                    help="what range the Fuji LUT expects on its input")
    ap.add_argument("--out-dir", default="out")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return
    if not a.fuji_lut:
        ap.error("pass a Fuji F-Log2 .cube file, or --selftest")
    bake(a.fuji_lut, a.size, a.exposure, a.input_range, a.fuji_range, a.out_dir)


if __name__ == "__main__":
    sys.exit(main())