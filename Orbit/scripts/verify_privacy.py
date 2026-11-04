#!/usr/bin/env python3
"""Exercise the publication audit using disposable Git repositories."""
import pathlib
import subprocess
import tempfile

script = pathlib.Path(__file__).with_name("audit_privacy.py").resolve()

with tempfile.TemporaryDirectory(prefix="orbit-privacy-test-") as folder:
    root = pathlib.Path(folder)

    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)

    def audit(*args, passes=True):
        result = subprocess.run(["python3", str(script), *args], cwd=root, capture_output=True, text=True)
        assert (result.returncode == 0) == passes, result.stdout + result.stderr
        return result.stdout

    git("init", "-b", "main")
    git("config", "user.name", "Orbit fixture")
    git("config", "user.email", "fixture@example.invalid")
    doc = root / "README.md"
    doc.write_text("Public source\n")
    (root / ".gitignore").write_text(".env\nbuild/\n")
    (root / ".env").write_text("private fixture\n")
    audit()
    marker = "private-fixture-identifier"
    doc.write_text(marker)
    output = audit("--deny", marker, passes=False)
    assert marker not in output, "Audit exposed the matched value"
    doc.write_text("Public source\n")
    named_secret = root / (marker + ".txt")
    named_secret.write_text("Ordinary contents\n")
    output = audit("--deny", marker, passes=False)
    assert marker not in output and "redacted-path-" in output
    named_secret.unlink()
    git("add", "README.md", ".gitignore")
    doc.write_text("private fixture\n")
    audit("--staged", "--deny", "private fixture")
    audit("--deny", "private fixture", passes=False)
    # Actual credentials are never needed to test the pattern.
    credential = "ghp_" + "A" * 36
    doc.write_text(credential)
    output = audit(passes=False)
    assert credential not in output
    doc.write_text("Public source\n")
    git("commit", "-m", "Public fixture")
    doc.write_text(marker)
    git("add", "README.md")
    git("commit", "-m", "Private fixture")
    doc.write_text("Public source\n")
    git("add", "README.md")
    git("commit", "-m", "Remove private fixture")
    output = audit("--deny", marker, passes=False)
    assert "history " in output
    private_name = "deleted-private-filename.md"
    private_file = root / private_name
    private_file.write_text("Ordinary contents\n")
    git("add", private_name)
    git("commit", "-m", "Add named fixture")
    git("rm", private_name)
    git("commit", "-m", "Remove named fixture")
    output = audit("--deny", private_name, passes=False)
    assert "history filename " in output and private_name not in output
    image = root / "docs/images/orbit.png"
    image.parent.mkdir(parents=True)
    image.write_bytes(b"\x89PNG\r\n\x1a\n" + b"unreviewed image")
    output = audit(passes=False)
    assert "image changed; repeat visual privacy review" in output
    image.unlink()
    git("add", "-f", ".env")
    audit("--staged", passes=False)

print("PASS: ignored local settings, staged bytes, private identifiers, credential detection, suppressed matches, historical contents, and deleted private filenames")
