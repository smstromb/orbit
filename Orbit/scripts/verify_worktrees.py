#!/usr/bin/env python3
"""Use real, disposable Git repositories to verify worktree discovery."""
import json
import pathlib
import os
import shutil
import subprocess
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
probe = project / "build/verify-worktrees"
subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", project / "build/module-cache",
    project / "Sources/ScanWire.swift", project / "Sources/Worktrees.swift", project / "scripts/verify_worktrees.swift", "-o", probe], check=True)

def git(root, *args):
    return subprocess.check_output(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(root), *args], stderr=subprocess.DEVNULL)

def discover(anchor, *candidates):
    result = json.loads(subprocess.check_output([probe, anchor, *candidates]))
    for entry in result["entries"]:
        entry["path"] = os.path.realpath(entry["path"])
    return result

with tempfile.TemporaryDirectory(prefix="orbit-worktree-test-") as folder:
    root = pathlib.Path(folder).resolve()
    anchor = root / "no-naming-convention"
    anchor.mkdir()
    git(anchor, "init", "-b", "main")
    git(anchor, "config", "user.name", "Orbit fixture")
    git(anchor, "config", "user.email", "fixture@example.invalid")
    (anchor / "file.txt").write_text("fixture\n")
    git(anchor, "add", "file.txt")
    git(anchor, "commit", "-m", "Fixture")
    git(anchor, "remote", "add", "origin", "git@example.invalid:Example/sample-repository.git")
    linked = root / "somewhere else" / 'checkout with spaces\nand 日本語'
    linked.parent.mkdir()
    git(anchor, "worktree", "add", "-b", "feature/example", str(linked))
    git(anchor, "worktree", "lock", "--reason", "test", str(linked))
    detached = root / "arbitrary-detached"
    git(anchor, "worktree", "add", "--detach", str(detached))
    stale = root / "removed-checkout"
    git(anchor, "worktree", "add", "-b", "stale", str(stale))
    shutil.rmtree(stale)
    initial = discover(anchor)
    entries = {entry["path"]: entry for entry in initial["entries"]}
    assert set(entries) == {str(anchor), str(linked), str(detached)}, initial
    assert entries[str(linked)]["branch"] == "feature/example"
    assert entries[str(linked)]["locked"] is True
    assert entries[str(detached)]["branch"] == "Detached HEAD"
    assert initial["unavailable"] == 1
    linked_anchor = discover(linked)
    kinds = {entry["path"]: entry["kind"] for entry in linked_anchor["entries"]}
    assert kinds[str(anchor)] == "Main checkout" and kinds[str(linked)] == "Linked worktree"
    rejected = subprocess.run([probe, anchor / "not-a-checkout"], capture_output=True)
    assert rejected.returncode != 0

    clone = root / "a-clone-with-another-name"
    git(root, "clone", "--shared", str(anchor), str(clone))
    git(clone, "remote", "set-url", "origin", "https://example.invalid/Example/sample-repository.git")
    clone_linked = root / "off-in-a-different-place"
    git(clone, "worktree", "add", "-b", "another/branch", str(clone_linked))
    wrong = root / "sample-repository-but-wrong-repo"
    git(root, "clone", "--shared", str(anchor), str(wrong))
    git(wrong, "remote", "set-url", "origin", "git@example.invalid:somebody-else/sample-repository.git")
    # Selecting a different repository changes the matching target.
    other_target = discover(wrong, anchor, clone)
    assert {entry["path"] for entry in other_target["entries"]} == {str(wrong)}
    case_distinct = root / "different-case-repository"
    git(root, "clone", "--shared", str(anchor), str(case_distinct))
    git(case_distinct, "remote", "set-url", "origin", "git@example.invalid:example/sample-repository.git")
    lookalike = root / "looks-like-a-repo"
    (lookalike / ".git").mkdir(parents=True)
    alias = root / "alias-to-linked"
    alias.symlink_to(linked)
    found = discover(anchor, clone, wrong, case_distinct, lookalike, alias, clone)
    entries = {entry["path"]: entry for entry in found["entries"]}
    assert set(entries) == {str(anchor), str(linked), str(detached), str(clone), str(clone_linked)}
    assert entries[str(clone)]["kind"] == "Clone checkout"
    assert entries[str(clone_linked)]["kind"] == "Linked worktree"
    assert entries[str(anchor)]["kind"] == "Main checkout"
    replaced = root / "replaced-stale-registry-path"
    git(anchor, "worktree", "add", "-b", "obsolete-branch", str(replaced))
    git(anchor, "worktree", "lock", str(replaced))
    shutil.rmtree(replaced)
    git(root, "clone", "--shared", str(anchor), str(replaced))
    git(replaced, "remote", "set-url", "origin", "https://example.invalid/Example/sample-repository.git")
    replacement = {entry["path"]: entry for entry in discover(anchor)["entries"]}[str(replaced)]
    assert replacement["branch"] == "main" and replacement["locked"] is False
    assert replacement["kind"] == "Clone checkout"
    # A moved linked checkout can be discovered from its .git marker even while
    # its registry points to the previous location. Discovery must not repair it.
    moved = root / "moved-without-git-repair"
    detached.rename(moved)
    before = git(anchor, "worktree", "list", "--porcelain", "-z")
    moved_result = discover(anchor, moved)
    assert str(moved) in {entry["path"] for entry in moved_result["entries"]}
    assert before == git(anchor, "worktree", "list", "--porcelain", "-z")

print("PASS: registered paths anywhere, space/newline/Unicode paths, branches, detached and locked worktrees, missing records, independent clones and their worktrees, wrong-repo exclusion, alias deduplication, moved worktrees, and read-only Git metadata")
