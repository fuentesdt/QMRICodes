#!/usr/bin/env python3
"""Convert the MAGiC synthetic DICOM cohort to NIfTI for the qMRI 3D-CNN pipeline.

The cohort CSV (schema in doc/fulldataset.md) indexes each patient's synthetic
contrasts as DICOM series in the columns ``T1W Synthetic``, ``T2W Synthetic``,
``FLAIR Synthetic`` and ``PS Synthetic``. This script converts each series to
NIfTI under ``<out>/<AnonymizationID>/`` (T1W.nii.gz, T2W.nii.gz, FLAIR.nii.gz,
PD.nii.gz) using SimpleITK, and stamps the pulse-sequence acquisition parameters
(TR/TE/FA/TI) read from the DICOM header into each NIfTI's ``descrip`` field so
the MATLAB pipeline (readAcqParams) can read them back via niftiinfo().Description.

Run this BEFORE the MATLAB training/prediction scripts, e.g.:

    python3 preprocess_dicom_to_nifti.py --csv dataset.csv --out processed

PHI protection (see ../radpathsandbox/CLAUDE.md): only AnonymizationID and the
contrast name are ever printed or used in output paths; MRN / Study UID /
Series UID are never logged or written. The produced NIfTI carries only pixel
data, geometry, and the numeric acquisition ``descrip`` -- DICOM header PHI is
dropped, not copied.
"""

from __future__ import annotations

import argparse
import os
import sys

import pandas as pd
import SimpleITK as sitk
import nibabel as nib

# ----------------------------------------------------------------------------
# Contrast table: (candidate CSV column names, output basename, tags to store).
# Tags map to the physics forward model in the MATLAB pipeline:
#   T1w (SPGR/GRE) -> TR, TE, FA ;  T2w (SE) -> TR, TE ;  FLAIR (IR) -> TR, TE, TI
# PD carries no timing tags (it is a quantitative map, not a weighted signal).
# ----------------------------------------------------------------------------
CONTRASTS = [
    (["T1W Synthetic", "T1W_Synthetic", "T1W"],     "T1W",   ["TR", "TE", "FA"]),
    (["T2W Synthetic", "T2W_Synthetic", "T2W"],     "T2W",   ["TR", "TE"]),
    (["FLAIR Synthetic", "FLAIR_Synthetic", "FLAIR"], "FLAIR", ["TR", "TE", "TI"]),
    (["PS Synthetic", "PD Synthetic", "PS_Synthetic"], "PD",  []),
]

# DICOM attribute name for each short tag key we store.
TAG_ATTR = {
    "TR": "RepetitionTime",   # (0018,0080) ms
    "TE": "EchoTime",         # (0018,0081) ms
    "FA": "FlipAngle",        # (0018,1314) deg
    "TI": "InversionTime",    # (0018,0082) ms
}

# match_status values that count as a valid DICOM<->synthetic match.
MATCHED_OK = {"matched", "match", "ok", "valid", "true", "1"}


def first_col(row: pd.Series, candidates) -> str:
    """First non-empty value among candidate column names (case-insensitive)."""
    lower = {str(c).strip().lower(): c for c in row.index}
    for cand in candidates:
        col = lower.get(str(cand).strip().lower())
        if col is None:
            continue
        val = str(row[col]).strip()
        if val and val.lower() not in ("nan", "na", "none", "<missing>"):
            return val
    return ""


def is_matched(row: pd.Series) -> bool:
    val = first_col(row, ["match_status"])
    return (val == "") or (val.strip().lower() in MATCHED_OK)


def read_series(path: str) -> sitk.Image:
    """Read a DICOM series (directory) or a single DICOM file as a SimpleITK image.

    Follows the cervicalsandbox/src/dicom_to_nifti.py idiom.
    """
    if os.path.isdir(path):
        reader = sitk.ImageSeriesReader()
        names = reader.GetGDCMSeriesFileNames(path)
        if not names:
            raise FileNotFoundError("no DICOM series in directory")
        reader.SetFileNames(names)
        return reader.Execute()
    return sitk.ReadImage(path)


def first_dicom_file(path: str) -> str:
    """A representative DICOM file for header reading (series dir -> first slice)."""
    if os.path.isfile(path):
        return path
    if os.path.isdir(path):
        names = sitk.ImageSeriesReader().GetGDCMSeriesFileNames(path)
        if names:
            return names[0]
        for entry in sorted(os.listdir(path)):
            fp = os.path.join(path, entry)
            if os.path.isfile(fp):
                return fp
    return ""


def read_acq_tags(dcm_file: str, tags) -> dict:
    """Read requested timing tags (TR/TE/FA/TI) from a DICOM header via pydicom."""
    out = {}
    if not tags or not dcm_file:
        return out
    try:
        import pydicom
        ds = pydicom.dcmread(dcm_file, stop_before_pixels=True, force=True)
    except Exception:
        return out
    for key in tags:
        raw = getattr(ds, TAG_ATTR[key], None)
        try:
            if raw is not None and str(raw).strip() != "":
                out[key] = float(raw)
        except (TypeError, ValueError):
            pass
    return out


def descrip_from_tags(tags: dict) -> str:
    """Compact 'TR=..;TE=..;FA=..;TI=..' string for the NIfTI descrip field (<=80B)."""
    parts = [f"{k}={tags[k]:g}" for k in ("TR", "TE", "FA", "TI") if k in tags]
    return ";".join(parts)[:80]


def stamp_descrip(nii_path: str, descrip: str) -> None:
    """Write `descrip` into the NIfTI header (nibabel; ITK does not persist it)."""
    if not descrip:
        return
    img = nib.load(nii_path)
    img.header["descrip"] = descrip.encode("ascii", "ignore")[:80]
    img.to_filename(nii_path)


def run(csv_path: str, out_root: str, id_col: str, require_matched: bool,
        overwrite: bool, dry_run: bool) -> int:
    df = pd.read_csv(csv_path, dtype=str, keep_default_na=False)

    # Resolve the id column case-insensitively.
    id_lookup = {str(c).strip().lower(): c for c in df.columns}
    id_real = id_lookup.get(id_col.strip().lower())
    if id_real is None:
        sys.exit(f"[error] id column '{id_col}' not found in {csv_path}")

    seen = set()
    n_ok = n_fail = n_pat = 0
    for _, row in df.iterrows():
        anon = str(row[id_real]).strip()
        if not anon or anon.lower() in ("nan", "na", "none"):
            continue
        if anon in seen:            # one folder per patient
            continue
        seen.add(anon)
        if require_matched and not is_matched(row):
            continue
        n_pat += 1

        pdir = os.path.join(out_root, anon)
        if not dry_run:
            os.makedirs(pdir, exist_ok=True)

        for candidates, base, tags in CONTRASTS:
            src = first_col(row, candidates)
            out_path = os.path.join(pdir, base + ".nii.gz")

            if not src:
                continue  # contrast not provided for this patient
            if not os.path.exists(src):
                print(f"[skip] {anon}/{base}: source not found")
                n_fail += 1
                continue
            if os.path.exists(out_path) and not overwrite:
                print(f"[keep] {anon}/{base}: exists")
                n_ok += 1
                continue

            if dry_run:
                print(f"[dry ] {anon}/{base} <- DICOM")
                n_ok += 1
                continue

            try:
                img = read_series(src)
                sitk.WriteImage(sitk.Cast(img, sitk.sitkFloat32), out_path)
                acq = read_acq_tags(first_dicom_file(src), tags)
                stamp_descrip(out_path, descrip_from_tags(acq))
                tagstr = descrip_from_tags(acq) or "no-acq-tags"
                print(f"[ok  ] {anon}/{base} [{tagstr}]")
                n_ok += 1
            except Exception as exc:  # never abort the whole cohort
                print(f"[fail] {anon}/{base}: {type(exc).__name__}: {exc}")
                n_fail += 1

    print(f"[done] patients={n_pat} converted/kept={n_ok} failed/skipped={n_fail}")
    return 0 if n_fail == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", required=True, help="cohort CSV (doc/fulldataset.md schema)")
    ap.add_argument("--out", default="processed", help="output root (default: processed)")
    ap.add_argument("--id-col", default="AnonymizationID", help="patient id column")
    ap.add_argument("--require-matched", action="store_true",
                    help="only convert rows whose match_status is a valid match")
    ap.add_argument("--overwrite", action="store_true",
                    help="re-convert even if the output NIfTI already exists")
    ap.add_argument("--dry-run", action="store_true",
                    help="list intended conversions without reading pixel data")
    args = ap.parse_args()

    if not os.path.isfile(args.csv):
        sys.exit(f"[error] CSV not found: {args.csv}")

    return run(args.csv, args.out, args.id_col, args.require_matched,
               args.overwrite, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
