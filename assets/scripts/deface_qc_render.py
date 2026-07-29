#!/usr/bin/env python3

import argparse
import json
import os
import sys

import nibabel as nib
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


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


def main():
    parser = argparse.ArgumentParser(description="Render QC montage for original vs defaced NIfTI.")
    parser.add_argument("--orig", required=True, help="Original NIfTI path")
    parser.add_argument("--defaced", required=True, help="Defaced NIfTI path")
    parser.add_argument("--method", required=True, help="Defacing method name")
    parser.add_argument("--project", default="", help="Project ID")
    parser.add_argument("--subject", default="", help="Subject ID without sub- prefix")
    parser.add_argument("--session", default="", help="Session ID without ses- prefix")
    parser.add_argument("--outdir", default="qc", help="Output directory")
    args = parser.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    base = strip_nii(os.path.basename(args.orig))
    out_png = os.path.join(args.outdir, f"{base}_{args.method}_qc.png")
    out_json = os.path.join(args.outdir, f"{base}_{args.method}_qc.json")

    orig_img, orig = load_3d(args.orig)
    def_img, deff = load_3d(args.defaced)

    if orig.shape != deff.shape:
        raise RuntimeError(f"Shape mismatch: original={orig.shape}, defaced={deff.shape}")

    absdiff = np.abs(orig - deff)

    mask = orig != 0
    coords = np.argwhere(mask)

    if coords.size == 0:
        mins = np.array([0, 0, 0], dtype=int)
        maxs = np.array(orig.shape) - 1
    else:
        mins = coords.min(axis=0)
        maxs = coords.max(axis=0)

    cx, cy, cz = ((mins + maxs) // 2).tolist()

    nz = orig[mask] if mask.any() else orig.ravel()
    if nz.size == 0:
        lo = float(np.nanmin(orig))
        hi = float(np.nanmax(orig))
    else:
        lo, hi = np.percentile(nz, [1, 99])

    if not np.isfinite(lo):
        lo = float(np.nanmin(orig))
    if not np.isfinite(hi) or hi <= lo:
        hi = lo + 1.0

    diff_vals = absdiff[mask] if mask.any() else absdiff.ravel()
    diff_hi = float(np.percentile(diff_vals, 99)) if diff_vals.size else 1.0
    if not np.isfinite(diff_hi) or diff_hi <= 0:
        diff_hi = 1.0

    def view_slices(arr: np.ndarray):
        return {
            "sagittal": np.rot90(arr[cx, :, :]),
            "coronal": np.rot90(arr[:, cy, :]),
            "axial": np.rot90(arr[:, :, cz]),
        }

    orig_views = view_slices(orig)
    def_views = view_slices(deff)
    diff_views = view_slices(absdiff)

    planes = ["sagittal", "coronal", "axial"]
    rows = [
        ("Original", orig_views, "gray", lo, hi),
        ("Defaced", def_views, "gray", lo, hi),
        ("|Diff|", diff_views, "magma", 0.0, diff_hi),
    ]

    fig, axes = plt.subplots(nrows=3, ncols=3, figsize=(12, 12))
    fig.suptitle(
        f"Defacing QC | sub-{args.subject} ses-{args.session} | {args.method}\n{os.path.basename(args.orig)}",
        fontsize=12,
    )

    for c, plane in enumerate(planes):
        axes[0, c].set_title(plane.capitalize(), fontsize=11)

    for r, (row_name, views, cmap, vmin, vmax) in enumerate(rows):
        for c, plane in enumerate(planes):
            ax = axes[r, c]
            ax.imshow(views[plane], cmap=cmap, vmin=vmin, vmax=vmax, interpolation="nearest")
            if c == 0:
                ax.set_ylabel(row_name, fontsize=10)
            ax.set_xticks([])
            ax.set_yticks([])

    plt.tight_layout(rect=[0, 0, 1, 0.95])
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig)

    summary = {
        "project": args.project,
        "subject": args.subject,
        "session": args.session,
        "method": args.method,
        "original_file": os.path.basename(args.orig),
        "defaced_file": os.path.basename(args.defaced),
        "shape_original": list(orig.shape),
        "shape_defaced": list(deff.shape),
        "center_voxel_used": {"x": int(cx), "y": int(cy), "z": int(cz)},
        "render_png": os.path.basename(out_png),
    }

    with open(out_json, "w") as f:
        json.dump(summary, f, indent=2)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        raise
