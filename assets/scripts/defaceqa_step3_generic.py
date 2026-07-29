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


def psnr_from_rmse(rmse: float, data_range: float) -> float:
    if rmse <= 0.0:
        return float("inf")
    if data_range <= 0.0:
        return float("nan")
    return float(20.0 * math.log10(data_range / rmse))


def pct(n: int, d: int) -> float:
    if d == 0:
        return float("nan")
    return float(n / d * 100.0)


def main():
    parser = argparse.ArgumentParser(description="Generic DefaceQA-style Step 3 feature extraction.")
    parser.add_argument("--orig", required=True)
    parser.add_argument("--brainmask", required=True)
    parser.add_argument("--defaced", required=True)
    parser.add_argument("--method", required=True)
    parser.add_argument("--project", default="")
    parser.add_argument("--subject", default="")
    parser.add_argument("--session", default="")
    parser.add_argument("--outdir", default="defaceqa_step3")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    base = strip_nii(os.path.basename(args.orig))
    out_tsv = os.path.join(args.outdir, f"{base}_{args.method}_defaceqa_step3.tsv")
    out_json = os.path.join(args.outdir, f"{base}_{args.method}_defaceqa_step3.json")

    orig_img, orig = load_3d(args.orig)
    bm_img, bm = load_3d(args.brainmask)
    def_img, deff = load_3d(args.defaced)

    same_shape = (orig.shape == deff.shape == bm.shape)
    same_affine = False
    if same_shape:
        same_affine = bool(
            np.allclose(orig_img.affine, def_img.affine, atol=1e-4, rtol=1e-4)
            and np.allclose(orig_img.affine, bm_img.affine, atol=1e-4, rtol=1e-4)
        )

    if not same_shape:
        raise RuntimeError(
            f"Shape mismatch: orig={orig.shape}, brainmask={bm.shape}, defaced={deff.shape}"
        )

    head_mask = orig != 0
    brain_mask = bm > 0
    face_shell_mask = head_mask & (~brain_mask)

    if not np.any(head_mask):
        raise RuntimeError("Head mask is empty (original image appears to be all zero).")

    if not np.any(brain_mask):
        raise RuntimeError("Brain mask is empty.")

    absdiff = np.abs(orig - deff)

    head_vals = orig[head_mask]
    p01, p99 = np.percentile(head_vals[np.isfinite(head_vals)], [1, 99])
    data_range = float(max(p99 - p01, 1e-6))
    tol = max(1.0, data_range * 1e-3)

    changed = absdiff > tol

    brain_changed = changed & brain_mask
    head_changed = changed & head_mask
    face_shell_changed = changed & face_shell_mask

    removed = (orig != 0) & (deff == 0)
    brain_removed = removed & brain_mask
    head_removed = removed & head_mask
    face_shell_removed = removed & face_shell_mask

    n_head = int(np.count_nonzero(head_mask))
    n_brain = int(np.count_nonzero(brain_mask))
    n_face_shell = int(np.count_nonzero(face_shell_mask))

    # central slices based on head bounding box
    coords = np.argwhere(head_mask)
    mins = coords.min(axis=0)
    maxs = coords.max(axis=0)
    cx, cy, cz = ((mins + maxs) // 2).tolist()

    ssim_sag = safe_ssim_2d(np.rot90(orig[cx, :, :]), np.rot90(deff[cx, :, :]), data_range)
    ssim_cor = safe_ssim_2d(np.rot90(orig[:, cy, :]), np.rot90(deff[:, cy, :]), data_range)
    ssim_axi = safe_ssim_2d(np.rot90(orig[:, :, cz]), np.rot90(deff[:, :, cz]), data_range)

    ssim_vals = [v for v in [ssim_sag, ssim_cor, ssim_axi] if np.isfinite(v)]
    ssim_mean = float(np.mean(ssim_vals)) if ssim_vals else float("nan")

    head_orig = orig[head_mask]
    head_def = deff[head_mask]
    brain_orig = orig[brain_mask]
    brain_def = deff[brain_mask]

    head_rmse = float(np.sqrt(np.mean((head_orig - head_def) ** 2)))
    brain_rmse = float(np.sqrt(np.mean((brain_orig - brain_def) ** 2)))

    row = {
        "project": args.project,
        "subject": args.subject,
        "session": args.session,
        "method": args.method,
        "original_file": os.path.basename(args.orig),
        "defaced_file": os.path.basename(args.defaced),
        "brainmask_file": os.path.basename(args.brainmask),
        "same_shape": str(same_shape).lower(),
        "same_affine": str(same_affine).lower(),

        "n_head_voxels": n_head,
        "n_brain_voxels": n_brain,
        "n_face_shell_voxels": n_face_shell,

        "brain_relative_to_head_pct": pct(n_brain, n_head),

        "pct_head_altered": pct(int(np.count_nonzero(head_changed)), n_head),
        "pct_head_removed": pct(int(np.count_nonzero(head_removed)), n_head),

        "pct_brain_altered": pct(int(np.count_nonzero(brain_changed)), n_brain),
        "pct_brain_removed": pct(int(np.count_nonzero(brain_removed)), n_brain),

        "pct_face_shell_altered": pct(int(np.count_nonzero(face_shell_changed)), n_face_shell),
        "pct_face_shell_removed": pct(int(np.count_nonzero(face_shell_removed)), n_face_shell),

        "mad_head": float(np.mean(np.abs(head_orig - head_def))),
        "rmse_head": head_rmse,
        "psnr_head": psnr_from_rmse(head_rmse, data_range),
        "pearson_head": safe_corr(head_orig.ravel(), head_def.ravel()),

        "mad_brain": float(np.mean(np.abs(brain_orig - brain_def))),
        "rmse_brain": brain_rmse,
        "pearson_brain": safe_corr(brain_orig.ravel(), brain_def.ravel()),

        "ssim_sagittal_center": ssim_sag,
        "ssim_coronal_center": ssim_cor,
        "ssim_axial_center": ssim_axi,
        "ssim_center_mean": ssim_mean,

        "data_range_used": data_range,
        "tolerance_used": tol,
        "center_voxel_x": int(cx),
        "center_voxel_y": int(cy),
        "center_voxel_z": int(cz),
    }

    columns = list(row.keys())

    with open(out_tsv, "w") as f:
        f.write("\t".join(columns) + "\n")
        f.write("\t".join(str(row[c]) for c in columns) + "\n")

    with open(out_json, "w") as f:
        json.dump(row, f, indent=2)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        raise
