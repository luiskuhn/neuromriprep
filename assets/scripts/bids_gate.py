#!/usr/bin/env python3

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List, Any, Optional, Tuple

ISSUE_RE = re.compile(r"\[(WARNING|ERROR)\]\s+([A-Z0-9_]+)\b(.*)")
FILELINE_RE = re.compile(r"^\s*(/[^ \t]+)") 

def split_codes_line(line: str) -> Optional[str]:
    # Allow "WARNING:CODE" or just "CODE"
    s = line.strip()
    if not s or s.startswith("#"):
        return None
    s = s.split("#", 1)[0].strip()
    if not s:
        return None
    if ":" in s:
        left, right = s.split(":", 1)
        # If it's WARNING:CODE, keep CODE
        if left.strip().upper() in {"WARNING", "ERROR"}:
            return right.strip()
    return s

def load_allowlisted_warnings(path: Optional[str]) -> Tuple[Path, set]:
    if not path:
        # default: empty allowlist => all warnings fail
        p = Path("warnings_ok.txt").resolve()
        return p, set()
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"Allowlist file not found: {p}")
    codes = set()
    for line in p.read_text(errors="replace").splitlines():
        code = split_codes_line(line)
        if code:
            codes.add(code)
    return p, codes

def load_helpers(path: Optional[str]) -> Dict[str, str]:
    if not path:
        return {}
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"Helpers file not found: {p}")

    # Support JSON mapping or TSV-like mapping
    if p.suffix.lower() == ".json":
        obj = json.loads(p.read_text(errors="replace"))
        if isinstance(obj, dict):
            return {str(k).strip(): str(v).strip() for k, v in obj.items()}
        raise ValueError("Helpers JSON must be an object mapping CODE -> help text")

    helpers: Dict[str, str] = {}
    for line in p.read_text(errors="replace").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # TSV preferred; fall back to splitting on first whitespace
        if "\t" in s:
            code, msg = s.split("\t", 1)
        else:
            parts = s.split(None, 1)
            if len(parts) == 1:
                continue
            code, msg = parts[0], parts[1]
        code = code.strip()
        msg = msg.strip()
        if code and msg:
            helpers[code] = msg
    return helpers

def parse_log(text: str) -> List[Dict[str, Any]]:
    issues: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None

    def flush():
        nonlocal cur
        if cur:
            cur["files"] = sorted(set(cur["files"]))
            cur["message"] = cur["message"].strip()
            issues.append(cur)
            cur = None

    for raw in text.splitlines():
        line = raw.rstrip("\n")

        m = ISSUE_RE.search(line)
        if m:
            flush()
            severity, code, rest = m.group(1), m.group(2), (m.group(3) or "").strip()
            cur = {
                "severity": severity,
                "code": code,
                "message": rest,
                "files": [],
                "raw": [line],
            }
            continue

        if cur is None:
            continue

        cur["raw"].append(line)

        s = line.strip()
        fm = FILELINE_RE.match(s)
        if fm:
            cur["files"].append(fm.group(1))
        else:
            # keep extra context lines (but skip generic "Please visit ..." noise)
            if s and not s.startswith("Please visit") and not s.startswith("See Section"):
                cur["message"] += ("\n" + s)

    flush()
    return issues

def group_by_code(items: List[Dict[str, Any]]) -> Dict[str, List[Dict[str, Any]]]:
    g: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for it in items:
        g[it["code"]].append(it)
    return g

def short_msg(it: Dict[str, Any]) -> str:
    # first line only
    msg = (it.get("message") or "").strip().splitlines()[0] if it.get("message") else ""
    return msg

def render_group(
    severity: str,
    code: str,
    items: List[Dict[str, Any]],
    helpers: Dict[str, str],
    max_files: int = 8,
) -> str:
    n = len(items)
    # gather files across occurrences
    files = []
    for it in items:
        files.extend(it.get("files", []))
    files = sorted(set(files))
    files_preview = files[:max_files]
    more = f" (+{len(files)-len(files_preview)} more)" if len(files) > len(files_preview) else ""
    help_msg = helpers.get(code)

    out = []
    out.append(f"- [{severity}] {code} (occurrences: {n}, files: {len(files)})")
    first = short_msg(items[0])
    if first:
        out.append(f"  {first}")
    if files_preview:
        out.append("  Files:")
        for f in files_preview:
            out.append(f"    - {f}")
        if more:
            out.append(f"    {more}")
    if help_msg:
        out.append(f"  Help: {help_msg}")
    return "\n".join(out)

def main() -> int:
    ap = argparse.ArgumentParser(description="Gate BIDS Validator output: fail on ERROR and on non-allowlisted WARNINGs.")
    ap.add_argument("--log", required=True, help="Path to bids-validator stdout/stderr log")
    ap.add_argument("--allow-warnings", required=True, help="File listing WARNING codes that are OK (allowlist). All other warnings fail.")
    ap.add_argument("--helpers", default=None, help="Optional file mapping CODE -> help message (TSV or JSON).")
    ap.add_argument("--json-out", default="bids_qc_report.json", help="Write JSON report to this path")
    ap.add_argument("--summary-out", default="bids_qc_summary.txt", help="Write human summary to this path")
    ap.add_argument("--max-files", type=int, default=8, help="Max file paths to print per code")
    args = ap.parse_args()

    log_path = Path(args.log).expanduser().resolve()
    if not log_path.exists():
        print(f"[bids-gate] ERROR: log not found: {log_path}", file=sys.stderr)
        return 2

    allow_path, allow_codes = load_allowlisted_warnings(args.allow_warnings)
    helpers = load_helpers(args.helpers)

    text = log_path.read_text(errors="replace")
    issues = parse_log(text)

    errors = [x for x in issues if x["severity"] == "ERROR"]
    warnings = [x for x in issues if x["severity"] == "WARNING"]

    warnings_skipped = [w for w in warnings if w["code"] in allow_codes]
    warnings_attention = [w for w in warnings if w["code"] not in allow_codes]

    unique_errors = sorted(set(x["code"] for x in errors))
    unique_warnings = sorted(set(x["code"] for x in warnings))

    counts = {
        "errors": len(errors),
        "warnings": len(warnings),
        "warnings_skipped_due_to_unimportant": len(warnings_skipped),
        "warnings_need_attention": len(warnings_attention),
        "unique_errors": len(unique_errors),
        "unique_warnings": len(unique_warnings),
    }

    failing = errors + warnings_attention
    check_passed = (len(failing) == 0)

    # Build human summary
    summary_lines: List[str] = []
    summary_lines.append("[bids-gate] BIDS Validator Quality Gate")
    summary_lines.append(f"[bids-gate] Log: {log_path}")
    summary_lines.append(f"[bids-gate] Allowlist (warnings OK): {allow_path}")
    if args.helpers:
        summary_lines.append(f"[bids-gate] Helpers: {Path(args.helpers).expanduser().resolve()}")
    summary_lines.append("")
    summary_lines.append("[bids-gate] Counts:")
    for k, v in counts.items():
        summary_lines.append(f"  - {k}: {v}")
    summary_lines.append(f"  - check_passed: {check_passed}")

    # Always print skipped warnings (short form) for transparency
    summary_lines.append("")
    summary_lines.append("[bids-gate] Warnings marked OK by allowlist (skipped):")
    if warnings_skipped:
        g = group_by_code(warnings_skipped)
        for code in sorted(g.keys()):
            items = g[code]
            summary_lines.append(f"  - {code} (occurrences: {len(items)})")
    else:
        summary_lines.append("  (none)")

    # Issues that cause failure: errors + attention warnings
    summary_lines.append("")
    summary_lines.append("[bids-gate] Issues requiring attention (cause workflow to stop):")
    if failing:
        if errors:
            summary_lines.append("Errors:")
            gE = group_by_code(errors)
            for code in sorted(gE.keys()):
                summary_lines.append(render_group("ERROR", code, gE[code], helpers, max_files=args.max_files))
        if warnings_attention:
            summary_lines.append("")
            summary_lines.append("Warnings:")
            gW = group_by_code(warnings_attention)
            for code in sorted(gW.keys()):
                summary_lines.append(render_group("WARNING", code, gW[code], helpers, max_files=args.max_files))
    else:
        summary_lines.append("  (none)")

    summary_text = "\n".join(summary_lines).rstrip() + "\n"
    Path(args.summary_out).write_text(summary_text)

    # JSON report (full detail)
    report = {
        "log": str(log_path),
        "allowlist": str(allow_path),
        "helpers": str(Path(args.helpers).expanduser().resolve()) if args.helpers else None,
        "check_passed": check_passed,
        "counts": counts,
        "unique": {
            "errors": unique_errors,
            "warnings": unique_warnings,
        },
        "skipped_warnings": warnings_skipped,
        "attention_warnings": warnings_attention,
        "errors": errors,
    }
    Path(args.json_out).write_text(json.dumps(report, indent=2))

    # Exit: fail if any error or any non-allowlisted warning
    return 0 if check_passed else 0

if __name__ == "__main__":
    raise SystemExit(main())

