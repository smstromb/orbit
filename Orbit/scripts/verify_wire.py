#!/usr/bin/env python3
"""Check the actual Swift stream reader against both scanner wire formats."""
import json
import pathlib
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
scanner = project / "build/Orbit.app/Contents/MacOS/orbit-scan"
decoder = project / "build/verify-wire"
subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", project / "build/module-cache",
    project / "Sources/ScanWire.swift", project / "scripts/verify_wire.swift", "-o", decoder], check=True)

with tempfile.TemporaryDirectory(prefix="orbit-wire-") as folder:
    root = pathlib.Path(folder)
    fixture = root / "input"
    fixture.mkdir()
    for i in range(24):
        child = fixture / f"folder-{i}"
        child.mkdir()
        for j in range(120):
            (child / f'日本語\n"{j}.txt').write_bytes(b"1234567")
    binary = root / "binary.dat"
    reference = root / "reference.dat"
    for target, flags in [(binary, ["--binary", "--workers", "12"]), (reference, ["--workers", "1"])]:
        with target.open("wb") as out:
            subprocess.run([scanner, fixture, *flags], stdout=out, check=True)
    decoded = json.loads(subprocess.check_output([decoder, binary, reference], text=True))
    assert decoded["files"] == 2880
    assert decoded["logical"] == 20160
    assert decoded["nodes"] == 2905
    assert binary.stat().st_size < reference.stat().st_size * 0.6

    # A writer that fragments every field across pipe reads must decode identically.
    producer = subprocess.Popen(["python3", "-c", "import sys,time; d=open(sys.argv[1],'rb').read();\nfor i in range(0,len(d),19): sys.stdout.buffer.write(d[i:i+19]); sys.stdout.buffer.flush()", binary], stdout=subprocess.PIPE)
    # /dev/stdin gives the same FileHandle stream reader used by the app.
    fragmented = subprocess.run([decoder, "/dev/stdin", reference], stdin=producer.stdout, capture_output=True)
    producer.stdout.close()
    producer.wait(timeout=5)
    assert fragmented.returncode == 0, fragmented.stderr
    assert json.loads(fragmented.stdout)["logical"] == 20160
    for name, data in [("truncated", binary.read_bytes()[:-1]),
                       ("bad-version", binary.read_bytes().replace(b'"version":1', b'"version":9', 1))]:
        damaged = root / name
        damaged.write_bytes(data)
        result = subprocess.run([decoder, damaged], capture_output=True)
        assert result.returncode != 0, name

print("PASS: Swift binary/JSON parity, exact totals, Unicode/newline names, fragmented streaming, compact payload, and rejection of truncated/unknown-version data")
