"""Read-only codec comparison. Writes reports only to a NEW external directory.

Run with the isolated pillow-heif Python environment, a freshly built Rust
codec_poc example, and Google's ultrahdr_app executable. No photos are uploaded.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import time

import pillow_heif


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def run(command, cwd):
    try:
        result = subprocess.run(command, cwd=cwd, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=90)
        return {"exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    except subprocess.TimeoutExpired:
        return {"exitCode": None, "error": "timeout after 90 seconds"}


def configurations(path):
    """Inspect hvcC records, including auxiliary images; not just the primary."""
    data = path.read_bytes()
    records = set()
    offset = 0
    while (offset := data.find(b"hvcC", offset)) != -1:
        if offset >= 4 and offset + 23 <= len(data):
            size = int.from_bytes(data[offset - 4:offset], "big")
            if 31 <= size <= len(data) - offset + 4 and data[offset + 4] == 1:
                records.add((data[offset + 20] & 3, 8 + (data[offset + 21] & 7),
                             8 + (data[offset + 22] & 7)))
        offset += 4
    return [{"chromaFormatIdc": c, "lumaBits": y, "chromaBits": uv}
            for c, y, uv in sorted(records)]


def rust_report(result):
    for line in reversed(result.get("stdout", "").splitlines()):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            pass
    return None


def metadata_comparison(stdout, floats, use_base_color_space=None):
    fields = {}
    for line in stdout.splitlines():
        match = re.fullmatch(r"--(\w+)\s+(.+)", line.strip())
        if match:
            try:
                fields[match[1]] = [float(x) for x in match[2].split()]
            except ValueError:
                continue
    if not floats or not fields:
        return {"reference": fields, "compared": False,
                "reason": "No shared metadata (Rust may synthesize an SDR identity gain map)"}
    expected = {"minContentBoost": floats[0:3], "maxContentBoost": floats[4:7],
                "gamma": floats[7:10], "offsetSdr": floats[10:13],
                "offsetHdr": floats[13:16], "hdrCapacityMin": [floats[16]],
                "hdrCapacityMax": [floats[17]]}
    if use_base_color_space is not None:
        expected["useBaseColorSpace"] = [int(use_base_color_space)]
    checks = {}
    for key, values in expected.items():
        actual = fields.get(key)
        if actual and len(actual) == 1 and len(values) == 3:
            actual = actual * 3
        checks[key] = actual is not None and len(actual) == len(values) and all(
            math.isclose(a, b, rel_tol=2e-5, abs_tol=2e-6) for a, b in zip(actual, values))
    return {"reference": fields, "compared": True, "checks": checks,
            "allMatch": all(checks.values()), "tolerance": "rel=2e-5, abs=2e-6 (CLI precision)"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rust-probe", type=Path, required=True)
    parser.add_argument("--uhdr-app", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--heif", type=Path, action="append", default=[])
    parser.add_argument("--jpeg", type=Path, action="append", default=[])
    args = parser.parse_args()
    rust = args.rust_probe.resolve(strict=True)
    uhdr = args.uhdr_app.resolve(strict=True)
    sources = [("heif", p.resolve(strict=True)) for p in args.heif] + [
        ("jpeg", p.resolve(strict=True)) for p in args.jpeg]
    if not sources or len({p for _, p in sources}) != len(sources):
        parser.error("Provide at least one input; duplicate inputs are not allowed")
    output = args.output_dir.resolve()
    if any(p == output or output in p.parents or p in output.parents for _, p in sources):
        parser.error("Output must not contain, or be nested under, an input file")
    output.mkdir(parents=True, exist_ok=False)
    report = {"pillowHeif": pillow_heif.__version__, "libheif": pillow_heif.libheif_info(),
              "rustProbeSha256": digest(rust), "uhdrAppSha256": digest(uhdr), "cases": []}
    for index, (kind, path) in enumerate(sources):
        case = {"kind": kind, "path": str(path), "sha256Before": digest(path)}
        case_dir = output / f"case-{index:02d}"
        case_dir.mkdir()
        result = run([str(rust), str(path)], case_dir)
        case["rustExecution"] = result
        case["rust"] = rust_report(result)
        if kind == "heif":
            case["hvcCRecords"] = configurations(path)
            started = time.perf_counter()
            try:
                image = pillow_heif.open_heif(path)
                pixels = image.data
                case["libheifDecode"] = {"success": True, "size": image.size,
                    "mode": image.mode, "stride": image.stride, "bytes": len(pixels),
                    "pixelsSha256": hashlib.sha256(pixels).hexdigest(),
                    "seconds": time.perf_counter() - started}
            except Exception as error:
                case["libheifDecode"] = {"success": False, "error": str(error)}
        else:
            probe = run([str(uhdr), "-m", "1", "-j", str(path), "-P"], case_dir)
            case["ultraHdrProbe"] = probe
            case["referenceHasGainmap"] = "Ultra HDR Image: Yes" in probe.get("stdout", "")
            info = (case.get("rust") or {}).get("ultraHdr", {})
            case["metadataComparison"] = metadata_comparison(probe.get("stdout", ""),
                                                              info.get("metaFloats"),
                                                              info.get("useBaseColorSpace"))
            if "Ultra HDR Image: Yes" in probe.get("stdout", ""):
                raw = case_dir / "hdr-linear-f16.raw"
                decode = run([str(uhdr), "-m", "1", "-j", str(path), "-o", "0",
                              "-O", "4", "-z", str(raw)], case_dir)
                case["ultraHdrDecode"] = decode
                if raw.exists():
                    case["hdrRawBytes"] = raw.stat().st_size
                    case["hdrRawSha256"] = digest(raw)
        case["sha256After"] = digest(path)
        case["sourceUnchanged"] = case["sha256Before"] == case["sha256After"]
        report["cases"].append(case)
        (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False),
                                             encoding="utf-8")
        print(json.dumps({"case": index, "name": path.name, "sourceUnchanged": case["sourceUnchanged"],
                          "heif": case.get("libheifDecode"),
                          "metadata": case.get("metadataComparison")}, ensure_ascii=False), flush=True)
    if not all(case["sourceUnchanged"] for case in report["cases"]):
        raise SystemExit("Input integrity check failed")


if __name__ == "__main__":
    main()
