#!/usr/bin/env python3
"""Generate brain masks for the converted qMRI cohort using HD-BET.

The MATLAB qMRI pipeline uses an optional skull-strip **brain mask**
(``config.fileMask = "mask.nii.gz"``) to (a) keep only training patches with
>=20% brain coverage and (b) confine the loss / CCC metrics to the brain. Without
a mask it falls back to the nonzero-T1W support. This script produces a proper
brain mask per patient by running HD-BET (MIC-DKFZ/HD-BET) on the T1W image.

Run AFTER preprocess_dicom_to_nifti.py and BEFORE the MATLAB scripts:

    python3 skullstrip_hdbet.py --processed processed --device cpu

For each <processed>/<AnonymizationID>/ that has T1W.nii.gz and no mask.nii.gz,
it runs HD-BET on T1W.nii.gz and writes the brain mask to
<processed>/<AnonymizationID>/mask.nii.gz. The mask shares the T1W grid, so it
matches the pipeline's reference grid (copied, not interpolated, by --resample)
and satisfies the per-patient size-equality checks.

Install HD-BET:  pip install HD-BET   (or from https://github.com/MIC-DKFZ/HD-BET)

PHI protection: only AnonymizationID and status are printed; no PHI-bearing paths.
"""

from __future__ import annotations

import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile


def find_mask(search_dir: str) -> str:
    """Locate the brain-mask NIfTI HD-BET wrote (naming varies across versions)."""
    pats = ["*_bet_mask.nii.gz", "*_mask.nii.gz", "*mask*.nii.gz", "*bet*.nii.gz"]
    for pat in pats:
        hits = sorted(glob.glob(os.path.join(search_dir, pat)))
        if hits:
            return hits[0]
    return ""


def run_hdbet(t1w: str, out_dir: str, device: str) -> str:
    """Run HD-BET on t1w into out_dir; return the path to the produced brain mask."""
    out_base = os.path.join(out_dir, "brain.nii.gz")
    # HD-BET CLI (v1/v2 compatible-ish): -i input, -o output; writes *_mask alongside.
    cmd = ["hd-bet", "-i", t1w, "-o", out_base]
    if device:
        cmd += ["-device", device]
        if device == "cpu":
            cmd += ["--disable_tta"]        # v2 flag; ignored/erroring versions handled below
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    except subprocess.CalledProcessError:
        # Retry without the optional speed flag for older HD-BET builds.
        cmd = ["hd-bet", "-i", t1w, "-o", out_base] + (["-device", device] if device else [])
        subprocess.run(cmd, check=True, capture_output=True, text=True)
    return find_mask(out_dir)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--processed", default="processed",
                    help="root with <AnonymizationID>/ subdirs (default: processed)")
    ap.add_argument("--main", default="T1W",
                    help="basename of the image to skull-strip (default: T1W)")
    ap.add_argument("--device", default="cpu",
                    help="HD-BET device: cpu | cuda | GPU index (default: cpu)")
    ap.add_argument("--overwrite", action="store_true",
                    help="re-run even if mask.nii.gz already exists")
    ap.add_argument("--ids", nargs="*", default=None,
                    help="only these AnonymizationIDs (default: all subdirs)")
    args = ap.parse_args()

    if not os.path.isdir(args.processed):
        sys.exit(f"[error] no such dir: {args.processed}")
    if shutil.which("hd-bet") is None:
        sys.exit("[error] 'hd-bet' not found on PATH. Install with: pip install HD-BET "
                 "(https://github.com/MIC-DKFZ/HD-BET)")

    ids = args.ids or sorted(d for d in os.listdir(args.processed)
                             if os.path.isdir(os.path.join(args.processed, d)))

    n_ok = n_skip = n_fail = 0
    for anon in ids:
        pdir = os.path.join(args.processed, anon)
        t1w = os.path.join(pdir, args.main + ".nii.gz")
        mask = os.path.join(pdir, "mask.nii.gz")

        if not os.path.isfile(t1w):
            print(f"[skip] {anon}: no {args.main}.nii.gz")
            n_skip += 1
            continue
        if os.path.isfile(mask) and not args.overwrite:
            print(f"[keep] {anon}: mask.nii.gz exists")
            n_skip += 1
            continue

        try:
            with tempfile.TemporaryDirectory() as tmp:
                produced = run_hdbet(t1w, tmp, args.device)
                if not produced or not os.path.isfile(produced):
                    raise FileNotFoundError("HD-BET produced no mask")
                shutil.move(produced, mask)
            print(f"[ok  ] {anon}: mask.nii.gz")
            n_ok += 1
        except Exception as exc:  # never abort the whole cohort
            print(f"[fail] {anon}: {type(exc).__name__}")
            n_fail += 1

    print(f"[done] masked={n_ok} skipped/kept={n_skip} failed={n_fail}")
    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
