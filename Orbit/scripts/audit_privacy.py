#!/usr/bin/env python3
"""Audit Git-visible content without printing matched personal data or secrets."""
import argparse
import hashlib
import pathlib
import re
import subprocess
import sys


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="inspect index bytes, not working files")
    parser.add_argument("--deny", action="append", default=[], help="private literal to reject, case insensitive")
    args = parser.parse_args()
    root = pathlib.Path(git("rev-parse", "--show-toplevel").decode().strip())
    import os
    os.chdir(root)
    names = git("ls-files", "-z", "--cached", *([] if args.staged else ["--others", "--exclude-standard"]))
    paths = sorted(set(p.decode("utf-8") for p in names.split(b"\0") if p))
    rules = [
        ("user-specific absolute path", re.compile(rb"(?:/Users/|/home/|[A-Za-z]:\\Users\\)[A-Za-z0-9._-]+")),
        ("private key", re.compile(rb"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----")),
        ("GitHub credential", re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})")),
        ("cloud access key", re.compile(rb"(?:AKIA|ASIA)[A-Z0-9]{16}")),
        ("service credential", re.compile(rb"(?:sk-(?:proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})")),
        ("URL with embedded credentials", re.compile(rb"[a-z][a-z0-9+.-]*://[^\s/@:]+:[^\s/@]+@", re.I)),
        ("email address", re.compile(rb"[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}")),
    ]
    denies = [value.encode().lower() for value in args.deny if value]
    failures = []
    examined = set()

    def inspect(label, data):
        for category, pattern in rules:
            for match in pattern.finditer(data):
                if category == "email address" and (match[0].lower().endswith((b".invalid", b"@example.com", b"@users.noreply.github.com", b".png"))):
                    continue
                failures.append((label, data[:match.start()].count(b"\n") + 1, category))
        for value in denies:
            at = data.lower().find(value)
            if at >= 0:
                failures.append((label, data[:at].count(b"\n") + 1, "private deny-list value"))

    # This exact sample-data screenshot was visually reviewed before publication.
    reviewed_images = {"docs/images/orbit.png": "be124685ae9fe9b72fc07b014506a753dc566d97f344750f686540d443d2e2e7"}
    allowed = {".swift", ".rs", ".py", ".sh", ".md", ".toml", ".lock"}
    for path in paths:
        inspect("file name", path.encode())
        p = pathlib.Path(path)
        if path != ".gitignore" and path not in reviewed_images and p.suffix not in allowed:
            failures.append((path, 0, "unexpected publication file type"))
        if any(part in {"build", "target", "node_modules", ".env", ".aws", ".ssh"} for part in p.parts):
            failures.append((path, 0, "local or generated data included"))
        stage = git("ls-files", "--stage", "--", path)
        if p.is_symlink() or stage.startswith((b"120000 ", b"160000 ")):
            failures.append((path, 0, "symlink or submodule requires manual audit")); continue
        data = git("show", ":" + path) if args.staged else p.read_bytes()
        if path in reviewed_images:
            if hashlib.sha256(data).hexdigest() != reviewed_images[path]:
                failures.append((path, 0, "image changed; repeat visual privacy review"))
            examined.add(data)
            continue
        if b"\0" in data:
            failures.append((path, 0, "binary data requires manual audit"))
        inspect(path, data)
        examined.add(data)

    # Audit publishable branch/tag history. App-owned local checkpoint refs are
    # not publication branches and must never be pushed with --mirror.
    objects = git("rev-list", "--objects", "--branches", "--tags", "--no-object-names").splitlines()
    for oid in objects:
        kind = git("cat-file", "-t", oid.decode()).strip()
        if kind == b"tree":
            # Inspect raw names, including files deleted before the current tip.
            for record in git("ls-tree", "-z", oid.decode()).split(b"\0"):
                if not record: continue
                header, _, name = record.partition(b"\t")
                inspect("history filename " + oid[:12].decode(), name)
                if header.startswith((b"120000 ", b"160000 ")):
                    failures.append(("history " + oid[:12].decode(), 0, "symlink or submodule requires manual audit"))
        elif kind in (b"blob", b"commit", b"tag"):
            data = git("cat-file", "-p", oid.decode())
            if kind == b"blob" and hashlib.sha256(data).hexdigest() in reviewed_images.values():
                continue
            if kind == b"blob" and b"\0" in data:
                failures.append(("history " + oid[:12].decode(), 0, "binary data requires manual audit"))
            if data not in examined:
                inspect("history " + oid[:12].decode(), data)
                examined.add(data)
    for label, line, category in sorted(set(failures)):
        encoded = label.encode()
        if any(value in encoded.lower() for value in denies) or any(pattern.search(encoded) for _, pattern in rules):
            label = "redacted-path-" + hashlib.sha256(encoded).hexdigest()[:12]
        print(f"FAIL: {label}:{line}: {category}")
    if failures:
        print("Matched values are suppressed. Review locally before publishing.")
        return 1
    print(f"PASS: {len(paths)} publication files and {len(objects)} reachable Git objects checked")
    print("No matches for the built-in rules or supplied private identifiers. Manual review is still required.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
