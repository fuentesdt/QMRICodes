#!/usr/bin/env python3
"""Convert the MAGiC synthetic DICOM cohort to NIfTI for the qMRI 3D-CNN pipeline.

The cohort CSV (schema in doc/fulldataset.md) indexes, per patient:
  - weighted synthetic contrasts, one DICOM series each, in the columns
    ``T1W Synthetic`` / ``T2W Synthetic`` / ``FLAIR Synthetic`` (and ``PS Synthetic``);
  - ``SYMAPS``: a directory (under ``synthentic_path``) holding the quantitative
    T1 / T2 / PD maps as per-slice DICOM files named ``SYMAPS_<NN>_{T1,T2,PD}.dcm``.

This script writes NIfTI under ``<out>/<AnonymizationID>/``:
  T1W.nii.gz, T2W.nii.gz, FLAIR.nii.gz            (weighted inputs)
  T1map.nii.gz, T2map.nii.gz, PD.nii.gz           (quantitative references, from SYMAPS)
  PS.nii.gz                                        (if a PS Synthetic column is present)
Each weighted NIfTI's ``descrip`` header field is stamped with the pulse-sequence
acquisition parameters (TR/TE/FA/TI) read from its DICOM, so the MATLAB pipeline
(readAcqParams) can read them back via niftiinfo().Description.

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
import glob
import os
import re
import shutil
import sys

import pandas as pd
import SimpleITK as sitk
import nibabel as nib

# ----------------------------------------------------------------------------
# Weighted contrasts: (candidate CSV column names, output basename, tags to store).
# Each column is a single DICOM series. Tags map to the physics forward model:
#   T1w (SPGR/GRE) -> TR, TE, FA ;  T2w (SE) -> TR, TE ;  FLAIR (IR) -> TR, TE, TI
# PS is a synthetic weighted contrast (not the PD map); stored for completeness.
# ----------------------------------------------------------------------------
CONTRASTS = [
    (["T1W Synthetic", "T1W_Synthetic", "T1W"],       "T1W",   ["TR", "TE", "FA"]),
    (["T2W Synthetic", "T2W_Synthetic", "T2W"],       "T2W",   ["TR", "TE"]),
    (["FLAIR Synthetic", "FLAIR_Synthetic", "FLAIR"], "FLAIR", ["TR", "TE", "TI"]),
    (["PS Synthetic", "PS_Synthetic"],                "PS",    []),
]

# SYMAPS quantitative maps: filename suffix in SYMAPS_<NN>_<suffix>.dcm -> output.
# Each is a stack of per-slice DICOM files sharing that suffix, in one directory.
SYMAP_TYPES = [("T1", "T1map"), ("T2", "T2map"), ("PD", "PD")]
SYMAPS_COLS = ["SYMAPS", "SyMaps", "symaps", "SYMAP"]

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


def resolve_source(row: pd.Series, candidates, data_root: str):
    """Locate a contrast's DICOM source.

    Returns (resolved_path, raw_value, tried_paths). The raw value from the
    contrast column may be an absolute path, a path relative to CWD, or a name
    relative to ``synthentic_path`` / ``dicom_path`` / ``--data-root``. We try
    each and return the first that exists so the caller can report exactly what
    was attempted when nothing is found.
    """
    raw = first_col(row, candidates)
    if not raw:
        return "", "", []

    syn = first_col(row, ["synthentic_path", "synthetic_path"])
    dcm = first_col(row, ["dicom_path"])

    tried = [raw]                                   # as given (abs or CWD-relative)
    if not os.path.isabs(raw):
        if syn:
            tried.append(os.path.join(syn, raw))
        if dcm:
            tried.append(os.path.join(dcm, raw))
        if data_root:
            tried.append(os.path.join(data_root, raw))
            if syn:
                tried.append(os.path.join(data_root, syn, raw))
    elif data_root:
        # absolute path recorded on another machine: retry under data_root
        tried.append(os.path.join(data_root, raw.lstrip("/\\")))

    for cand in tried:
        if os.path.exists(cand):
            return cand, raw, tried
    return "", raw, tried


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


def _slice_sort_key(f: str):
    """Sort key for a SYMAPS slice: prefer through-plane position, else file index."""
    idx = None
    m = re.search(r"_(\d+)_[A-Za-z0-9]+\.dcm$", os.path.basename(f))
    if m:
        idx = int(m.group(1))
    try:
        import pydicom
        ds = pydicom.dcmread(f, stop_before_pixels=True, force=True)
        ipp = [float(x) for x in getattr(ds, "ImagePositionPatient", [])]
        iop = [float(x) for x in getattr(ds, "ImageOrientationPatient", [])]
        if len(ipp) == 3 and len(iop) == 6:
            r, c = iop[:3], iop[3:]
            n = (r[1] * c[2] - r[2] * c[1],
                 r[2] * c[0] - r[0] * c[2],
                 r[0] * c[1] - r[1] * c[0])
            return (0, sum(a * b for a, b in zip(ipp, n)))
    except Exception:
        pass
    return (1, idx if idx is not None else 0)


def read_map_series(symaps_dir: str, suffix: str) -> sitk.Image:
    """Build one SYMAPS quantitative map (T1/T2/PD) from its per-slice DICOM files.

    Files are ``SYMAPS_<NN>_<suffix>.dcm``; they are gathered, ordered by slice
    position (falling back to the <NN> index), and stacked. RescaleSlope/Intercept
    are applied by the reader so the NIfTI holds real map values.
    """
    files = glob.glob(os.path.join(symaps_dir, f"*_{suffix}.dcm"))
    if not files:  # case-insensitive fallback
        files = [f for f in glob.glob(os.path.join(symaps_dir, "*"))
                 if os.path.isfile(f) and f.upper().endswith(f"_{suffix.upper()}.DCM")]
    if not files:
        raise FileNotFoundError(f"no *_{suffix}.dcm files in SYMAPS directory")
    files = sorted(files, key=_slice_sort_key)
    reader = sitk.ImageSeriesReader()
    reader.SetFileNames(files)
    return reader.Execute()


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


def read_descrip(nii_path: str) -> str:
    """Read back the NIfTI 'descrip' string (empty if unreadable)."""
    try:
        return bytes(nib.load(nii_path).header["descrip"]).split(b"\x00")[0].decode(
            "ascii", "ignore")
    except Exception:
        return ""


def _grid(img: sitk.Image):
    """Geometry signature (size, spacing, origin, direction) for grid comparison."""
    return (tuple(int(s) for s in img.GetSize()),
            tuple(round(s, 5) for s in img.GetSpacing()),
            tuple(round(o, 4) for o in img.GetOrigin()),
            tuple(round(d, 5) for d in img.GetDirection()))


def resample_patient(pdir: str, rpdir: str, ref_base: str = "T1W") -> int:
    """Mirror one patient's NIfTI set from pdir into rpdir on a common grid.

    The reference grid is ``<ref_base>.nii.gz`` (the weighted-input space the CNN
    works in). Volumes whose grid already matches are copied verbatim (preserving
    the acq 'descrip'); volumes on a different grid are linearly resampled onto the
    reference and the acq 'descrip' is re-stamped. Returns the number of volumes
    resampled, or -1 if the reference is missing.
    """
    ref_path = os.path.join(pdir, ref_base + ".nii.gz")
    if not os.path.isfile(ref_path):
        print(f"[warn] {os.path.basename(pdir)}: no {ref_base}.nii.gz; skip resample")
        return -1
    ref = sitk.ReadImage(ref_path)
    ref_sig = _grid(ref)
    os.makedirs(rpdir, exist_ok=True)

    n_res = 0
    for fn in sorted(os.listdir(pdir)):
        if not fn.endswith(".nii.gz"):
            continue
        src = os.path.join(pdir, fn)
        dst = os.path.join(rpdir, fn)
        img = sitk.ReadImage(src)
        if _grid(img) == ref_sig:
            shutil.copyfile(src, dst)                 # identical grid -> copy as-is
        else:
            out = sitk.Resample(img, ref, sitk.Transform(), sitk.sitkLinear,
                                0.0, img.GetPixelIDValue())
            sitk.WriteImage(out, dst)
            stamp_descrip(dst, read_descrip(src))     # resampling drops descrip
            n_res += 1
            print(f"[resamp] {os.path.basename(pdir)}/{fn} -> {ref_base} grid")
    return n_res


def preview_first_row(row: pd.Series, id_real: str, data_root: str) -> None:
    """Print the path-like column values for the first patient so the operator can
    see what the contrast columns actually contain (path? flag? relative name?)."""
    anon = str(row[id_real]).strip()
    print(f"[preview] first patient {anon} -- raw column values:")
    for label, cands in (
        ("dicom_path",      ["dicom_path"]),
        ("synthentic_path", ["synthentic_path", "synthetic_path"]),
    ):
        val = first_col(row, cands)
        if val == "":
            print(f"    {label:16s}= <empty/absent>")
        else:
            exists = "exists" if os.path.exists(val) else "NOT a path on this host"
            print(f"    {label:16s}= {val!r}  ({exists})")
    for label, cands in (
        ("T1W Synthetic",   ["T1W Synthetic", "T1W_Synthetic", "T1W"]),
        ("T2W Synthetic",   ["T2W Synthetic", "T2W_Synthetic", "T2W"]),
        ("FLAIR Synthetic", ["FLAIR Synthetic", "FLAIR_Synthetic", "FLAIR"]),
        ("SYMAPS",          SYMAPS_COLS),
        ("PS Synthetic",    ["PS Synthetic", "PS_Synthetic"]),
    ):
        resolved, raw, _ = resolve_source(row, cands, data_root)
        if raw == "":
            print(f"    {label:16s}= <empty/absent>")
        elif resolved:
            print(f"    {label:16s}= {raw!r}  (found -> {resolved})")
        else:
            print(f"    {label:16s}= {raw!r}  (NOT resolvable to a file/dir)")
    print("[preview] if the *_Synthetic values are not paths (e.g. True/1), the "
          "files likely live inside synthentic_path -- use --data-root or tell me "
          "the layout.")


def run(csv_path: str, out_root: str, id_col: str, require_matched: bool,
        overwrite: bool, dry_run: bool, data_root: str,
        resample: bool, resampled_out: str) -> int:
    df = pd.read_csv(csv_path, dtype=str, keep_default_na=False)

    # Resolve the id column case-insensitively.
    id_lookup = {str(c).strip().lower(): c for c in df.columns}
    id_real = id_lookup.get(id_col.strip().lower())
    if id_real is None:
        sys.exit(f"[error] id column '{id_col}' not found. Columns: "
                 f"{list(df.columns)}")

    print(f"[info] cwd={os.getcwd()}")
    print(f"[info] csv={os.path.abspath(csv_path)} rows={len(df)}")
    print(f"[info] out={os.path.abspath(out_root)} data_root={data_root or '<none>'}")
    if resample:
        print(f"[info] resample=on -> {os.path.abspath(resampled_out)} "
              f"(reference grid: T1W)")
    if len(df):
        preview_first_row(df.iloc[0], id_real, data_root)

    seen = set()
    n_ok = n_fail = n_pat = n_resampled = 0
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
            src, raw, tried = resolve_source(row, candidates, data_root)
            out_path = os.path.join(pdir, base + ".nii.gz")

            if not raw:
                continue  # contrast column empty/absent for this patient
            if not src:
                # Show the value read and everything tried, so the operator can
                # tell whether the cell is a path, a relative name, or a flag.
                print(f"[skip] {anon}/{base}: source not found | value={raw!r} "
                      f"tried={tried}")
                n_fail += 1
                continue
            if os.path.exists(out_path) and not overwrite:
                print(f"[keep] {anon}/{base}: exists")
                n_ok += 1
                continue

            if dry_run:
                print(f"[dry ] {anon}/{base} <- {src}")
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

        # SYMAPS quantitative maps (T1map/T2map/PD) from one directory of
        # per-slice DICOM files split by filename suffix.
        sym_dir, sym_raw, sym_tried = resolve_source(row, SYMAPS_COLS, data_root)
        if sym_raw and not sym_dir:
            print(f"[skip] {anon}/SYMAPS: dir not found | value={sym_raw!r} "
                  f"tried={sym_tried}")
            n_fail += 1
        elif sym_dir:
            for suffix, base in SYMAP_TYPES:
                out_path = os.path.join(pdir, base + ".nii.gz")
                if os.path.exists(out_path) and not overwrite:
                    print(f"[keep] {anon}/{base}: exists")
                    n_ok += 1
                    continue
                if dry_run:
                    print(f"[dry ] {anon}/{base} <- SYMAPS *_{suffix} in {sym_dir}")
                    n_ok += 1
                    continue
                try:
                    img = read_map_series(sym_dir, suffix)
                    sitk.WriteImage(sitk.Cast(img, sitk.sitkFloat32), out_path)
                    print(f"[ok  ] {anon}/{base} (SYMAPS *_{suffix})")
                    n_ok += 1
                except Exception as exc:
                    print(f"[fail] {anon}/{base}: {type(exc).__name__}: {exc}")
                    n_fail += 1

        # Resample to a common grid (weighted-input space) into a separate dir,
        # so MATLAB's size-equality check passes when SYMAPS maps and weighted
        # contrasts were exported on different grids.
        if resample and not dry_run:
            n = resample_patient(pdir, os.path.join(resampled_out, anon))
            if n > 0:
                n_resampled += 1

    print(f"[done] patients={n_pat} converted/kept={n_ok} failed/skipped={n_fail}"
          + (f" resampled_patients={n_resampled}" if resample else ""))
    if resample:
        print(f"[done] point MATLAB config.processedRoot at {os.path.abspath(resampled_out)}")
    return 0 if n_fail == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--csv", required=True, help="cohort CSV (doc/fulldataset.md schema)")
    ap.add_argument("--out", default="processed", help="output root (default: processed)")
    ap.add_argument("--id-col", default="AnonymizationID", help="patient id column")
    ap.add_argument("--data-root", default="",
                    help="prefix for relative (or re-homed absolute) DICOM paths "
                         "in the CSV; also joined with synthentic_path")
    ap.add_argument("--require-matched", action="store_true",
                    help="only convert rows whose match_status is a valid match")
    ap.add_argument("--overwrite", action="store_true",
                    help="re-convert even if the output NIfTI already exists")
    ap.add_argument("--dry-run", action="store_true",
                    help="list intended conversions without reading pixel data")
    ap.add_argument("--resample", action="store_true",
                    help="mirror each patient onto a common grid (the T1W input "
                         "space) into a separate directory; volumes whose grid "
                         "differs are linearly resampled, others copied")
    ap.add_argument("--resampled-out", default="",
                    help="destination for --resample (default: <out>_resampled)")
    args = ap.parse_args()

    if not os.path.isfile(args.csv):
        sys.exit(f"[error] CSV not found: {args.csv}")

    resampled_out = args.resampled_out
    if args.resample and not resampled_out:
        resampled_out = args.out.rstrip("/\\") + "_resampled"

    return run(args.csv, args.out, args.id_col, args.require_matched,
               args.overwrite, args.dry_run, args.data_root,
               args.resample, resampled_out)


if __name__ == "__main__":
    raise SystemExit(main())
