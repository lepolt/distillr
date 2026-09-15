# cull-wizard

A native desktop tool for culling burst-shot photos fast: point it at a
folder, it groups near-identical burst sequences by capture timestamp, and
you review each group and pick the keepers with a few keystrokes.

Built with [egui](https://github.com/emilk/egui)/`eframe` — one Rust
codebase, no webview, native windows on macOS and Windows.

## Status

- **Formats:** JPEG only for now. RAW support (CR2/CR3, NEF, ARW, …) is
  planned but not implemented.
- **Sources:** local folders only. Reading directly from a mounted SD
  card/camera volume is planned but not implemented.
- **Platforms:** actively developed and tested on macOS. Builds against the
  same cross-platform stack on Windows, but hasn't been validated there yet.

## Requirements

- [Rust](https://www.rust-lang.org/tools/install) (stable toolchain, via
  `rustup`)
- macOS or Windows with a graphical session (this is a native GUI app, not
  a headless tool)

No other system dependencies — everything else is a Cargo crate.

## Running it

```bash
cargo run --release
```

`--release` matters here: JPEG decoding is meaningfully faster in release
mode. A debug build works but feels sluggish on large folders.

This launches the `cull-wizard` binary (from the `cw-app` crate). Click
**Choose folder…** and point it at a folder of JPEGs.

## Using it

1. **Choose folder…** — pick a folder of JPEGs. They're scanned, grouped
   into bursts by capture-time proximity, and shown as a grid, one section
   per burst.
2. **Review a burst** — click **Review** on a group, or double-click any
   thumbnail to jump straight to it.
   - `←` / `→` — navigate between photos in the burst
   - `K` — keep, `X` — reject, `U` — clear the decision
   - `2` / `3` / `4` — expand into a multi-photo compare view
   - `Esc` — back to the grid
3. **Compare mode** — review 2-4 photos side by side (2/3 in a row, 4 in a
   2×2 grid). Click a panel or use the arrow keys to change focus; `K`/`X`/
   `U` act on the focused panel and it refills with the next undecided
   photo. `1` collapses back to single view.
   - You can also select 2-4 thumbnails in the grid (Cmd/Ctrl-click) and
     click **Compare (N)** to open them together.
4. **Grid keyboard navigation** — click a thumbnail, then use the arrow
   keys (Finder-style) and `Enter` to open review on the focused photo.
5. **Finalize…** — once you're done deciding, this is the only step that
   touches your files. Two independent choices:
   - Move rejected photos to the OS trash/recycle bin
   - Copy keepers (anything not rejected) to a destination folder you pick

   Nothing happens until you confirm. Rejecting or keeping a photo never
   touches the file on disk by itself — only Finalize does.

## Project layout

A Cargo workspace, one crate per concern:

| Crate | Responsibility |
|---|---|
| [`cw-scan`](crates/cw-scan) | Folder walking |
| [`cw-metadata`](crates/cw-metadata) | EXIF reading (capture time, camera model, dimensions) |
| [`cw-burst`](crates/cw-burst) | Burst-sequence clustering by capture-time gap |
| [`cw-actions`](crates/cw-actions) | Trash / copy-to-destination logic |
| [`cw-app`](crates/cw-app) | The `eframe`/`egui` UI — everything else lives here |

`cw-scan`, `cw-metadata`, `cw-burst`, and `cw-actions` have no UI
dependency and are fully unit-testable headless.

## Testing

```bash
cargo test           # debug build — correct, but JPEG decode is slow
cargo test --release # much faster; use this if you're iterating on tests
```

The test suite runs against real JPEGs in `examples/` rather than mocked
data. That folder isn't part of this repo (see `.gitignore`) since it's
real camera photos — to run the full suite yourself, drop your own JPEGs
in `examples/` at the repo root. Tests that check specific burst groupings
expect a particular set of files (see `crates/cw-burst/src/lib.rs` and
`crates/cw-app/src/main.rs` test modules for what they assume); tests that
just need *some* real JPEGs will work with any of your own photos.
