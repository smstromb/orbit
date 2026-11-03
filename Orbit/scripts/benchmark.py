#!/usr/bin/env python3
"""Rerunnable scanner A/B benchmark. Scan data is kept only in temporary files."""
import argparse
import json
import pathlib
import resource
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument("folder", type=pathlib.Path)
parser.add_argument("--baseline", type=pathlib.Path)
parser.add_argument("--workers", default="1,4,8,12")
args = parser.parse_args()
project = pathlib.Path(__file__).resolve().parents[1]
binary = project / "scanner/target/release/orbit-scan"
runs = []
if args.baseline:
    runs.append(("original", args.baseline, []))
runs += [(f"bulk/{count}", binary, ["--workers", count]) for count in args.workers.split(",")]
for label, executable, options in runs:
    cpu_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    start = time.monotonic()
    with tempfile.TemporaryFile() as output:
        subprocess.run([executable, args.folder, *options], stdout=output, check=True)
        wall = time.monotonic() - start
        output.seek(0)
        for line in output:
            if line.startswith(b'{"type":"result"'):
                result = json.loads(line)
                root = result["nodes"][0]
                cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
                cpu_seconds = cpu.ru_utime + cpu.ru_stime - cpu_before.ru_utime - cpu_before.ru_stime
                print(json.dumps({"run": label, "wall_seconds": round(wall, 3),
                    "scan_seconds": round(result["elapsed"], 3), "cpu_seconds": round(cpu_seconds, 3),
                    "average_cpu_percent": round(cpu_seconds / wall * 100), "nodes": len(result["nodes"]),
                    "files": root["files"], "logical": root["logical"], "allocated": root["allocated"],
                    "issues": root["issues"], "output_mb": round(len(line) / 1e6, 2)}), flush=True)
