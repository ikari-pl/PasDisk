# OpenDisk (Pascal)

Cross-platform disk usage analyzer — a Free Pascal rewrite of
[OpenDisk](https://github.com/137137137/OpenDisk), aimed at **macOS, Windows,
and Linux** from one codebase.

The original OpenDisk is a native SwiftUI / AppKit app whose speed comes from
Darwin-only APIs (`getattrlistbulk`, FSEvents). This project keeps the same
product idea (scan → ring chart → collector → delete) but builds the scanner
and tree model in FPC so Windows is a first-class target, not an afterthought.

## Status

**Day 0 scaffold.** Working pieces:

- `FileTree` — packed sibling/child tree (same shape as the Swift original)
- Portable directory traversal via `FindFirst` / `lstat` (Unix) or Win32 attrs
- CLI: `opendisk scan <path>` prints largest children of a path

Still to come: Darwin `getattrlistbulk` fast path, Windows USN incremental
rescans, Lazarus LCL UI (rings + collector), scan cache.

## Requirements

- [Free Pascal](https://www.freepascal.org/) 3.2.2+
- Optional: [Lazarus](https://www.lazarus-ide.org/) for the future GUI
- Optional: [PascaLS](https://github.com/) MCP indexer for agent tooling

## Build

```sh
make            # → ./opendisk
make test       # FileTree unit tests
```

## Run

```sh
./opendisk scan ~
./opendisk scan /Volumes/External
```

## Layout

```
src/opendisk.lpr          CLI entry
src/units/FileTree.pas    In-memory directory tree
src/units/DirReader.pas   Platform directory listing
src/units/Traversal.pas   Recursive scanner
src/units/Formatters.pas  Human-readable sizes
tests/                    FPCTest-style unit tests
```

## Relationship to Swift OpenDisk

| | Swift OpenDisk | OpenDisk-pascal |
|---|---|---|
| Platforms | macOS 15+ | macOS, Windows, Linux |
| UI | SwiftUI + AppKit | CLI now; Lazarus LCL planned |
| Fast scan | `getattrlistbulk` | Portable first; Darwin bulk later |
| Incremental | FSEvents | TBD (USN Journal on Windows) |
| License | MIT | MIT |

Algorithms and UX ideas are shared; this is a new codebase, not a line-by-line
port of Darwin interop.

## License

[MIT](LICENSE).
