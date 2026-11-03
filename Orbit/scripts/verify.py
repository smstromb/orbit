#!/usr/bin/env python3
"""Exercise the shipped Rust scanner against real filesystem fixtures."""
import json
import os
import pathlib
import subprocess
import tempfile
import shlex

project = pathlib.Path(__file__).resolve().parents[1]
scanner = pathlib.Path(os.environ.get("ORBIT_SCANNER", str(project / "build/Orbit.app/Contents/MacOS/orbit-scan")))
options = shlex.split(os.environ.get("ORBIT_SCAN_OPTIONS", ""))

def scan(path):
    records = [json.loads(line) for line in subprocess.check_output([scanner, path, *options], text=True).splitlines()]
    assert records[-1]["type"] == "result"
    return records[-1]

with tempfile.TemporaryDirectory(prefix="orbit-verification-") as folder:
    root = pathlib.Path(folder)
    (root / "nested").mkdir()
    (root / "empty").mkdir()
    (root / "a.bin").write_bytes(b"a" * 8192)
    (root / 'nested/quote" and 日本語\n.txt').write_bytes(b"hello")
    os.link(root / "a.bin", root / "hardlink.bin")
    os.symlink(root, root / "loop")
    with (root / "sparse.bin").open("wb") as file:
        file.seek(16 * 1024 * 1024)
        file.write(b"x")
    result = scan(root)
    nodes = result["nodes"]
    names = {n["name"]: n for n in nodes}
    expected = 8192 * 2 + 5 + 16 * 1024 * 1024 + 1 + os.lstat(root / "loop").st_size
    assert nodes[0]["logical"] == expected, (nodes[0], expected)
    assert nodes[0]["files"] == 5, nodes[0]
    assert nodes[0]["folders"] == 2, nodes[0]
    assert names["nested"]["logical"] == 5
    assert names["empty"]["logical"] == 0
    assert names['quote" and 日本語\n.txt']["logical"] == 5
    assert names["loop"]["kind"] == "link"
    assert len(nodes) == 8, "A symbolic link must never be traversed"
    unique_blocks = sum(os.lstat(root / p).st_blocks * 512 for p in ["a.bin", "nested/quote\" and 日本語\n.txt", "sparse.bin", "loop"])
    assert nodes[0]["allocated"] == unique_blocks, (nodes[0], unique_blocks)
    assert nodes[0]["allocated"] < nodes[0]["logical"], "Sparse data must use allocated blocks"
    for i, node in enumerate(nodes):
        if node["parent"] is not None:
            assert node["parent"] < i
    # Invalid UTF-8 names must be excluded explicitly, never mapped to a different file.
    raw = os.fsencode(root) + b"/invalid-\xff"
    try:
        fd = os.open(raw, os.O_CREAT | os.O_WRONLY, 0o600)
    except PermissionError:
        pass  # APFS itself rejects invalid UTF-8 names.
    else:
        os.close(fd)
        assert scan(root)["nodes"][0]["issues"] == 1
    bad = subprocess.run([scanner, root / "does-not-exist"], capture_output=True)
    assert bad.returncode != 0 and bad.stderr
    not_folder = subprocess.run([scanner, root / "a.bin"], capture_output=True)
    assert not_folder.returncode != 0 and b"Choose a folder" in not_folder.stderr

with tempfile.TemporaryDirectory(prefix="orbit-bulk-verification-") as folder:
    root = pathlib.Path(folder)
    for group in range(28):
        child = root / f"group-{group:02d}"
        child.mkdir()
        for item in range(100):
            (child / f"file-{item:03d}.txt").write_bytes(b"1234567")
    # This flat directory forces several getattrlistbulk buffers as well.
    flat = root / "flat"
    flat.mkdir()
    for item in range(2800):
        (flat / f"file-{item:04d}.txt").write_bytes(b"1234567")
    result = scan(root)
    assert result["nodes"][0]["files"] == 5600
    assert result["nodes"][0]["folders"] == 29
    assert result["nodes"][0]["logical"] == 39200
    assert result["nodes"][0]["issues"] == 0
    assert len(result["nodes"]) == 5630
    # Closing the consumer must not strand producers on a full result channel.
    process = subprocess.Popen([scanner, root, *options], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert json.loads(process.stdout.readline())["type"] == "progress"
    process.stdout.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        raise AssertionError("Scanner did not stop after its output pipe closed")
    assert process.returncode != 0

print("PASS: exact totals, escaped/Unicode names, empty folders, hard links, sparse files, symlink cycles, multi-buffer/multi-directory scans, broken-pipe shutdown, and error exits")
