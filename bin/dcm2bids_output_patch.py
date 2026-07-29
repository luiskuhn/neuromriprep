#!/usr/bin/env python3
"""
Patch BIDS JSON metadata after dcm2bids for special subjects where two generic
GRE fieldmap blocks were converted as run-01 and run-02.

For subjects listed in the VPN file:
- fmap/*run-01*.json -> rest GRE fieldmap
- fmap/*run-02*.json -> EAT/experiment GRE fieldmap
- func/*task-rest*_bold.json -> rest GRE + PA source
- func/*task-EAT*_bold.json and func/*task-ERT*_bold.json -> EAT GRE source

This script intentionally edits final BIDS JSONs, because run-01/run-02 only
exist after dcm2bids has written the output.
"""

import argparse
import json
import shutil
from pathlib import Path
from typing import Any


REST_PHASEDIFF_ID = "phasediff_fmap_ses-01_rest"
EAT_PHASEDIFF_ID = "phasediff_fmap_ses-01_eat"
# Use the identifier that is actually present in your output, without the hyphen.
REST_PEPOLAR_ID = "pepolar_fmap0_ses01"


def normalise_subject(value: str) -> str:
    value = str(value).strip().replace("\r", "")
    if value.startswith("sub-"):
        value = value[4:]
    return f"sub-{value}"


def normalise_session(value: str) -> str:
    value = str(value).strip().replace("\r", "")
    if value.startswith("ses-"):
        value = value[4:]
    return f"ses-{value.zfill(2)}"


def read_vpn_subjects(path: Path) -> set[str]:
    if not path.exists():
        raise FileNotFoundError(f"VPN file not found: {path}")

    subjects: set[str] = set()
    for line in path.read_text().splitlines():
        line = line.replace("\r", "").strip()
        if not line or line.startswith("#"):
            continue
        for token in line.split():
            subjects.add(normalise_subject(token))
    return subjects


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text())


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=4, ensure_ascii=False) + "\n")


def value_changed(data: dict[str, Any], key: str, value: Any) -> bool:
    return data.get(key) != value


def set_json_key(path: Path, key: str, value: Any, changes: list[str], label: str) -> None:
    data = read_json(path)
    if value_changed(data, key, value):
        data[key] = value
        write_json(path, data)
        changes.append(f"{path}: {key} -> {value!r} ({label})")


def find_session_root(bids_dir: Path, subject: str, session: str) -> Path:
    """
    Accept either:
    - a BIDS root containing sub-*/
    - a subject directory, e.g. sub-006046/
    - a session directory, e.g. ses-01/

    Return the session root: .../sub-006046/ses-01
    """
    bids_dir = bids_dir.resolve()

    candidates = [
        bids_dir / subject / session,
        bids_dir / session,
        bids_dir,
    ]

    for candidate in candidates:
        if (candidate / "func").is_dir() and (candidate / "fmap").is_dir():
            return candidate

    raise RuntimeError(
        "Could not find session root with func/ and fmap/. Tried: "
        + ", ".join(str(c) for c in candidates)
    )


def patch_output(session_root: Path, subject: str, session: str) -> dict[str, Any]:
    func_dir = session_root / "func"
    fmap_dir = session_root / "fmap"

    changes: list[str] = []
    warnings: list[str] = []

    rest_source = [REST_PHASEDIFF_ID, REST_PEPOLAR_ID]
    eat_source = EAT_PHASEDIFF_ID

    # ---------------------------------------------------------------------
    # Functional JSONs
    # ---------------------------------------------------------------------
    rest_func = sorted(func_dir.glob("*task-rest*_bold.json"))
    eat_func = sorted(func_dir.glob("*task-EAT*_bold.json")) + sorted(func_dir.glob("*task-ERT*_bold.json"))

    if not rest_func:
        warnings.append(f"No rest bold JSON found in {func_dir}")

    if not eat_func:
        warnings.append(f"No EAT/ERT bold JSON found in {func_dir}")

    for path in rest_func:
        set_json_key(path, "B0FieldSource", rest_source, changes, "rest func")

    for path in eat_func:
        set_json_key(path, "B0FieldSource", eat_source, changes, "EAT/ERT func")

    # ---------------------------------------------------------------------
    # GRE fieldmaps
    # ---------------------------------------------------------------------
    run01_fmaps = sorted(fmap_dir.glob("*run-01*.json"))
    run02_fmaps = sorted(fmap_dir.glob("*run-02*.json"))

    if not run01_fmaps:
        warnings.append(f"No run-01 GRE fmap JSONs found in {fmap_dir}")

    if not run02_fmaps:
        warnings.append(f"No run-02 GRE fmap JSONs found in {fmap_dir}")

    rest_intended = f"{session}/func/{subject}_{session}_task-rest_dir-AP_bold.nii.gz"

    # Prefer EATlong if present, otherwise use first EAT/ERT bold JSON.
    eatlong = sorted(func_dir.glob("*task-EATlong*_bold.json"))
    if eatlong:
        eat_intended = f"{session}/func/{eatlong[0].with_suffix('').with_suffix('').name}.nii.gz"
    elif eat_func:
        eat_intended = f"{session}/func/{eat_func[0].with_suffix('').with_suffix('').name}.nii.gz"
    else:
        eat_intended = f"{session}/func/{subject}_{session}_task-EATlong_dir-AP_bold.nii.gz"

    for path in run01_fmaps:
        data = read_json(path)
        changed = False
        if data.get("B0FieldIdentifier") != REST_PHASEDIFF_ID:
            data["B0FieldIdentifier"] = REST_PHASEDIFF_ID
            changed = True
        if data.get("IntendedFor") != rest_intended:
            data["IntendedFor"] = rest_intended
            changed = True
        if changed:
            write_json(path, data)
            changes.append(f"{path}: run-01 -> rest GRE ({REST_PHASEDIFF_ID})")

    for path in run02_fmaps:
        data = read_json(path)
        changed = False
        if data.get("B0FieldIdentifier") != EAT_PHASEDIFF_ID:
            data["B0FieldIdentifier"] = EAT_PHASEDIFF_ID
            changed = True
        if data.get("IntendedFor") != eat_intended:
            data["IntendedFor"] = eat_intended
            changed = True
        if changed:
            write_json(path, data)
            changes.append(f"{path}: run-02 -> EAT GRE ({EAT_PHASEDIFF_ID})")

    # ---------------------------------------------------------------------
    # PA fieldmap for rest
    # This special case uses the existing non-hyphen identifier pepolar_fmap0_ses01.
    # Exclude DWI PA files such as acq-DGD006.
    # ---------------------------------------------------------------------
    pa_candidates = sorted(fmap_dir.glob("*acq-tasksall_dir-PA_epi.json")) + sorted(
        fmap_dir.glob("*acq-rest_dir-PA_epi.json")
    )

    if not pa_candidates:
        warnings.append(
            "No rest/tasksall PA epi fmap found. Rest B0FieldSource will reference "
            f"{REST_PEPOLAR_ID}, but no matching PA fmap was patched."
        )

    for path in pa_candidates:
        data = read_json(path)
        changed = False
        if data.get("B0FieldIdentifier") != REST_PEPOLAR_ID:
            data["B0FieldIdentifier"] = REST_PEPOLAR_ID
            changed = True
        if data.get("IntendedFor") != rest_intended:
            data["IntendedFor"] = rest_intended
            changed = True
        if changed:
            write_json(path, data)
            changes.append(f"{path}: PA -> rest pepolar ({REST_PEPOLAR_ID})")

    return {
        "patched": True,
        "session_root": str(session_root),
        "rest_source": rest_source,
        "eat_source": eat_source,
        "rest_intended": rest_intended,
        "eat_intended": eat_intended,
        "n_changes": len(changes),
        "changes": changes,
        "warnings": warnings,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bids-dir", required=True, type=Path)
    parser.add_argument("--vpn-file", required=True, type=Path)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--session", required=True)
    parser.add_argument("--out-report", default="b0field_output_patch_report.json", type=Path)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Fail if expected rest/EAT/run-01/run-02 files are missing.",
    )

    args = parser.parse_args()

    subject = normalise_subject(args.subject)
    session = normalise_session(args.session)
    vpn_subjects = read_vpn_subjects(args.vpn_file)

    report: dict[str, Any] = {
        "subject": subject,
        "session": session,
        "patched": False,
    }

    if subject not in vpn_subjects:
        report["reason"] = "subject not in VPN file"
        write_json(args.out_report, report)
        print(f"[B0FIELD_OUTPUT_PATCH] {subject}: not in VPN file, unchanged")
        return

    session_root = find_session_root(args.bids_dir, subject, session)
    patch_report = patch_output(session_root, subject, session)

    report.update(patch_report)
    write_json(args.out_report, report)

    print(f"[B0FIELD_OUTPUT_PATCH] {subject} {session}: patched {report['n_changes']} JSON fields")
    for warning in report.get("warnings", []):
        print(f"[B0FIELD_OUTPUT_PATCH] WARNING: {warning}")

    if args.strict and report.get("warnings"):
        raise RuntimeError("Strict mode enabled and warnings occurred. See patch report.")


if __name__ == "__main__":
    main()
