# PasDisk

Cross-platform disk usage analyzer — a Free Pascal port of
[OpenDisk](https://github.com/137137137/OpenDisk) (MIT), aimed at **macOS,
Windows, and Linux**.

## Status (goal: full parity + better visuals)

| Area | State |
|---|---|
| FileTree + hard-link once-counting | Done |
| Darwin `getattrlistbulk` (FindFirst fallback) | Done |
| Rings geometry (`RingsLayout` = Swift) | Done |
| SVG HTML viewer (`pasdisk view`) | Done |
| Name search | Done |
| Collector + protected paths (units) | Done |
| FSEvents incremental (`watch` / `rescan`) | Done |
| ScanCache persistence (`~/Library/Caches/pasdisk/`) | Done |
| Volume listing (`pasdisk volumes`) | Done |
| Cocoa LCL GUI | **Done** — link via `tools/ldwrap` (Xcode `ld-classic`) |
| Windows / Linux smoke | Not verified yet |
| Device picker UX / collector delete UI | Partial (collector panel in GUI) |

## Requirements

- Free Pascal 3.2.2+
- Optional: Lazarus (GUI), when Cocoa/Qt linking works on your host

## Build

```sh
make            # → ./pasdisk
make gui        # → ./pasdisk-gui  (needs Xcode ld-classic wrapper)
make app        # → ./PasDisk.app (bundle with Info.plist + icon; Developer ID signed when available, else ad-hoc)
make test
```

`make test` touches only the boot volume. The live volume sweep probes every
mounted volume, network shares included, so it is opt-in:
`OPENDISK_LIVE_VOLUMES=1 make test`.

## Run

```sh
./pasdisk volumes
./pasdisk scan ~              # full scan + cache
./pasdisk rescan ~            # FSEvents delta onto cache (macOS)
./pasdisk view ~
./pasdisk search ~ cache
./pasdisk watch ~             # live 5s FSEvents window after scan
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
