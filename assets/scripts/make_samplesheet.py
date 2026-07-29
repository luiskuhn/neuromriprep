#!/usr/bin/env python3

import csv
import re
import argparse
from pathlib import Path

ROOT = Path("/p/irtg")

PATH_RE = re.compile(
    r"^/p/irtg/IRTG(\d+)/\d{2}_BIDS_IRTG\1/sourcedata/IRTG\1_\d+(?:_S\d+)?(?:_b\d{8})?$"
)

def parse_projects(projects_arg):
    if not projects_arg:
        return None

    projects = []
    for p in projects_arg.split(","):
        p = p.strip()
        if not p:
            continue
        if not re.fullmatch(r"\d{2}", p):
            raise ValueError(f"Invalid project code: '{p}'. Expected format like 01,03,06")
        projects.append(p)

    return sorted(set(projects))


def find_sourcedata_dirs(root, projects=None):
    if projects is None:
        return sorted(root.glob("IRTG*/??_BIDS_IRTG*/sourcedata"))

    dirs = []
    for project in projects:
        dirs.extend(sorted(root.glob(f"IRTG{project}/??_BIDS_IRTG{project}/sourcedata")))
    return dirs


def main():
    parser = argparse.ArgumentParser(description="Generate samplesheet.csv from IRTG sourcedata folders")
    parser.add_argument(
        "--projects",
        help="Comma-separated list of 2-digit projects to include, e.g. 01 or 01,03,06. If omitted, all projects are scanned."
    )
    parser.add_argument(
        "--outfile",
        default="samplesheet.csv",
        help="Output CSV file name (default: samplesheet.csv)"
    )

    args = parser.parse_args()

    try:
        projects = parse_projects(args.projects)
    except ValueError as e:
        parser.error(str(e))

    rows = []
    sourcedata_dirs = find_sourcedata_dirs(ROOT, projects)

    if not sourcedata_dirs:
        print("No matching sourcedata directories found.")

    for sourcedata_dir in sourcedata_dirs:
        if not sourcedata_dir.is_dir():
            continue

        for subject_dir in sorted(sourcedata_dir.iterdir()):
            if not subject_dir.is_dir():
                continue

            full_path = str(subject_dir)
            m = PATH_RE.match(full_path)
            if not m:
                print(f"Skipping unexpected folder path: {full_path}")
                continue

            project = m.group(1).zfill(2)
            rows.append({
                "project": project,
                "dicom_dir": full_path
            })

    with open(args.outfile, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["project", "dicom_dir"])
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {args.outfile}")
    if projects:
        print(f"Included projects: {', '.join(projects)}")
    else:
        print("Included projects: all")


if __name__ == "__main__":
    main()