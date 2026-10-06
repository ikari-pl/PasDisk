# Feature parity: Swift OpenDisk vs OpenDisk-pascal

Checklist for bead `od-31j.17`. It feeds the GUI fidelity epic `od-31j.18`.

- **Swift reference:** `/Users/ikari/src/OpenDisk/OpenDisk/` (paths below are relative to it).
- **Pascal port:** `src/` in this repo at commit `d4ada94` (2026-10-05). Line numbers refer to
  that commit, except in rows updated on 2026-10-06, which name units and cite the commit that
  changed them. Uncommitted work in the checkout is not reflected.
- **Method:** I read both source trees. I did not build or run either app, so visual and runtime
  claims come from the code and from the bead descriptions.

**Status values:** **Done** = behavior matches Swift. **Partial** = present, but it differs as
noted. **Missing** = no counterpart. **N/A** = does not apply to this column or this build.
**Unverified** = I could not confirm it from source alone; the note says why.
"Engine/CLI" covers `src/units/` and `src/opendisk.lpr`. "GUI" covers `src/gui/`.

---

## 1. Scanning engine

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| `getattrlistbulk` directory reader (`O_NOFOLLOW`, name/type/fileid/linkcount/allocsize, mount status) | Services/Scanning/SystemInterop/BulkDirectoryReader.swift:23-80 | units/DirReader.pas:65-96, 366-530 | Done | Done | od-31j.3 | Pascal also falls back to the portable reader when the Darwin read fails (DirReader.pas:532-541). Swift has no fallback. |
| Portable reader (`FindFirst`/`readdir`) | — | units/DirReader.pas:271-343 | N/A | N/A | od-31j.1 | Pascal only. It exists for non-Darwin platforms. |
| Device-boundary stop; mount points kept as empty dirs | TraversalScanner.swift:178-183; BulkDirectoryReader.swift:43 | units/Traversal.pas:171-175; DirReader.pas:486-491 | Done | Done | — | |
| Hard-link dedupe (first sighting counts) + `recordHardLink` | TraversalScanner.swift:138-176 | units/Traversal.pas:140-150 | Done | Done | — | |
| `normalizeHardLinks` | Services/Scanning/FileTree.swift:110-122 | units/FileTree.pas:587 | Done | Done | od-31j.22 | |
| FileTree model, size rollup, display sort, `path(of:)`, `nodeID(forPath:)` | FileTree.swift:3-306 | units/FileTree.pas:29-770 | Done | Done | od-31j.1 | |
| Allowed devices = scan root + Data volume (when the root is on the system volume) | Services/Scanning/ScanEngine.swift:160-162, 256-265 | units/Traversal.pas:73-88; opendisk.lpr:92; gui/uMainForm.pas (TScanThread.Execute) | Done | Done | od-31j.39 | Both full-scan paths pass `SubtreeAllowedDevices` (2115090, a081ce3); `test_traversal` checks / includes /System/Volumes/Data. |
| Data-volume alias (`/x` → `/System/Volumes/Data/x` when `/x` is missing) | ScanEngine.swift:173-177 | units/ScanTopology.pas (ResolveDataVolumeAlias); gui/uMainForm.pas (TScanThread, StartScan) | Done | Done | od-31j.43 | 93a8b81; GUI scans through it since 07394ea. |
| Boot volume group: scan `/` plus each `/System/Volumes/*` sibling, merge them, drop `/Volumes` | ScanEngine.swift:288-359; FileTree.swift:306 (`merge`) | units/ScanTopology.pas (ScanBootVolumeGroup); FileTree.pas (Merge, RemoveChildNamed) | Done | Done | od-31j.43 | 93a8b81. Not exercised on a real `/` scan here (it would walk the NFS mount point under ~/OrbStack); merge and sibling selection are unit-tested. |
| Parallel traversal workers (3-5 for a subtree, 4-8 for a volume) | TraversalScanner.swift:6-12, 65-116 | units/Traversal.pas (ParallelScan, TScanWorker); ScanTopology.pas (WorkersFor) | Done | Done | od-31j.44 | 9fc76bc. ~/src (1.5M nodes): 1 worker 30-35 s, 4 workers 11-14 s. |
| Process I/O tuning (`setiopolicy_np` IMPORTANT, `RLIMIT_NOFILE` 65536) | ScanEngine.swift:41-48 | units/PlatformProcessTuning.pas | Done | Done | od-31j.43 | 93a8b81. Like Swift, it can lower a soft limit above 65536. |
| Cancellation (`isCancelled` checked by every worker) | ScanEngine.swift:5-10, 107-114; TraversalScanner.swift:127 | units/Traversal.pas (ScanPath IsCancelled); gui/uMainForm.pas CancelScan | Done | Done | od-31j.24 | Polled once per directory like TraversalScanner.swift:130; window close and Unmount stop the walk (2115090). |
| Progress metrics (bytes, items, phase) emitted every 33 ms | ScanEngine.swift:36, 63-72; ScanMetrics.swift; Models/ScanProgress.swift | units/Traversal.pas:177-178 (callback once per directory); opendisk.lpr:22-33 | Partial | Partial | od-31j.38 | No `checkingChanges` phase. The GUI polls unsynchronized fields every 120 ms (uMainForm.pas:144-154, 611-626). |
| Unreadable-directory count | ScanMetrics.swift:22; TraversalScanner.swift:131 | units/Traversal.pas (Unreadable); ScanTopology.pas | Done | Done | od-31j.43, od-31j.18.12 | 93a8b81; drives "Couldn't Read This Location" (07394ea). |
| Partial-tree snapshots during the scan (500 ms to 15 s backoff) | ScanEngine.swift:12-33, 74-99; Services/DiskAnalyzer.swift:208-217 | — | Missing | Missing | — | |
| CatalogScanner / SearchFS whole-volume enumeration | Services/Scanning/CatalogScanner.swift:5-125; SystemInterop/SearchFS.swift:31-291 | — | N/A | N/A | od-31j.19 | Nothing in the Swift app calls `CatalogScanner` or `CatalogSearch`; `ScanEngine` uses only `TraversalScanner`. Deferred (od-31j.19). |

## 2. Cache & incremental

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| Cache file format v3 (eventID, capturedAt, fullScanSeconds, device, path) + validation | Services/Scanning/ScanCache.swift:16-70 | units/ScanCache.pas:56, 246-328 | Done | Missing | od-31j.6, od-31j.12 | |
| FileTree binary serialization (`DMT3`) | FileTree.swift:330-473 | units/FileTree.pas:793-1000 | Done | Missing | od-31j.6 | |
| Corrupt cache falls back to a full scan | FileTree.swift:387 (`init?`) | units/FileTree.pas:863 | Done | N/A | od-31j.37 | |
| Prune to 8 files / 4 GiB; remove `.tmp` files older than 1 h | ScanCache.swift:111-145 | units/ScanCache.pas:58-59, 166-244 | Done | N/A | od-31j.36 | Cache dir and hash case differ (`~/Library/Caches/opendisk`, uppercase hex), so the two apps' caches are not interchangeable. |
| Scan tries the cache automatically and replays FSEvents (peek → journal → apply → save) | ScanEngine.swift:179-242 | opendisk.lpr:154-224 (`rescan` command only) | Partial | Missing | od-31j.12 | CLI `scan` always does a full walk; only `rescan` uses the cache. The GUI never uses the cache. |
| Replay time budget (half the expected scan time, 2-30 s) | ScanEngine.swift:244-246 | units/FSEventsJournal.pas:277-285; opendisk.lpr:64-78 | Done | Missing | od-31j.5 | |
| Background cache save | ScanEngine.swift:248-254 | opendisk.lpr:50-62 (synchronous) | Done | Missing | od-31j.6 | The CLI blocks on the write. Harmless for a CLI. |
| FSEvents journal: HistoryDone, dropped/wrapped/root-changed abort, MustScanSubDirs, 40k cap, sorted output | SystemInterop/FSEventsChangeJournal.swift:5-165 | units/FSEventsJournal.pas:73-260 | Done | Missing | od-31j.5, od-31j.23 | |
| `currentEventID` captured at scan start | FSEventsChangeJournal.swift:162; ScanEngine.swift:187 | units/FSEventsJournal.pas:150; opendisk.lpr:131-132 | Done | Missing | od-31j.5 | |
| Incremental apply: changed dirs, subtree rescans, hard-link policy, adopt-then-validate | Services/Scanning/IncrementalUpdater.swift:6-220 | units/Incremental.pas:47-355, 379-414 | Done | Missing | od-31j.22, od-31j.30, od-31j.32 | Pascal sorts changed directories shallowest first (Incremental.pas:165, 395). |
| Large-file drift re-stat (≥ 64 MiB) | IncrementalUpdater.swift:48-69 | units/Incremental.pas:357-377 | Done | Missing | od-31j.31 | |
| Live FSEvents window (`watch`) | — | opendisk.lpr:322-370; FSEventsJournal.pas:23-30 | N/A | N/A | — | Pascal only, for debugging. |
| Change journal on non-Darwin | — | units/FSEventsJournal.pas:260-275 (stub returns OK=False) | Missing | Missing | od-31j.15 | Off macOS, every rescan is a full scan. |

## 3. Volumes & permissions

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| Volume list: "Computer" (`/`) + browsable, readable, non-boot volumes with capacity | Services/DeviceMonitor.swift:19-60 | units/Volumes.pas:76-126; PlatformVolumes.pas:139-222 | Partial | Partial | od-31j.7, od-31j.27 | Swift sorts mounts by path (DeviceMonitor.swift:40); I found no sort in Pascal. Pascal uses `kCFURLEnumeratorSkipInvisibles` where Swift uses `.skipHiddenVolumes`. **Unverified** that the two filters select the same volumes. |
| Capacity: available = max(free, important-usage), clamped to total; purgeable = available - free | Models/DeviceInfo.swift:23-35; DeviceMonitor.swift:62-81 | units/Volumes.pas:54-61; PlatformVolumes.pas:191-222 | Done | Partial | od-31j.18.7 | Pascal does not compute or show the purgeable amount. |
| Live volume refresh | DeviceMonitor.swift:9-17 | gui/uMainForm.pas:254-261, 530-533 (Refresh button) | N/A | Done | od-31j.18.9 | The Swift source has no mount/unmount observer: `refresh()` runs only from `init`. The premise of od-31j.18.9 ("Swift refreshes on mount") is not supported by the source. |
| Full Disk Access probe (`isGranted`) | Services/FullDiskAccess.swift:11-43 | units/PlatformFullDiskAccess.pas | Done | Done | od-31j.18.12 | 07394ea. Same probe paths and rule. |
| FDA gate before scanning `/` + retry when the app becomes active | DiskAnalyzer.swift:54-58; Views/Analysis/DiskAnalysisView.swift:147-151 | gui/uMainForm.pas (StartScan, FormActivate) | N/A | Done | od-31j.18.12 | 07394ea. |
| FDA startup prompt (with suppression), open System Settings, relaunch | FullDiskAccess.swift:46-91; App/OpenDiskApp.swift:46-62 | units/PlatformFullDiskAccess.pas (OpenFullDiskAccessSettings); PlatformShell.pas (LaunchNewInstance) | N/A | Partial | od-31j.18.12 | Open System Settings and Quit & Reopen exist (07394ea); the startup prompt with suppression does not. |
| Settings window (FDA status, startup toggle, reset suppression) | Views/Settings/SettingsView.swift | — | N/A | Missing | — | |
| Protected paths (system roots, home, ~/Library, /Users/*, /Volumes/*, /System/Volumes/*, ancestors) | Services/ProtectedPaths.swift:3-47 | units/ProtectedPaths.pas:38-133 | Done | Done | od-31j.9, od-31j.26 | Pascal adds a Windows variant (ProtectedPaths.pas:82-110). |
| Sandbox folder grants (security-scoped bookmarks) | Services/ScanAccess.swift; Views/Main/DevicePickerView.swift:57-92, 109-139 | — | N/A | N/A | — | Applies only to the sandboxed Swift build. The Pascal app is not sandboxed. |

## 4. Search

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| Name index + multi-token AND match, largest first, 500-result cap, scope All/Folders/Files | Services/Search/SearchIndex.swift:3-247 | units/SearchIndex.pas; opendisk.lpr (CmdSearch) | Done | Missing | od-31j.41, od-31j.18.5 | 93260b8: blob + longest-token sweep, 500-entry heap, size then name, TotalMatches. No GUI search yet. |
| Case/Unicode folding (`lowercased()` + NFC) | SearchIndex.swift:80-104 | units/SearchIndex.pas (FoldName); PlatformTextFold.pas | Done | Missing | od-31j.41 | 93260b8: CFStringLowercase + NFC on macOS; other systems fold without NFC. |
| Skip unreachable nodes (detached by incremental updates) | SearchIndex.swift:58 (`reachabilityBitmap`) | units/SearchIndex.pas; FileTree.pas (ReachabilityBitmap) | Done | Missing | od-31j.41 | 93260b8. |
| Partial-index search while scanning ("results may be incomplete") | DiskAnalyzer.swift:214-216, 323-342; Views/Analysis/SearchResultsView.swift:57-61 | — | N/A | Missing | od-31j.18.5 | |
| Search UI: toolbar `.searchable`, results list with location line, open result navigates | DiskAnalysisView.swift:152-162, 238-250, 417-424; SearchResultsView.swift | — | N/A | Missing | od-31j.18.5 | |

## 5. Collector & deletion

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| Stage rules: skip `::` paths and missing paths, block protected paths, dedupe, parent absorbs children | Models/Collector.swift:37-54 | units/Collector.pas:136-188 | Done | Partial | od-31j.9, od-31j.25 | The GUI can stage files only (double-click, uMainForm.pas:761-781). Directories cannot be staged from the GUI. |
| Undo stack (max 50, no-op changes not recorded) + Cmd-Z | Collector.swift:27-30, 108-119; DiskAnalysisView.swift:180-186 | units/Collector.pas:110-134, 202-219; gui/uMainForm.pas:550-555 | Done | Done | od-31j.25 | |
| Blocked-protected notice (banner, auto-hides after 3.5 s) | Collector.swift:56-64; Views/Components/CollectorBar.swift:66-72, 286-297 | units/Collector.pas:146-150; gui/uMainForm.pas:746-751 | Done | Partial | od-31j.18.6 | The notice is appended to the collector label and never times out. |
| Drag-in drop target (rows and rings → collector) with targeted/rejecting tint | DiskAnalysisView.swift:450-476; CollectorBar.swift:35-41, 113-157; Utilities/FileDrag.swift | — | N/A | Missing | od-31j.18.6 | |
| Dragged-protected rejection state | Collector.swift:66-75; Views/Components/FolderRowView.swift:24-45 | — | N/A | Missing | od-31j.18.6 | |
| Expandable staged list (hover), per-row remove, Preview, Show in Finder, Open in Terminal | CollectorBar.swift:30-45, 265-284, 315-403 | — | N/A | Missing | od-31j.18.6, od-31j.18.15 | |
| Drag out of the collector to unstage (keep zones) | Collector.swift:77-103; CollectorBar.swift:171-175 | — | N/A | Missing | od-31j.18.6 | |
| Permanent-delete confirmation ("Delete N items?" / "Delete <size>") | CollectorBar.swift:99-110 | gui/uMainForm.pas:832-835 | N/A | Partial | — | Uses a modal `MessageDlg` (Yes/No), not a sheet with a destructive button. The wording differs. |
| Delete execution: per-item, off the main thread; failures stay staged; clear undo | Collector.swift:132-160 | units/Collector.pas; PlatformRemove.pas | Done | Partial | od-31j.33, od-31j.34 | PlatformRemove is descriptor-relative and iterative on Unix (7e2c079). The GUI still runs `DeleteAll` on the UI thread, so the window freezes during large deletes. |
| Delete progress (current name, n of N, freed bytes, bar) | Collector.swift:14-25, 140-142; CollectorBar.swift:204-243 | — | N/A | Missing | — | |
| Done state ("Freed X · N couldn't be removed", 2 s) | CollectorBar.swift:245-263, 299-307 | gui/uMainForm.pas:838-842 (status bar text) | N/A | Partial | — | |
| Rescan the root after a delete | DiskAnalysisView.swift:444-448 | gui/uMainForm.pas:843 | N/A | Done | od-31j.11 | |
| Purgeable/cache synthetic node: "Purgeable Space" row, chart, expands into the collector | Models/HiddenSpace.swift; DiskAnalyzer.swift:137-199, 236-250; DiskAnalysisView.swift:206-210, 465-469 | units/CleanableSpace.pas; PlatformCacheCatalog.pas | Partial | Missing | od-31j.20 | 9aa1682: catalogue, entries, totals, display order. Summary row, navigation, chart and collecting are not wired yet. |

## 6. Charts

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| ChartItem tree (max depth 5, min fraction 0.0015, `hasHiddenChildren`) | Models/ChartItem.swift:23-82 | units/ChartItem.pas:45-46, 75-140 | Done | Done | od-31j.2 | Pascal declares `ckSynthetic` but never builds one (see od-31j.20). |
| Rings layout geometry + hit test | Views/Charts/RingsChartLayout.swift:4-91 | units/RingsLayout.pas:103-194 | Done | Done | od-31j.2 | |
| Palette (6 hues, 3 bands, depth intensity, highlight normalization) | Views/Charts/ChartPalette.swift:3-55 | gui/RingsChart.pas:116-167; units/RingsSVG.pas:27-65 | Done | Partial | od-31j.18.10 | The center disk is dark (`$0038322E`) in the GUI; Swift uses light grey `#D3D6D1`/`#E0E2DD`. The GUI also draws a hardcoded dark gradient background (RingsChart.pas:169-182). |
| Antialiased arc paths | Views/Charts/RingsChartView.swift:210-234 | gui/PlatformChartCanvas.pas (Core Graphics arcs) | N/A | Done | od-31j.18.11 | ba740bb. |
| Static layer cache; redraw only the hover overlay | RingsChartView.swift:17-23, 148-160 | gui/RingsChart.pas; PlatformChartCanvas.pas (TChartCanvasCache) | N/A | Done | od-31j.18.14 | ba740bb: cached at the window's backing scale; rebuilt on resize, scale or appearance change. |
| Hover highlight of a segment | RingsChartView.swift:26-34, 128-145 | gui/RingsChart.pas:295, 299-327 | N/A | Done | od-31j.18.4 | |
| Hover tooltip pill (name, size · %, edge flip) | Views/Charts/ChartHoverTip.swift:3-58 | — | N/A | Missing | od-31j.18.13 | |
| Curved sector labels (thickness ≥ 12, arc ≥ 30, fit 85%, flipped on the lower half) | RingsChartView.swift:236-279 | gui/RingsChart.pas:259-270 (straight text at the bisector) | N/A | Partial | od-31j.18.4 | Different thresholds; no fit check, so labels can overflow. |
| Center label (name + size, falls back to size only) | RingsChartView.swift:281-303 | gui/RingsChart.pas:196-220 | N/A | Partial | od-31j.18.4 | No width-fit fallback; colors differ. |
| Continued-edge arc for hidden children | RingsChartView.swift:194-207 | gui/PlatformChartCanvas.pas (StrokeContinuedEdge) | N/A | Done | od-31j.18.11 | ba740bb: Core Graphics arc. |
| Click: center → back, directory → navigate | RingsChartView.swift:35-44 | gui/RingsChart.pas:329-343; uMainForm.pas:783-793 | N/A | Done | od-31j.11 | Pascal checks `DirectoryExists` on disk instead of the segment kind. |
| Drag a segment to the collector; segment context menu (Add, Show in Finder, Copy Path) | RingsChartView.swift:45-56, 96-126; Views/Components/FileActionsMenu.swift | — | N/A | Missing | od-31j.18.6 | The context menu has no bead (see Gaps). |
| Chart accessibility (label + per-segment elements/actions) | RingsChartView.swift:57-94 | — | N/A | Missing | — | |
| Coalesced chart rebuild; "Building chart…" placeholder | DiskAnalyzer.swift:256-281; DiskAnalysisView.swift:430-439 | gui/RingsChart.pas:281-287 ("Rings appear after a scan.") | N/A | Partial | od-31j.18.4 | |
| SVG/HTML rings export (`opendisk view`) | — | units/RingsSVG.pas; opendisk.lpr:258-292 | N/A | N/A | — | Pascal only. |

## 7. GUI shell & navigation

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| Picker first, analysis after choosing (NavigationStack) | Views/Main/ContentView.swift:8-23 | gui/uMainForm.pas:401-418 | N/A | Done | od-31j.8 | |
| Device row fidelity (volume icon, used/total decimal, capacity bar, chevron, hover) | Views/Components/DeviceRow.swift; DevicePickerView.swift:160-179 | gui/uMainForm.pas VolListDrawItem | N/A | Partial | od-31j.18.1 | Owner-drawn rows with semantic colours, used/total caption and capacity bar (d2ba636); volume icons, hover, chevron and Swift row metrics are in progress under od-31j.18.1. |
| "Scan Folder…" open panel | DevicePickerView.swift:46-49, 141-157 | gui/uMainForm.pas:521-528 | N/A | Done | od-31j.11 | `SelectDirectory` starts in the home folder. |
| Empty picker state ("No Disks Found") | DevicePickerView.swift:29-35 | — | N/A | Missing | od-31j.18.12 | |
| Breadcrumb bar (clickable segments, hover, chevrons) | Views/Components/BreadcrumbBar.swift | gui/BreadcrumbBar.pas; gui/uMainForm.pas CrumbNavigate | N/A | Done | od-31j.18.2 | 93ceb04. Deviation: an over-long trail collapses its middle and middle-truncates names instead of scrolling horizontally. |
| Toolbar: Unmount (Cmd-[, confirmation dialog), Refresh (Cmd-R) | DiskAnalysisView.swift:97-122, 189-195 | gui/uMainForm.pas DisksClick/RefreshClick/FormKeyDown | N/A | Partial | od-31j.18.19 | Behaviour done (717ffaf): Unmount + confirmation, Cmd-[, Refresh rescans the current folder, Cmd-R, window title. Native NSToolbar + size subtitle missing. |
| Window title/subtitle (folder name / displayed size) | DiskAnalysisView.swift:94-95, 496-506 | gui/uMainForm.pas:601 | N/A | Partial | od-31j.18.2 | No subtitle. The title does not follow navigation. |
| Back via the rings center / breadcrumb stack | DiskAnalysisView.swift:544-574 | gui/uMainForm.pas:772-773, 809-818 | N/A | Done | od-31j.11 | |
| Navigating to an unscanned path triggers a scan of it | DiskAnalysisView.swift:569-574 | — | N/A | Missing | — | |
| List/chart split 60/40, resizable, minimum widths | DiskAnalysisView.swift:51-67 | gui/uMainForm.pas:343-348 (fixed 440 px, no splitter) | N/A | Partial | od-31j.18.4 | |
| Folder rows: file icon, name weight, "N items", size bar, size, chevron, hover/selection | Views/Components/FolderRowView.swift:47-121; Views/Analysis/ScanResultsView.swift | gui/uMainForm.pas ListDrawItem | N/A | Partial | od-31j.18.17 | a1801e3, b481ed9: name weight, item count, size capsule, size column, chevron, hover/selection, middle truncation. Native file icons missing. |
| Sortable Name/Size column header | DiskAnalysisView.swift:216-228, 340-375 | — | N/A | Missing | od-31j.18.3 | |
| Multi-select (Shift range, Cmd toggle) + "Add N Selected" | DiskAnalysisView.swift:377-415; FolderRowView.swift:160-171 | — | N/A | Missing | od-31j.18.16 | |
| Row context menu (Add to Collector, Quick Look, Show in Finder, Copy Path) | FolderRowView.swift:150-196 | — | N/A | Missing | — | |
| Quick Look (Space, centered panel) | DiskAnalysisView.swift:123-128, 265-338 | — | N/A | Missing | — | |
| Drag rows out to Finder (move → refresh) | Utilities/FileDrag.swift:44-115; DiskAnalysisView.swift:167-169 | — | N/A | Missing | — | |
| Display limits: 100 children below the root, hide < 1 KiB | DiskAnalyzer.swift:7-8, 344-368 | gui/uMainForm.pas:717-729 (shows every child > 0 bytes) | N/A | Partial | — | |
| Skeleton listing before the first results | DiskAnalyzer.swift:89-96, 370-417 | — | N/A | Missing | — | |
| Scanning placeholder ("Preparing scan…") | DiskAnalysisView.swift:80-83 | gui/uMainForm.pas:600 (crumb text) | N/A | Partial | od-31j.18.4 | |
| Empty / FDA-required / unreadable states | DiskAnalysisView.swift:508-542 | gui/uMainForm.pas:573-576, 639-644 (`MessageDlg`, status text) | N/A | Missing | od-31j.18.12 | |
| Scan status bar: phase text, progress bar vs. used space, files/sec, "Scanned in", total · items | Views/Components/ScanStatusBar.swift:15-77; DiskAnalysisView.swift:484-487 | gui/uMainForm.pas:618-620, 650-655 (`TStatusBar` simple text) | N/A | Partial | od-31j.18.7 | |
| Status bar capacity readout (bar + "X available of Y", purgeable tooltip, a11y) | ScanStatusBar.swift:60-112; DiskAnalysisView.swift:134-137, 489-494 | gui/uMainForm.pas:650-653 (text "volume used / total") | N/A | Partial | od-31j.18.7 | |
| Semantic system colors (light/dark) | Swift uses system materials throughout | gui/uMainForm.pas, RingsChart.pas, GuiColors.pas, PlatformAppearance.pas | N/A | Done | od-31j.18.10 | d2ba636. Dark mode judged from source (host in Light). |
| Typography/spacing tokens | — | gui/uMainForm.pas (ad-hoc sizes) | N/A | Missing | od-31j.18.8 | |
| Restrained motion (hover fades, collector drawer, chart transition) | CollectorBar.swift:89-95; ScanResultsView.swift:29 | — | N/A | Missing | od-31j.18.15 | |
| Thread-safe scan state handoff | DiskAnalyzer.swift:99-103 (MainActor hop) | gui/uMainForm.pas:126-170, 611-626 | N/A | Missing | od-31j.38 | |
| Byte formatting (`ByteCountFormatter` `.file` = decimal; GB/TB no fraction on devices) | Utilities/Formatters.swift:4-31 | units/Formatters.pas; units/PlatformLocale.pas | Done | Done | od-31j.40 | b2e9e18: matches 360 values from the real ByteCountFormatter (en_US, en_PL), locale separators. |

## 8. Platform / portability

| Feature | Swift ref | Pascal ref | Engine/CLI | GUI | Bead | Note |
|---|---|---|---|---|---|---|
| OS interface layer (`Platform*` units) | — | units/PlatformFS.pas, PlatformVolumes.pas, PlatformRemove.pas | Partial | N/A | od-31j.29 | Still in progress. `IFDEF` sites remain in DirReader, FSEventsJournal and ProtectedPaths. |
| Windows build (CLI, GUI if feasible) | — | Windows branches in DirReader/PlatformVolumes/PlatformRemove/PlatformFS | Unverified | Unverified | od-31j.13 | Code paths exist. No build was run. |
| Linux build | — | Unix branches as above | Unverified | Unverified | od-31j.14 | No build was run. |
| `.app` bundle + icon | App target (Xcode) | — | N/A | Missing | od-31j.16 | |
| Move-to-Applications prompt / translocation handling | App/MoveToApplications.swift | — | N/A | Missing | — | Swift runs it only when Sparkle is linked. |
| Sparkle "Check for Updates…" | App/SoftwareUpdater.swift; DevicePickerView.swift:94-107 | — | N/A | Missing | — | Distribution feature. |
| `RemoveItem` hardening (O_NOFOLLOW dir open, iterative) | — (Swift uses `FileManager.removeItem`) | units/PlatformRemove.pas:28-85 | Partial | N/A | od-31j.34 | Hardening goes beyond Swift; not a parity requirement. |

---

## GUI fidelity gaps (feeds od-31j.18)

| Bead | Title | Rows above |
|---|---|---|
| od-31j.18.1 | Device picker: capacity row fidelity | §7 Device row fidelity |
| od-31j.18.2 | Analysis chrome: toolbar + breadcrumbs | §7 Breadcrumb bar, Toolbar, Window title |
| od-31j.18.3 | Folder list: FolderRow density + sort + multi-select | §7 Folder rows, Sortable header, Multi-select |
| od-31j.18.4 | Rings pane: labels, hover, HSplit proportions | §6 Sector/center labels, placeholder; §7 split, scanning placeholder |
| od-31j.18.5 | In-GUI name search | §4 Search UI, partial-index search |
| od-31j.18.6 | Collector bar: drag targets + visual staging | §5 drag-in, rejection, staged list, drag-out; §6 segment drag |
| od-31j.18.7 | Scan status bar: phase, progress, capacity | §7 status bar, capacity readout; §3 purgeable amount |
| od-31j.18.8 | Typography/spacing design tokens | §7 tokens |
| od-31j.18.9 | Live DeviceMonitor volume attach/detach | §3 Live volume refresh (no Swift basis) |
| od-31j.18.10 | Semantic system colors | §7 colors; §6 palette center/background |
| od-31j.18.11 | Antialiased CoreGraphics arcs | §6 arcs, continued edge |
| od-31j.18.12 | Empty / FDA / error states | §3 FDA rows; §7 empty picker, empty/FDA/unreadable |
| od-31j.18.13 | Rings hover tooltip pill | §6 tooltip |
| od-31j.18.14 | Rings: cache static layer | §6 static layer |
| od-31j.18.15 | Restrained native motion | §5 staged list drawer; §7 motion |

Related GUI correctness beads outside od-31j.18: od-31j.12 (cache in the GUI), od-31j.24 (cancellation), od-31j.38 (thread-safe state).

## Gaps without a bead

Engine/CLI:
1. ~~Scans don't pass `SubtreeAllowedDevices`~~ — fixed in CLI and GUI (od-31j.39).
2. ~~Data-volume path alias (§1).~~ — fixed (od-31j.43, 93a8b81).
3. ~~Boot volume group composition: `/System/Volumes/*` siblings, `merge`, drop `/Volumes` (§1).~~ — fixed (od-31j.43, 93a8b81).
4. ~~Parallel traversal workers (§1).~~ — fixed (od-31j.44, 9fc76bc).
5. ~~Process I/O tuning: iopolicy and file-descriptor limit (§1).~~ — fixed (od-31j.43, 93a8b81).
6. ~~Unreadable-directory counting (§1).~~ — fixed (93a8b81; used by od-31j.18.12, 07394ea).
7. Partial-tree snapshots during the scan (§1).
8. ~~Search: reachability filter, Unicode/NFC folding, name tiebreak, total-match count (§4).~~ — fixed (od-31j.41, 93260b8).
9. ~~Byte formatting: decimal `ByteCountFormatter` semantics (§7).~~ — fixed (od-31j.40).
10. Volume list sorted by path (§3).

GUI:
11. Settings window: FDA status, startup prompt toggle (§3).
12. Deletion progress UI and running deletion off the UI thread (§5).
13. Delete confirmation as a native sheet with Swift wording (§5).
14. Staging directories from the GUI (§5).
15. Row and segment context menus: Add to Collector, Quick Look, Show in Finder, Copy Path (§6, §7).
16. Quick Look (§7).
17. Drag rows out to Finder, with refresh on move (§7).
18. Display limits: top 100 below the root, hide < 1 KiB (§7).
19. Skeleton listing before results (§7).
20. Navigating to an unscanned path triggers a scan (§7).
21. ~~Refresh rescans the current folder, not the root (§7).~~ — fixed (od-31j.18.2).
22. Chart accessibility (§6).

Distribution:
23. Move-to-Applications prompt (§8).
24. Sparkle updates (§8).

## Unverified items

- ~~**`/` scan misses the Data volume**~~ — resolved by od-31j.39: confirmed from source and by `tests/test_traversal.pas` `TestAllowedDevices` (CLI) and the GUI scan thread (2115090).
- **Hidden-volume filter equivalence:** whether `kCFURLEnumeratorSkipInvisibles` matches Swift's `.skipHiddenVolumes` was not tested.
- **Windows and Linux builds (od-31j.13, od-31j.14):** no build was run.
- **GUI visuals:** light appearance, folder rows, breadcrumbs and the rings chart are checked in window captures (OPENDISK_GUI_SCAN); dark appearance is judged from source only (the host is in Light and no per-process override forces Dark).

## Summary counts

Each table row has two cells: one for Engine/CLI and one for GUI. These counts tally cells, not rows. Totals cover §1–§8 (105 rows).

| Status | Engine/CLI | GUI |
|---|---|---|
| Done | 36 | 31 |
| Partial | 6 | 22 |
| Missing | 2 | 41 |
| N/A | 59 | 9 |
| Unverified | 2 | 2 |

Engine/CLI is mostly at parity; scan topology, parallel workers, I/O tuning, the unreadable count and search now match. Partial snapshots and the purgeable node are not finished. Most remaining work is GUI fidelity and interaction (od-31j.18.*).
