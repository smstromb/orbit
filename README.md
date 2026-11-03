# Orbit

A macOS disk explorer with a Rust scanner, a native SwiftUI sunburst, and Git worktree discovery for a repository you choose.

Requires Apple Silicon, macOS 14 or later, Xcode command-line tools, Python 3, and Rust 1.95.0.

```sh
cd Orbit
bash scripts/build.sh
```

Launch `Orbit/build/Orbit.app` from the repository root after building. See [the app documentation](Orbit/README.md) for navigation, disk accounting, worktree discovery, verification, and privacy checks.

Orbit reads filesystem metadata and local Git metadata. It has no deletion actions, telemetry, or network dependencies. Scan results stay in memory; the selected repository path stays in local preferences.
