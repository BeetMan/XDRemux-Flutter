#!/usr/bin/env python3
"""Cross-implementation conformance driver for XDRemux.

Walks a directory of HEIC source samples, runs the inspect subcommand for
Tier 1+2, converts them with each implementation, and runs the dump
subcommand for Tier 3 structural comparison.

Usage:
    python3 tests/conformance/driver.py \
        --sample-dir ../example \
        --glob 'IMG20260*.heic' \
        --out-report conformance_report.md
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parents[1]


@dataclass
class Implementation:
    name: str
    inspect_cmd: list[str]
    convert_cmd: list[str] = field(default_factory=list)
    dump_cmd: list[str] = field(default_factory=list)
    skip_reason: Optional[str] = None


def find_rust_bin() -> Path:
    candidates = [
        PROJECT_ROOT / "target" / "debug" / "xdremux-conformance",
        PROJECT_ROOT / "target" / "release" / "xdremux-conformance",
    ]
    for c in candidates:
        if c.exists():
            return c
    print("Rust binary not found; running `cargo build` ...", file=sys.stderr)
    subprocess.run(
        ["cargo", "build", "-p", "xdremux-conformance"],
        cwd=PROJECT_ROOT,
        check=True,
    )
    return candidates[0]


def discover_implementations(rust_bin: Path) -> list[Implementation]:
    return [
        Implementation(
            name="rust",
            inspect_cmd=[str(rust_bin), "inspect", "__INPUT__", "__OUTPUT__"],
            convert_cmd=[str(rust_bin), "convert", "__INPUT__", "__OUTPUT__"],
            dump_cmd=[str(rust_bin), "dump", "__INPUT__", "__OUTPUT__"],
        ),
        Implementation(
            name="python",
            inspect_cmd=[
                sys.executable, "-m", "xdremux.python.conformance.inspect_heic",
                "__INPUT__", "__OUTPUT__",
            ],
            convert_cmd=[
                sys.executable, "-m", "xdremux.python.XDRemux", "convert",
                "--input", "__INPUT__", "--output", "__OUTPUT__",
            ],
            dump_cmd=[
                sys.executable, "-m", "xdremux.python.conformance.dump_heic",
                "__INPUT__", "__OUTPUT__",
            ],
        ),
    ]


def run_cmd(cmd: list[str], cwd: Path, timeout: int = 120) -> tuple[bool, str]:
    """Run a command. Returns (success, error_message)."""
    if not cmd:
        return False, "no command"
    try:
        result = subprocess.run(cmd, capture_output=True, text=True,
                                timeout=timeout, cwd=str(cwd))
    except subprocess.TimeoutExpired:
        return False, "timeout"
    except FileNotFoundError as e:
        return False, f"binary not found: {e}"
    if result.returncode != 0:
        err = result.stderr.strip()[:200] or result.stdout.strip()[:200]
        return False, f"exit={result.returncode} {err}"
    return True, ""


def subst_cmd(cmd: list[str], input_path: Path, output_path: Path) -> list[str]:
    return [a.replace("__INPUT__", str(input_path)).replace("__OUTPUT__", str(output_path))
            for a in cmd]


def is_source_sample(p: Path) -> bool:
    """Filter out converted variants like *_py.heic, *_final.heic, *_oppo.heic."""
    name = p.stem  # without .heic
    return not any(name.endswith(s) for s in ("_py", "_final", "_oppo", "_out"))


def discover_samples(sample_dir: Path, glob: str) -> list[Path]:
    if not sample_dir.is_dir():
        raise SystemExit(f"sample-dir does not exist: {sample_dir}")
    all_samples = sorted(sample_dir.glob(glob))
    return [s for s in all_samples if is_source_sample(s)]


def run_inspect(impl: Implementation, input_path: Path, output_path: Path,
                cwd: Path) -> tuple[bool, str]:
    cmd = subst_cmd(impl.inspect_cmd, input_path, output_path)
    return run_cmd(cmd, cwd)


def run_convert(impl: Implementation, input_path: Path, output_path: Path,
                cwd: Path) -> tuple[bool, str]:
    cmd = subst_cmd(impl.convert_cmd, input_path, output_path)
    return run_cmd(cmd, cwd)


def run_dump(impl: Implementation, input_path: Path, output_path: Path,
             cwd: Path) -> tuple[bool, str]:
    cmd = subst_cmd(impl.dump_cmd, input_path, output_path)
    return run_cmd(cmd, cwd)


def compare_inspect(compare_bin: Path, a_json: dict, b_json: dict, tmpdir: Path) -> dict:
    a = tmpdir / "a.json"
    b = tmpdir / "b.json"
    a.write_text(json.dumps(a_json), encoding="utf-8")
    b.write_text(json.dumps(b_json), encoding="utf-8")
    ok, err = run_cmd(
        [str(compare_bin), "compare", str(a), str(b)],
        PROJECT_ROOT, timeout=30,
    )
    if not ok:
        return {"tier1_pass": False, "tier2_pass": False, "xmp_pass": False,
                "report": err}
    # We need to read the report from stdout. The run_cmd won't capture it
    # because the compare exits non-zero on diffs, so we can't use run_cmd.
    # Let's call subprocess directly.
    try:
        result = subprocess.run(
            [str(compare_bin), "compare", str(a), str(b)],
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"tier1_pass": False, "tier2_pass": False, "xmp_pass": False,
                "report": "(timeout)"}
    report = result.stdout
    tier1_pass = "differences: 0" in report
    return {
        "tier1_pass": tier1_pass,
        "tier2_pass": tier1_pass,
        "xmp_pass": tier1_pass,
        "report": report,
    }


def compare_dump(compare_bin: Path, a_json: dict, b_json: dict, tmpdir: Path) -> dict:
    a = tmpdir / "da.json"
    b = tmpdir / "db.json"
    a.write_text(json.dumps(a_json), encoding="utf-8")
    b.write_text(json.dumps(b_json), encoding="utf-8")
    try:
        result = subprocess.run(
            [str(compare_bin), "compare-dump", str(a), str(b)],
            capture_output=True, text=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return {"tier3_pass": False, "report": "(timeout)"}
    report = result.stdout
    tier3_pass = "✓ All structural elements match!" in report
    return {"tier3_pass": tier3_pass, "report": report}


def write_report(report_path: Path, samples: list[Path], impls: list[Implementation],
                 results: dict) -> None:
    with report_path.open("w", encoding="utf-8") as f:
        f.write("# XDRemux Conformance Report\n\n")
        f.write("## Implementations\n\n")
        for impl in impls:
            note = f" — {impl.skip_reason}" if impl.skip_reason else ""
            f.write(f"- **{impl.name}**{note}\n")
        f.write(f"\n## Samples ({len(samples)})\n\n")

        f.write("\n## Tier 1+2: Source File Inspect\n\n")
        f.write("| Sample | Implementation | Tier 1 | Tier 2 | XMP | Notes |\n")
        f.write("|---|---|---|---|---|---|\n")
        for sample in samples:
            for impl in impls:
                r = results[str(sample)].get("inspect", {}).get(impl.name, {})
                tier1 = tier2 = xmp = "—"
                notes = r.get("msg", "")
                if r.get("ok"):
                    cmp = r.get("compare", {})
                    tier1 = "pass" if cmp.get("tier1_pass") else "FAIL"
                    tier2 = "pass" if cmp.get("tier2_pass") else "FAIL"
                    xmp = "pass" if cmp.get("xmp_pass") else "FAIL"
                f.write(f"| {sample.name} | {impl.name} | {tier1} | {tier2} | {xmp} | {notes} |\n")

        f.write("\n## Tier 3: Output ISOBMFF Structure\n\n")
        f.write("| Sample | Implementation | Struct | Output Size | Notes |\n")
        f.write("|---|---|---|---|---|\n")
        for sample in samples:
            for impl in impls:
                r = results[str(sample)].get("dump", {}).get(impl.name, {})
                struct = os_size = "—"
                notes = r.get("msg", "")
                if r.get("ok"):
                    cmp = r.get("compare", {})
                    struct = "pass" if cmp.get("tier3_pass") else "diff"
                    os_size = f"{r.get('file_size', 0):,} B"
                f.write(f"| {sample.name} | {impl.name} | {struct} | {os_size} | {notes} |\n")

        f.write("\n## Detail: Tier 1+2\n\n")
        for sample in samples:
            f.write(f"### {sample.name} (source)\n\n")
            for impl in impls:
                r = results[str(sample)].get("inspect", {}).get(impl.name, {})
                f.write(f"- **{impl.name}**: ")
                if r.get("ok"):
                    cmp = r.get("compare", {})
                    if cmp.get("report"):
                        f.write("\n\n```\n" + cmp["report"] + "```\n\n")
                    else:
                        f.write("(no compare report)\n\n")
                else:
                    f.write(f"FAIL — {r.get('msg', 'unknown')}\n\n")

        f.write("\n## Detail: Tier 3\n\n")
        for sample in samples:
            f.write(f"### {sample.name} (output)\n\n")
            for impl in impls:
                r = results[str(sample)].get("dump", {}).get(impl.name, {})
                f.write(f"- **{impl.name}**: ")
                if r.get("ok"):
                    cmp = r.get("compare", {})
                    if cmp.get("report"):
                        f.write("\n\n```\n" + cmp["report"] + "```\n\n")
                    else:
                        f.write("(no compare report)\n\n")
                else:
                    f.write(f"FAIL — {r.get('msg', 'unknown')}\n\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sample-dir", required=True, type=Path,
                    help="Directory containing HEIC source samples.")
    ap.add_argument("--glob", default="*.heic",
                    help="Glob pattern within sample-dir.")
    ap.add_argument("--out-report", type=Path, default=Path("conformance_report.md"),
                    help="Path to write the Markdown report.")
    ap.add_argument("--compare-bin", type=Path, default=None,
                    help="Path to xdremux-conformance binary.")
    ap.add_argument("--skip-convert", action="store_true",
                    help="Skip Tier 3 conversion (only run inspect).")
    args = ap.parse_args()

    rust_bin = find_rust_bin()
    compare_bin = args.compare_bin or rust_bin
    impls = discover_implementations(rust_bin)
    samples = discover_samples(args.sample_dir, args.glob)
    if not samples:
        print(f"no source samples matched in {args.sample_dir}", file=sys.stderr)
        return 1

    results: dict[str, dict] = {}
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        for sample in samples:
            results[str(sample)] = {"inspect": {}, "dump": {}}

            # ── Tier 1+2: Inspect source files ──
            for impl in impls:
                out_path = tmpdir / f"{sample.stem}.inspect.{impl.name}.json"
                ok, err = run_inspect(impl, sample, out_path, PROJECT_ROOT)
                rec = {"ok": ok, "msg": err}
                if ok:
                    try:
                        rec["json"] = json.loads(out_path.read_text())
                    except json.JSONDecodeError as e:
                        rec["ok"] = False
                        rec["msg"] = f"invalid JSON: {e}"
                results[str(sample)]["inspect"][impl.name] = rec

            active = [i for i in impls if results[str(sample)]["inspect"]
                      .get(i.name, {}).get("ok")]
            if len(active) >= 2:
                a_name, b_name = active[0].name, active[1].name
                cmp = compare_inspect(
                    compare_bin,
                    results[str(sample)]["inspect"][a_name]["json"],
                    results[str(sample)]["inspect"][b_name]["json"],
                    tmpdir,
                )
                results[str(sample)]["inspect"][a_name]["compare"] = cmp
                results[str(sample)]["inspect"][b_name]["compare"] = cmp

            # ── Tier 3: Convert + Dump ──
            if args.skip_convert:
                continue
            for impl in impls:
                if not impl.convert_cmd:
                    continue
                heic_out = tmpdir / f"{sample.stem}.{impl.name}.heic"
                ok, err = run_convert(impl, sample, heic_out, PROJECT_ROOT)
                if not ok:
                    results[str(sample)]["dump"][impl.name] = {"ok": False, "msg": err}
                    continue

                dump_path = tmpdir / f"{sample.stem}.dump.{impl.name}.json"
                ok, err = run_dump(impl, heic_out, dump_path, PROJECT_ROOT)
                rec = {"ok": ok, "msg": err,
                       "file_size": heic_out.stat().st_size if heic_out.exists() else 0}
                if ok:
                    try:
                        rec["json"] = json.loads(dump_path.read_text())
                    except json.JSONDecodeError as e:
                        rec["ok"] = False
                        rec["msg"] = f"invalid JSON: {e}"
                results[str(sample)]["dump"][impl.name] = rec

            active = [i for i in impls if results[str(sample)]["dump"]
                      .get(i.name, {}).get("ok")]
            if len(active) >= 2:
                a_name, b_name = active[0].name, active[1].name
                cmp = compare_dump(
                    compare_bin,
                    results[str(sample)]["dump"][a_name]["json"],
                    results[str(sample)]["dump"][b_name]["json"],
                    tmpdir,
                )
                results[str(sample)]["dump"][a_name]["compare"] = cmp
                results[str(sample)]["dump"][b_name]["compare"] = cmp

    args.out_report.parent.mkdir(parents=True, exist_ok=True)
    write_report(args.out_report, samples, impls, results)
    print(f"wrote {args.out_report}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
