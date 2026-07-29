#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path
from typing import List, Optional

import pandas as pd


METHOD_PATTERNS = [
    "pydeface",
    "mri_deface",
    "fsl_deface",
    "afni_refacer",
]


def detect_method_from_text(text: str) -> Optional[str]:
    t = text.lower()
    for m in METHOD_PATTERNS:
        if m in t:
            return m
    return None


def find_first_column(df: pd.DataFrame, candidates: List[str]) -> Optional[str]:
    lowered = {c.lower(): c for c in df.columns}
    for cand in candidates:
        if cand.lower() in lowered:
            return lowered[cand.lower()]
    return None


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df.columns = [str(c).strip() for c in df.columns]
    return df


def strip_nii(name: str) -> str:
    name = re.sub(r"\.nii\.gz$", "", name)
    name = re.sub(r"\.nii$", "", name)
    return name


def normalize_id(value) -> str:
    s = str(value).strip()
    s = re.sub(r"^(sub|ses)-", "", s)
    s = s.lstrip("0")
    return s if s else "0"


def normalize_image_name(name: str) -> str:
    n = Path(str(name)).name
    n = re.sub(r"\.deface_qc\.json$", "", n)
    n = re.sub(r"\.(csv|tsv|json)$", "", n)
    n = strip_nii(n)
    n = re.sub(r"_defaced$", "", n)
    n = re.sub(r"_(pydeface|mri_deface|fsl_deface|afni_refacer)_metrics$", "", n)
    n = re.sub(r"_metrics$", "", n)
    return n


def extract_subject_session(text: str):
    msub = re.search(r"sub-?([A-Za-z0-9]+)", text)
    mses = re.search(r"ses-?([A-Za-z0-9]+)", text)
    subject = normalize_id(msub.group(1)) if msub else ""
    session = normalize_id(mses.group(1)) if mses else ""
    return subject, session


def read_metric_manifest(path: Path) -> List[Path]:
    if not path.exists():
        return []
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()]
    return [Path(line) for line in lines if line]


def read_detector_manifest(path: Path) -> pd.DataFrame:
    if not path.exists():
        return pd.DataFrame(columns=["subject", "session", "deface_method", "image_name", "json_path"])

    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            raise ValueError(f"Detector manifest line must have 5 tab-separated fields, got: {line}")
        subject, session, deface_method, image_name, json_path = parts
        rows.append({
            "subject": normalize_id(subject),
            "session": normalize_id(session),
            "deface_method": str(deface_method).strip(),
            "image_name": normalize_image_name(image_name),
            "json_path": json_path,
        })
    return pd.DataFrame(rows)


def load_one_metric_file(path: Path) -> pd.DataFrame:
    suffixes = "".join(path.suffixes).lower()

    if suffixes.endswith(".json"):
        with open(path, "r", encoding="utf-8") as f:
            obj = json.load(f)
        rows = obj if isinstance(obj, list) else [obj]
        return normalize_columns(pd.json_normalize(rows))

    if suffixes.endswith(".tsv"):
        return normalize_columns(pd.read_csv(path, sep="\t"))

    if suffixes.endswith(".csv"):
        return normalize_columns(pd.read_csv(path))

    try:
        df = pd.read_csv(path, sep="\t")
        if df.shape[1] > 1:
            return normalize_columns(df)
    except Exception:
        pass

    return normalize_columns(pd.read_csv(path))


def enrich_metric_df(df: pd.DataFrame, source_file: Path) -> pd.DataFrame:
    df = df.copy()
    df["source_file"] = source_file.name

    method_col = find_first_column(df, ["deface_method", "method", "tool", "algorithm", "defacer"])
    if method_col is None:
        df["deface_method"] = detect_method_from_text(str(source_file)) or "unknown"
    else:
        df["deface_method"] = df[method_col].astype(str)

    subj_col = find_first_column(df, ["subject", "sub", "participant_id", "sub_id"])
    if subj_col is None:
        subject, session = extract_subject_session(source_file.name)
        df["subject"] = subject
    else:
        df["subject"] = df[subj_col].map(normalize_id)

    ses_col = find_first_column(df, ["session", "ses", "session_id"])
    if ses_col is None:
        subject, session = extract_subject_session(source_file.name)
        df["session"] = session
    else:
        df["session"] = df[ses_col].map(normalize_id)

    image_col = find_first_column(df, ["image", "image_name", "basename", "input_file", "file", "filename"])
    if image_col is None:
        df["image_name"] = normalize_image_name(source_file.name)
    else:
        df["image_name"] = df[image_col].astype(str).map(normalize_image_name)

    return df


def load_detector_json_with_meta(subject: str, session: str, deface_method: str, image_name: str, json_path: str) -> pd.DataFrame:
    path = Path(json_path)
    with open(path, "r", encoding="utf-8") as f:
        obj = json.load(f)

    row = obj if isinstance(obj, dict) else obj[0]
    row = dict(row)

    row["source_file"] = path.name
    row["subject"] = normalize_id(subject)
    row["session"] = normalize_id(session)
    row["deface_method"] = deface_method
    row["image_name"] = normalize_image_name(image_name)

    if "confidence" in row:
        row["detector_confidence"] = row["confidence"]
    elif "score" in row:
        row["detector_confidence"] = row["score"]
    elif "probability" in row:
        row["detector_confidence"] = row["probability"]

    if "passed" in row:
        row["detector_pass"] = row["passed"]
    elif "pass" in row:
        row["detector_pass"] = row["pass"]
    elif "is_defaced" in row:
        row["detector_pass"] = row["is_defaced"]

    return pd.DataFrame([row])


def build_summary(df: pd.DataFrame) -> pd.DataFrame:
    base = (
        df.groupby("deface_method", dropna=False)
        .agg(
            n_rows=("deface_method", "size"),
            n_subjects=("subject", "nunique"),
            n_sessions=("session", "nunique"),
            n_images=("image_name", "nunique"),
        )
        .reset_index()
    )

    numeric_cols = [
        c for c in df.columns
        if c not in {"deface_method", "subject", "session", "image_name", "source_file"}
        and pd.api.types.is_numeric_dtype(df[c])
        and c not in {"detector_pass"}
    ]

    out = base.copy()

    for col in numeric_cols:
        stats = (
            df.groupby("deface_method", dropna=False)[col]
            .agg(["mean", "std", "min", "max"])
            .reset_index()
            .rename(columns={
                "mean": f"{col}__mean",
                "std": f"{col}__std",
                "min": f"{col}__min",
                "max": f"{col}__max",
            })
        )
        out = out.merge(stats, on="deface_method", how="left")

    if "detector_pass" in df.columns:
        tmp = df.copy()
        tmp["detector_pass"] = tmp["detector_pass"].astype(float)
        pass_stats = (
            tmp.groupby("deface_method", dropna=False)["detector_pass"]
            .agg(["mean", "sum", "count"])
            .reset_index()
            .rename(columns={
                "mean": "detector_pass_rate",
                "sum": "detector_pass_n",
                "count": "detector_n",
            })
        )
        out = out.merge(pass_stats, on="deface_method", how="left")

    return out.sort_values("deface_method")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-per-subject", required=True)
    parser.add_argument("--out-summary", required=True)
    parser.add_argument("--metric-manifest", required=True)
    parser.add_argument("--detector-manifest", required=True)
    args = parser.parse_args()

    metric_paths = read_metric_manifest(Path(args.metric_manifest))
    detector_manifest = read_detector_manifest(Path(args.detector_manifest))

    metric_dfs = []
    for path in metric_paths:
        if not path.exists():
            continue
        df = load_one_metric_file(path)
        df = enrich_metric_df(df, path)
        metric_dfs.append(df)

    if metric_dfs:
        merged = pd.concat(metric_dfs, ignore_index=True, sort=False)
    else:
        merged = pd.DataFrame(columns=["subject", "session", "image_name", "deface_method"])

    detector_dfs = []
    for _, row in detector_manifest.iterrows():
        json_path = Path(row["json_path"])
        if not json_path.exists():
            continue
        detector_dfs.append(
            load_detector_json_with_meta(
                subject=row["subject"],
                session=row["session"],
                deface_method=row["deface_method"],
                image_name=row["image_name"],
                json_path=row["json_path"],
            )
        )

    if detector_dfs:
        detector_df = pd.concat(detector_dfs, ignore_index=True, sort=False)

        keep_cols = [c for c in [
            "subject", "session", "image_name", "deface_method",
            "detector_confidence", "detector_pass", "source_file"
        ] if c in detector_df.columns]

        detector_df = detector_df[keep_cols].copy()

        merged = merged.merge(
            detector_df,
            on=["subject", "session", "image_name", "deface_method"],
            how="left",
            suffixes=("", "__det")
        )

    sort_cols = [c for c in ["subject", "session", "image_name", "deface_method"] if c in merged.columns]
    if sort_cols:
        merged = merged.sort_values(sort_cols)

    summary = build_summary(merged)

    merged.to_csv(args.out_per_subject, index=False)
    summary.to_csv(args.out_summary, index=False)

if __name__ == "__main__":
    main()