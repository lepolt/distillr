import AppKit
import SwiftUI

struct CompareView: View {
    @Bindable var model: AppModel

    /// Shared with all visible panels — see `ZoomPanController`'s doc
    /// comment for why this isn't part of `AppModel`.
    @State private var zoom = ZoomPanController()

    var body: some View {
        if let compare = model.compare {
            content(compare: compare)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(compare: CompareState) -> some View {
        VStack(spacing: 8) {
            HStack {
                Button(model.review != nil ? "Back to review (Esc)" : "Back to grid (Esc)") {
                    model.compare = nil
                }
                // Attached directly to this visible button rather than an
                // invisible ShortcutButton (unlike every other Compare
                // shortcut) — this is the one keyboard shortcut in this app
                // that's repeatedly failed to register reliably when routed
                // through the invisible-button mechanism, despite several
                // rounds of chasing plausible-looking causes (dynamic
                // label, Observable churn, gesture cross-talk). This exact
                // pattern — attached straight to a visible button — is also
                // what ReviewView's Esc already uses, and that one has
                // never been reported broken. The action here captures
                // nothing but `model` itself, so it was never actually at
                // risk of the stale-label-closure bug that motivated moving
                // it off this button in the first place.
                .keyboardShortcut(.escape, modifiers: [])
                Text("Burst \(compare.groupIndex + 1) — comparing \(compare.slots.count)")
                Spacer()
            }
            .buttonStyle(.glass)

            HStack {
                Spacer()
                ZoomSliderRow(controller: zoom)
                Spacer()
            }

            // Zoom/pan gestures live once on this whole area (not per-panel
            // — see the doc comment on `ZoomPanController.magnifyGesture`),
            // so pinching or dragging anywhere over the panels, including
            // the gaps between them, affects all of them together.
            Group {
                if compare.slots.count > 3 {
                    // Two HStacks in a VStack, not a LazyVGrid: a LazyVGrid
                    // outside a ScrollView sizes each row to its content's
                    // *ideal* height, and every panel asks for
                    // `.frame(maxHeight: .infinity)` — an unbounded
                    // request with no well-defined ideal — so the grid
                    // couldn't correctly compute or bound its row heights,
                    // which is what was clipping the bottom row. A plain
                    // HStack (used for the 2/3-panel case below, which
                    // never had this problem) correctly propagates a
                    // flexible child's size request up to itself, and
                    // VStack divides available height evenly between two
                    // of them the same way HStack divides width.
                    // Shaped to the burst's own photo aspect ratio (see
                    // `representativeAspectRatio`) rather than a plain
                    // square 2x2 — a landscape photo in a squarish cell
                    // otherwise gets letterboxed (blank margins left/right
                    // to preserve the whole photo), which is what the
                    // "gap" between panels actually was. Sizing the whole
                    // block to the photo's own ratio first means each cell
                    // ends up matching it almost exactly once divided,
                    // with any leftover space centered around the block
                    // instead of between individual photos.
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            panel(index: 0, compare: compare)
                            panel(index: 1, compare: compare)
                        }
                        HStack(spacing: 4) {
                            panel(index: 2, compare: compare)
                            panel(index: 3, compare: compare)
                        }
                    }
                    .aspectRatio(representativeAspectRatio(compare), contentMode: .fit)
                } else {
                    HStack(spacing: 4) {
                        ForEach(compare.slots.indices, id: \.self) { panel(index: $0, compare: compare) }
                    }
                    .aspectRatio(CGFloat(compare.slots.count) * representativeAspectRatio(compare), contentMode: .fit)
                }
            }
            .simultaneousGesture(zoom.magnifyGesture)

            // Mouse-clickable equivalents of the keyboard shortcuts, for
            // discoverability — all apply to the currently focused panel
            // (the one with the blue ring), same as their keyboard
            // counterparts in `shortcuts` below. A shared row under the
            // whole block rather than one per panel — with up to 4 panels
            // already dense, repeating a 4-button row that many times
            // would be more clutter than it's worth, and clicking a panel
            // to focus it before deciding is already a single click.
            HStack(spacing: 12) {
                Spacer()
                Button("Keep (K)") { model.decideFocusedComparePanel(.keep) }
                Button("Reject (X)") { model.decideFocusedComparePanel(.reject) }
                Button("Undo (U)") { model.decideFocusedComparePanel(.undecided) }
                Button("Single view (1)") { collapseToSingleView() }
                Button("Previous Burst (Shift+Tab)") { model.compareMoveBurst(-1) }
                    .padding(.leading, 20)
                Button("Next Burst (Tab)") { model.compareMoveBurst(1) }
                Spacer()
            }
            .buttonStyle(.glass)

            // The one bit of documentation still worth keeping here: these
            // are pure trackpad gestures with no button equivalent (there's
            // no sensible "button" for a pinch or a two-finger scroll), so
            // unlike everything else that used to be in this hint line,
            // they have no other way to be discovered.
            Text("Pinch to zoom, two-finger scroll to pan, double-click to reset zoom")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onChange(of: model.compareGroupExhausted()) { _, exhausted in
            if exhausted { model.compare = nil }
        }
        .onChange(of: compare.groupIndex) { _, _ in
            zoom.reset()
        }
        .background(shortcuts)
        .onAppear { zoom.installScrollPanMonitor() }
        .onDisappear { zoom.removeScrollPanMonitor() }
    }

    /// Every action reads current state from `model.compare` at call time
    /// — see ShortcutButton's doc comment on why this matters.
    @ViewBuilder
    private var shortcuts: some View {
        ShortcutButton(key: .leftArrow) { model.moveCompareFocus(deltaCol: -1, deltaRow: 0) }
        ShortcutButton(key: .rightArrow) { model.moveCompareFocus(deltaCol: 1, deltaRow: 0) }
        ShortcutButton(key: .upArrow) { model.moveCompareFocus(deltaCol: 0, deltaRow: -1) }
        ShortcutButton(key: .downArrow) { model.moveCompareFocus(deltaCol: 0, deltaRow: 1) }
        ShortcutButton(key: .tab) { model.compareMoveBurst(1) }
        ShortcutButton(key: .tab, modifiers: [.shift]) { model.compareMoveBurst(-1) }
        ShortcutButton(key: KeyEquivalent("k")) { model.decideFocusedComparePanel(.keep) }
        ShortcutButton(key: KeyEquivalent("x")) { model.decideFocusedComparePanel(.reject) }
        ShortcutButton(key: KeyEquivalent("u")) { model.decideFocusedComparePanel(.undecided) }
        ShortcutButton(key: KeyEquivalent("1")) { collapseToSingleView() }
    }

    private func collapseToSingleView() {
        guard let compare = model.compare, let path = compare.slots[compare.focused] else { return }
        let itemIndex = model.groups[compare.groupIndex].items.firstIndex { $0.path == path } ?? 0
        model.enterReview(groupIndex: compare.groupIndex, itemIndex: itemIndex)
    }

    /// Width/height of whichever visible slot has an image loaded yet,
    /// falling back to a plain 3:2 if none do (briefly possible right as
    /// Compare opens, before even the thumbnail has decoded). Bursts are
    /// effectively always one consistent camera orientation, so any loaded
    /// photo is a fine stand-in for shaping the whole panel block.
    private func representativeAspectRatio(_ compare: CompareState) -> CGFloat {
        for slot in compare.slots {
            guard let path = slot, let image = model.loupeCache[path] ?? model.thumbnails[path] else { continue }
            if image.height > 0 { return CGFloat(image.width) / CGFloat(image.height) }
        }
        return 3.0 / 2.0
    }

    @ViewBuilder
    private func panel(index: Int, compare: CompareState) -> some View {
        let path = compare.slots[index]
        let isFocused = index == compare.focused
        // Only the focused panel gets a border — with 2-4 photos already
        // side by side for direct comparison, a decision-color border on
        // every other panel too was just visual noise.
        let borderColor: Color = isFocused ? focusRingColor : .clear
        let borderWidth: CGFloat = isFocused ? 6 : 0

        Button {
            model.compare?.focused = index
        } label: {
            Group {
                // Prefer the full-resolution loupe image once it's loaded;
                // falling back to the 200px grid thumbnail (and never
                // switching off it) was why Compare looked blurry/"zoomed
                // in" — the low-res thumbnail was being stretched to fill
                // panels much larger than a grid cell.
                if let path, let image = model.loupeCache[path] ?? model.thumbnails[path] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom.zoomScale)
                        .offset(zoom.panOffset)
                        .onAppear { model.loadLoupeImage(path) }
                        // A panel's view identity stays put when its slot
                        // gets backfilled with a new photo (after deciding
                        // the old one) — onAppear only fires once, the
                        // first time a panel is ever shown, so without
                        // this the backfilled photo's loupe image was
                        // never requested at all and stayed stuck on the
                        // low-res thumbnail fallback indefinitely. Same
                        // pair of hooks ReviewView already uses for the
                        // same reason.
                        .onChange(of: path) { _, newPath in model.loadLoupeImage(newPath) }
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Filename and border are deliberately outside the scaleEffect/
            // offset/clipped chain above, applied to the panel itself
            // rather than the zoomable image — they used to zoom and pan
            // along with the photo, which pushed the border straight past
            // the clip bounds (invisible once zoomed) and sent the
            // filename label drifting around instead of staying put.
            .overlay(alignment: .bottom) {
                if let path {
                    Text(path.lastPathComponent)
                        .font(.caption)
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: borderWidth)
                    .shadow(color: borderColor.opacity(isFocused ? 0.95 : 0.6), radius: isFocused ? 8 : 3)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        // On the Button itself, not just the label's Group: a Button
        // doesn't become flexible just because its label wants to be, so
        // without this the button (and its clickable area) sized itself to
        // the label's small intrinsic content size, leaving a big gap
        // between panels — scaleEffect during a pinch was then just
        // visually enlarging that small render in place, which is why
        // zooming in looked like the photos "growing to fill" the panel.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .simultaneousGesture(zoom.doubleTapToResetGesture)
    }
}
