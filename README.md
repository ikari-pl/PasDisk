# OpenDisk (Pascal)

Cross-platform disk usage analyzer — Free Pascal rewrite of
[OpenDisk](https://github.com/137137137/OpenDisk), aimed at **macOS, Windows,
and Linux**.

## Status (goal: full parity + better visuals)

| Area | State |
|---|---|
| FileTree + hard-link once-counting | Done |
| Darwin `getattrlistbulk` (FindFirst fallback) | Done |
| Rings geometry (`RingsLayout` = Swift) | Done |
| SVG HTML viewer (`opendisk view`) | Done |
| Name search | Done |
| Collector + protected paths (units) | Done |
| FSEvents incremental (`watch` / `rescan`) | Done |
| ScanCache persistence (`~/Library/Caches/opendisk/`) | Done |
| Volume listing (`opendisk volumes`) | Done |
| Cocoa LCL GUI | **Done** — link via `tools/ldwrap` (Xcode `ld-classic`) |
| Windows / Linux smoke | Not verified yet |
| Device picker UX / collector delete UI | Partial (collector panel in GUI) |

## Requirements

- Free Pascal 3.2.2+
- Optional: Lazarus (GUI), when Cocoa/Qt linking works on your host

## Build

```sh
make            # → ./opendisk
make gui        # → ./opendisk-gui  (needs Xcode ld-classic wrapper)
make test
```

`make test` touches only the boot volume. The live volume sweep probes every
mounted volume, network shares included, so it is opt-in:
`OPENDISK_LIVE_VOLUMES=1 make test`.

## Run

```sh
./opendisk volumes
./opendisk scan ~              # full scan + cache
./opendisk rescan ~            # FSEvents delta onto cache (macOS)
./opendisk view ~
./opendisk search ~ cache
./opendisk watch ~             # live 5s FSEvents window after scan
```

## Layout

```
src/opendisk.lpr          CLI
src/units/                FileTree, DirReader, Traversal, ScanCache, …
src/gui/                  Lazarus GUI (OpenDiskGUI.lpi)
tests/
```

## License

[MIT](LICENSE).
