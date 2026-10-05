# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:1105d646 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/core-concepts/sync-concepts.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Swift reference (parity source)

This repo is a Free Pascal / Lazarus port of the Swift OpenDisk app.
**Do not invent behavior** — match the Swift implementation when adding or
changing scan, cache, rings, collector, volumes, or GUI flows.

| | |
|---|---|
| Local clone | `/Users/ikari/src/OpenDisk` |
| Upstream | https://github.com/137137137/OpenDisk |
| App sources | `/Users/ikari/src/OpenDisk/OpenDisk/` |

Useful Swift entry points (under `OpenDisk/`):

- `Services/Scanning/` — `getattrlistbulk`, tree walk, hard links, FSEvents
- `Services/Search/` — name search
- `Services/` — volumes, Full Disk Access, protected paths, analyzer
- `Views/Charts/` — rings layout / chart
- `Views/Main/` — device picker, content shell
- `Views/Analysis/` — scan results, search UI
- `Views/Components/` — collector, breadcrumbs, device rows

Treat the Swift tree as **read-only reference**. Edit only this Pascal repo
unless the user explicitly asks otherwise.

## UI design and rendering standard

The Pascal UI must feel like a polished native macOS app. Match the Swift
reference before creating a new visual language. Preserve native behavior,
keyboard access, accessibility, and system appearance while porting it.

### Visual design

- Use native Cocoa/LCL controls when they produce the correct result. Custom
  draw only charts, progress visuals, and interactions that native controls
  cannot express.
- Follow the Swift hierarchy, spacing, type scale, colors, icons, hover states,
  selection states, empty states, and error states. Compare both apps at the
  same window size before calling a screen complete.
- Use system fonts and semantic weights. Use monospaced digits only for changing
  sizes, counts, rates, and percentages. Never use a monospaced font for the
  main file list.
- Use semantic system colors where Cocoa exposes them. Support light mode,
  dark mode, increased contrast, accent-color changes, inactive windows, and
  disabled controls. Do not hard-code a dark-only palette.
- Keep spacing on a small scale such as 4, 8, 12, 16, 20, 24, and 32 points.
  Align text baselines and control edges. Avoid arbitrary one-off offsets.
- Use SF Symbols or native template icons where available. Keep symbols sharp,
  monochrome unless meaning requires color, and aligned to the text baseline.
- Use one restrained accent and reserve red, orange, and green for destructive,
  warning, and success states. Avoid gradients, glowing edges, fake glass,
  excessive shadows, decorative pills, and nested cards.
- Give every screen deliberate loading, empty, permission-denied, partial-data,
  and failure states. Never flash an empty list or stale chart while replacing
  data.

### HiDPI and antialiasing

- Lay out in logical points. Obtain the backing scale from the target window or
  view; never assume 1x or 2x and never multiply all coordinates by a constant.
- Let Cocoa render text. Do not rasterize text into cached bitmaps. Measure with
  the same font, weight, and scale used for drawing.
- Draw custom vector geometry with Core Graphics or an equivalent
  scale-aware, antialiased path API. Avoid polygon approximations when arcs or
  Bézier paths exist.
- Snap one-device-pixel strokes to the backing pixel grid. Recompute snapping
  when the window moves between displays or its backing scale changes.
- Render icons and cached chart layers at the current backing scale. Invalidate
  scale-dependent caches after display, appearance, size, font, or data changes.
- Never stretch a low-resolution bitmap. Keep source artwork vector-based or
  provide correct scale variants and use high-quality interpolation only for
  photographic content.
- Test at 100%, 125%, 150%, 200%, and mixed-display scales where the platform
  supports them. Check text, ring edges, separators, focus rings, and icons.

### Motion and 60 fps

- Animation must explain continuity: navigation, selection, hover, collector
  expansion, progress, insertion, removal, and chart transitions. Do not animate
  static decoration or make routine actions wait for an animation.
- Target the active display refresh rate, with 60 fps as the minimum baseline.
  At 60 Hz the main-thread frame budget is 16.67 ms; keep application work well
  below that budget.
- Drive visual animation from a display-synchronized clock. Derive each frame
  from elapsed time rather than adding fixed increments, so dropped frames do
  not change duration or final state.
- Keep animation state separate from model state. Retarget an in-flight
  animation from its current presentation value; never jump back to its old
  start value after rapid clicks, resize events, or repeated navigation.
- Prefer opacity and transform animation. Avoid relayout, text measurement,
  filesystem access, tree traversal, chart-layout calculation, or large memory
  allocation inside a frame callback.
- Compute scans, sorting, search, icons, and chart layouts off the UI thread.
  Publish immutable snapshots on the UI thread, coalesce bursts of progress,
  and repaint only the dirty region. Never block input while scanning.
- Cache the static rings layer. Redraw only the hover/selection overlay during
  pointer movement. Coalesce mouse-move and resize events to at most one visual
  update per display frame.
- Use short, consistent timings: roughly 100–160 ms for hover and selection,
  180–250 ms for simple state changes, and 250–350 ms for spatial transitions.
  Use ease-out for arrival and a restrained spring only for direct manipulation.
- Respect Reduce Motion. Replace spatial movement and springs with a short
  cross-fade or an immediate update. Stop timers when the window is hidden,
  occluded, minimized, or the animation reaches rest.
- Preserve focus, selection, hit targets, and input throughout animation.
  Interrupted and reversed animations must end in a valid state.

### Interaction quality

- Use native title bars, menus, sheets, context menus, tooltips, focus rings,
  cursors, drag-and-drop, and keyboard conventions. Never imitate a web page
  inside a desktop window.
- Provide hover, pressed, focused, selected, disabled, drag-target, busy,
  success, warning, and error states for every interactive component.
- Keep controls stable when labels, counts, or progress values change. Reserve
  space and use monospaced digits where needed to prevent layout jitter.
- Truncate paths in the middle, preserve filenames when possible, and show the
  full value in a tooltip or accessible description.
- Use split views and sensible minimum sizes. During live resize, degrade detail
  before dropping frames; recompute expensive chart geometry after coalescing
  resize events.
- Keep hit targets at least 28 by 28 points and separate destructive actions
  from routine navigation. Require explicit confirmation for permanent deletion.
- Match standard macOS keyboard navigation and VoiceOver semantics. Do not use
  color, hover, or animation as the only way to convey state.

### Performance and acceptance gate

- Profile release builds with Instruments or the closest platform profiler.
  Judge smoothness from frame-time traces, not by eye alone.
- A UI change is not complete until it has been checked at normal and HiDPI
  scales, in light and dark appearances, with Reduce Motion enabled, during live
  resize, and while a scan updates in the background.
- Record or inspect a sustained interaction trace. No recurring frame may exceed
  16.67 ms at 60 Hz, input must remain responsive, memory must remain bounded,
  and idle UI must not keep an animation timer running.
- Check rapid repeated input, cancellation, navigation during scans, window
  deactivation, display-scale changes, and empty/error states. Fix flicker,
  stale frames, clipped text, geometry jumps, hover lag, and race-dependent
  state before adding more polish.

## Build & Test

```bash
make            # → ./opendisk
make gui        # → ./opendisk-gui  (needs tools/ldwrap → Xcode ld-classic)
make test
```

## Architecture Overview

CLI (`src/opendisk.lpr`) and Cocoa LCL GUI (`src/gui/`) share units under
`src/units/` (FileTree, DirReader, Traversal, ScanCache, FSEventsJournal,
RingsLayout, Volumes, …). Goal: full parity with Swift OpenDisk, then
Windows/Linux.

## Conventions & Patterns

- Track work in **bd** (`od-31j.*`), not TodoWrite / markdown TODOs
- Prefer Darwin APIs on macOS (`getattrlistbulk`, FSEvents); fallbacks elsewhere
- When porting, cite the Swift file you mirrored in the commit/bead notes
