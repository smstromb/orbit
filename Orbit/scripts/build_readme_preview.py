#!/usr/bin/env python3
"""Build the real UI with synthetic scan/volume data for README screenshots.

Run build.sh first. The separate preview bundle never reads user folders.
The installed app and production sources remain unchanged.
"""
import json
import pathlib
import plistlib
import shutil
import subprocess

project = pathlib.Path(__file__).resolve().parents[1]
build = project / "build"
preview = build / "Orbit Preview.app"
if preview.exists():
    shutil.rmtree(preview)
shutil.copytree(build / "Orbit.app", preview)
info_path = preview / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleIdentifier"] = "local.orbit.readme-preview"
info["CFBundleDisplayName"] = "Orbit Preview"
info_path.write_bytes(plistlib.dumps(info))

# Same UI and stream decoder; only the scanner input and volume reader are fixtures.
nodes = []
categories = [
    ("Projects", 180, ["Workspaces", "Dependencies", "Build output", "Tools"]),
    ("Photos", 132, ["Photo library", "RAW originals", "Exports", "Albums"]),
    ("Media", 96, ["Video projects", "Recordings", "Music", "Podcasts"]),
    ("Applications", 76, ["Creative tools", "Developer tools", "Productivity", "Utilities"]),
    ("Archives", 54, ["Backups", "Project bundles", "Installers", "Disk images"]),
    ("Documents", 32, ["Design files", "Research", "Writing", "Reference"]),
    ("Downloads", 26, ["Packages", "Images", "Videos", "Other files"]),
    ("Library", 24, ["Application support", "Caches", "Containers", "Logs"]),
]

def node(name, parent, amount, depth, children=None, seed=1):
    index = len(nodes)
    current = dict(name=name, parent=parent, logical=amount, allocated=amount,
                   kind="folder" if depth < 4 else "file", files=0, folders=0, issues=0)
    nodes.append(current)
    if depth == 4:
        current["files"] = 1
        return index
    names = children or (["Assets", "Packages", "Sources", "Resources", "Cache"] if depth == 2 else
                         [f"Sample {n + 1:02d}" for n in range(3 + seed % 7)])
    weights = [max(1, 13 - i * 2 + (seed + i) % 4) for i in range(len(names))]
    used = 0
    for i, (title, weight) in enumerate(zip(names, weights)):
        share = amount - used if i == len(names) - 1 else amount * weight // sum(weights)
        used += share
        child = node(title, index, share, depth + 1, seed=seed * 3 + i)
        current["files"] += nodes[child]["files"]
        current["folders"] += nodes[child]["folders"] + (nodes[child]["kind"] == "folder")
    return index

nodes.append(dict(name="Sample disk", parent=None, logical=620_000_000_000, allocated=620_000_000_000,
                  kind="folder", files=0, folders=0, issues=0))
for rank, (name, gb, children) in enumerate(categories):
    child = node(name, 0, gb * 1_000_000_000, 1, children, seed=rank + 1)
    nodes[0]["files"] += nodes[child]["files"]
    nodes[0]["folders"] += nodes[child]["folders"] + 1
assert sum(nodes[i]["allocated"] for i in range(1, len(nodes)) if nodes[i]["parent"] == 0) == nodes[0]["allocated"]
fixture = dict(type="result", root="/Sample disk", elapsed=1.2, workers=8, engine="sample", nodes=nodes)
helper = preview / "Contents/MacOS/orbit-scan"
helper.write_text("#!/usr/bin/env python3\nimport sys\nsys.stdout.write(" + repr(json.dumps(fixture, separators=(",", ":")) + "\n") + ")\n")
helper.chmod(0o755)

source = (project / "Sources/DiskSpace.swift").read_text()
original = '''        let values = try FileManager.default.attributesOfFileSystem(forPath: path)
        guard let total = values[.systemSize] as? NSNumber, let free = values[.systemFreeSize] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return try DiskSpace(capacity: total.uint64Value, free: free.uint64Value)'''
assert source.count(original) == 1, "Update the preview volume fixture for the current reader"
volume = build / "PreviewDiskSpace.swift"
volume.write_text(source.replace(original, "        return try DiskSpace(capacity: 1_000_000_000_000, free: 380_000_000_000)"))
subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
    "-module-cache-path", str(build / "module-cache"),
    *[str(project / "Sources" / name) for name in ["Orbit.swift", "ScanWire.swift", "Worktrees.swift", "WorktreeView.swift"]],
    str(volume), "-o", str(preview / "Contents/MacOS/Orbit"), "-framework", "SwiftUI", "-framework", "AppKit"], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(preview)], check=True)
print(preview)
