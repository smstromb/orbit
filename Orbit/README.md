# Orbit

A personal macOS disk explorer with a Rust scanner and a native SwiftUI sunburst.

Build with `bash scripts/build.sh`, verify with `python3 scripts/verify.py`, and launch `build/Orbit.app`.
Requires Apple Silicon, macOS 14+, Xcode command-line tools, and Rust. The build script uses the existing Rust 1.95.0 toolchain without changing the machine's default. Override it with `ORBIT_RUST_TOOLCHAIN`.

The app starts by mapping `~/Library/Caches`. Choose a location in the sidebar, use Scan folder or Command-O, or drop a folder onto the window. Click a folder segment or list row to zoom. Click the center, breadcrumbs, or Command-Up to return. Command-R rescans. Clicking a file reveals it in Finder. Right-click a row to reveal, copy its path, or rescan that folder.

On disk is the default map and uses Unix block allocation and deduplicates hard links within a scan. APFS clones can share extents, so allocated totals are estimates, not reclaimable-space promises. Snapshots, purgeable space, directory blocks, and filesystem overhead are not included. Symbolic links are measured without following them. Other devices and previously visited directory inodes are excluded. Unreadable entries and unsupported non-UTF-8 names are reported. Full Disk Access can be granted manually through System Settings for protected folders.

The scanner reads metadata only. It uses macOS `getattrlistbulk` to fetch names and metadata in 256 KiB batches, with up to 12 directory workers based on the machine's available cores. Workers own their directory handles; one coordinator owns the tree and inode accounting. A bounded result channel limits buffered batches. Unsupported filesystems fall back to ordinary directory reads. An access preflight rejects unreadable directories before opening them. On whole-disk scans, `/System/Volumes` is excluded so the APFS Data alias does not claim folders that also appear at their normal paths. Long filesystem waits produce progress heartbeats with the active path.

The app has no deletion actions or network dependencies. Closing the app cancels its scanner. Results remain in memory; no scan history or telemetry is written.

To rerun the scanner benchmark, use `python3 scripts/benchmark.py ~/Library/Caches --baseline build/bench/orbit-scan-baseline`. Provide your own archived scanner executable for baseline comparisons. Use `--workers 1,4,8,12` to compare concurrency. CLI options include `--binary` for the compact app stream, `--workers N`, `--portable` for the fallback implementation, and `--summary` to omit individual nodes in benchmark output. The verification script accepts `ORBIT_SCANNER` and `ORBIT_SCAN_OPTIONS` to test a candidate binary or worker count without modifying the installed app.

Visual design: a charcoal workspace, a single large radial map, restrained lavender controls, and a fixed contents inspector. Folder families retain their colors while zooming. A Canvas interpolates arc geometry during navigation, with reduced-motion support. Scanning, decoding, and chart layout run outside the main thread. Tiny sectors are grouped to limit drawing work.

The GUI uses a versioned binary stream with a small JSON header and fixed 31-byte little-endian record headers plus UTF-8 names. Swift decodes records incrementally and reconstructs counts from parent links. This avoids retaining a full encoded copy of the tree. Run `python3 scripts/verify_wire.py` to compile and exercise the actual Swift decoder against the JSON mode, fragmented pipes, filenames with newlines, and damaged data.

The disk summary reads macOS filesystem capacity/free counters and defines used as capacity minus free. Its GB display uses paired rounding so the visible equation adds up. Whole-disk scans show the signed adjustment between scanned allocation estimates and OS used space; the adjustment can include shared APFS blocks, inaccessible data, snapshots, filesystem overhead, and changes since the scan. Per-folder estimates are never rescaled. Logical mode is explicit and warns that sparse capacity and repeated paths can exceed disk capacity. Progress totals follow the selected metric.

Verify accounting with `xcrun swiftc -O -parse-as-library -module-cache-path build/module-cache Sources/DiskSpace.swift scripts/verify_space.swift -o build/verify-space && build/verify-space`.

The Worktrees location finds checkouts of a repository you choose from Git metadata rather than folder names. It starts with Git's linked-worktree registry, which can reference paths anywhere. Use the repository button to select a checkout with an origin remote URL; the valid main checkout path is saved as a preference. Search this Mac runs a fresh full-disk scan, inspects `.git` markers, matches the selected repository's origin host and path, and expands each matching clone's worktree registry. Missing or inaccessible paths and partial size measurements are reported. Registered paths outside the usual worktree folders are included; a disk search remains limited to readable paths included by the normal scanner.

Each checkout is measured independently with two concurrent sizing jobs and four scanner workers per job. The list ranks allocation estimates or logical sizes and shows paths, branches, checkout types and Git locks. Nested checkouts and shared files can overlap, so the list does not claim a reclaimable-space total. Click a checkout to open its normal sunburst, or reveal it in Finder. Stop cancels discovery and sizing child processes.

Run `python3 scripts/verify_worktrees.py` for disposable real-Git discovery fixtures. No user repositories are modified by discovery or sizing. The chosen repository path is persisted; scan results remain in memory.

Before publishing, run `python3 scripts/audit_privacy.py` from this directory. It checks Git-visible files and branch and tag history for credential patterns, user-specific absolute paths, and unexpected generated files. Use repeated `--deny` arguments for private names or identifiers; these values are never saved by the script. `--staged` checks the index rather than working files. Run `python3 scripts/verify_privacy.py` to exercise the audit with disposable fixtures. Build outputs, local scan data, and local settings are excluded by `.gitignore`. This check is a guardrail, not a guarantee that arbitrary personal information can be detected automatically.
