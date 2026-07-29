#!/usr/bin/env python3

import argparse
import json
import math
import os
import sys

import nibabel as nib
import numpy as np

try:
    from skimage.metrics import structural_similarity as ssim
except Exception:
    ssim = None


def strip_nii(name: str) -> str:
    if name.endswith(".nii.gz"):
        return name[:-7]
    if name.endswith(".nii"):
        return name[:-4]
    return name


def load_3d(path: str):
    img = nib.load(path)
    data = img.get_fdata(dtype=np.float32)
    if data.ndim == 4:
        data = data[..., 0]
    return img, np.asarray(data, dtype=np.float32)


def safe_corr(a: np.ndarray, b: np.ndarray) -> float:
    if a.size < 2:
        return float("nan")
    a_std = float(np.std(a))
    b_std = float(np.std(b))
    if a_std == 0.0 or b_std == 0.0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def safe_ssim_2d(a: np.ndarray, b: np.ndarray, data_range: float) -> float:
    if ssim is None:
        return float("nan")
    try:
        return float(ssim(a, b, data_range=data_range))
    except Exception:
        return float("nan")


def main():
    parser = argparse.ArgumentParser(description="Compute simple image-level metrics for original vs defaced NIfTI.")
    parser.add_argument("--orig", required=True, help="Original NIfTI path")
    parser.add_argument("--defaced", required=True, help="Defaced NIfTI path")
    parser.add_argument("--method", required=True, help="Defacing method name")
    parser.add_argument("--project", default="", help="Project ID")
    parser.add_argument("--subject", default="", help="Subject ID without sub- prefix")
    parser.add_argument("--session", default="", help="Session ID without ses- prefix")
    parser.add_argument("--outdir", default="metrics", help="Output directory")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    base = strip_nii(os.path.basename(args.orig))
    out_tsv = os.path.join(args.outdir, f"{base}_{args.method}_metrics.tsv")
    out_json = os.path.join(args.outdir, f"{base}_{args.method}_metrics.json")

    orig_img, orig = load_3d(args.orig)
    def_img, deff = load_3d(args.defaced)

    same_shape = (orig.shape == deff.shape)
    same_affine = bool(np.allclose(orig_img.affine, def_img.affine, atol=1e-4, rtol=1e-4)) if same_shape else False

    row = {
        "project": args.project,
        "subject": args.subject,
        "session": args.session,
        "method": args.method,
        "original_file": os.path.basename(args.orig),
        "defaced_file": os.path.basename(args.defaced),
        "shape_original": "x".join(map(str, orig.shape)),
        "shape_defaced": "x".join(map(str, deff.shape)),
        "same_shape": str(same_shape).lower(),
        "same_affine": str(same_affine).lower(),
        "n_voxels_total": "",
        "n_nonzero_original": "",
        "n_nonzero_defaced": "",
        "n_changed_voxels_total": "",
        "n_changed_voxels_nonzero": "",
        "pct_changed_total": "",
        "pct_changed_nonzero": "",
        "n_nonzero_lost": "",
        "n_nonzero_gained": "",
        "mad_nonzero": "",
        "rmse_nonzero": "",
        "pearson_nonzero": "",
        "ssim_sagittal_center": "",
        "ssim_coronal_center": "",
        "ssim_axial_center": ""
    }

    summary = dict(row)

    if same_shape:
        absdiff = np.abs(orig - deff)

        mask = (orig != 0)
        if not mask.any():
            mask = np.ones(orig.shape, dtype=bool)

        orig_m = orig[mask]
        def_m = deff[mask]
        diff_m = absdiff[mask]

        nz = orig_m[np.isfinite(orig_m)]
        if nz.size:
            p01, p99 = np.percentile(nz, [1, 99])
            data_range = float(max(p99 - p01, 1e-6))
        else:
            data_range = 1.0

        tol = max(1e-6, data_range * 1e-6)

        changed = absdiff > tol
        changed_nonzero = changed & mask

        coords = np.argwhere(mask)
        mins = coords.min(axis=0)
        maxs = coords.max(axis=0)
        cx, cy, cz = ((mins + maxs) // 2).tolist()

        ssim_sag = safe_ssim_2d(np.rot90(orig[cx, :, :]), np.rot90(deff[cx, :, :]), data_range)
        ssim_cor = safe_ssim_2d(np.rot90(orig[:, cy, :]), np.rot90(deff[:, cy, :]), data_range)
        ssim_axi = safe_ssim_2d(np.rot90(orig[:, :, cz]), np.rot90(deff[:, :, cz]), data_range)

        row.update({
            "n_voxels_total": int(orig.size),
            "n_nonzero_original": int(np.count_nonzero(orig)),
            "n_nonzero_defaced": int(np.count_nonzero(deff)),
            "n_changed_voxels_total": int(np.count_nonzero(changed)),
            "n_changed_voxels_nonzero": int(np.count_nonzero(changed_nonzero)),
            "pct_changed_total": float(np.count_nonzero(changed) / orig.size * 100.0),
            "pct_changed_nonzero": float(np.count_nonzero(changed_nonzero) / np.count_nonzero(mask) * 100.0),
            "n_nonzero_lost": int(np.count_nonzero((orig != 0) & (deff == 0))),
            "n_nonzero_gained": int(np.count_nonzero((orig == 0) & (deff != 0))),
            "mad_nonzero": float(np.mean(diff_m)),
            "rmse_nonzero": float(np.sqrt(np.mean((orig_m - def_m) ** 2))),
            "pearson_nonzero": safe_corr(orig_m.ravel(), def_m.ravel()),
            "ssim_sagittal_center": ssim_sag,
            "ssim_coronal_center": ssim_cor,
            "ssim_axial_center": ssim_axi
        })

        summary.update({
            "center_voxel_used": {"x": int(cx), "y": int(cy), "z": int(cz)},
            "data_range_used": data_range,
            "tolerance_used": tol
        })

    columns = list(row.keys())

    with open(out_tsv, "w") as f:
        f.write("\t".join(columns) + "\n")
        f.write("\t".join(str(row[c]) for c in columns) + "\n")

    summary.update(row)
    with open(out_json, "w") as f:
        json.dump(summary, f, indent=2)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        raise
