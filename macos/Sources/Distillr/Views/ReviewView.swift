import SwiftUI

struct ReviewView: View {
    @Bindable var model: AppModel

    /// See `ZoomPanController`'s doc comment — shared with `CompareView`,
    /// this instance is just for the one image here.
    @State private var zoom = ZoomPanController()

    var body: some View {
        if let review = model.review, let path = model.currentReviewPath() {
            content(review: review, path: path)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(review: ReviewState, path: URL) -> some View {
        let groupIndex = review.groupIndex
        let itemIndex = review.itemIndex
        let groupPaths = model.groups[groupIndex].items.map(\.path)
        let decision = model.decisions[path] ?? .undecided

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Burst \(groupIndex + 1) — photo \(itemIndex + 1) of \(groupPaths.count)")
                Text(decision.label).foregroundStyle(decision.color)
                Spacer()
            }

            HStack {
                Spacer()
                ZoomSliderRow(controller: zoom)
                Spacer()
            }

            HStack(spacing: 12) {
                Button("Previous (←)") { model.reviewMove(-1) }
                    .buttonStyle(.glass)

                if let image = model.loupeCache[path] {
                    // Only an explicit Keep/Reject gets a border — an
                    // "undecided" photo (viewed or not) showing a
                    // gray/yellow border was never really conveying
                    // anything actionable, just noise on every photo you
                    // hadn't decided on yet. Border and pinch/pan work the
                    // same way as Compare's panels: border applied *after*
                    // the scaleEffect/clip, not before, so it stays fixed
                    // and visible instead of zooming/panning off-screen
                    // along with the photo.
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom.zoomScale)
                        .offset(zoom.panOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(decision == .undecided ? .clear : decision.color, lineWidth: 6)
                                .shadow(color: decision == .undecided ? .clear : decision.color.opacity(0.8), radius: 6)
                        )
                        .padding(4)
                        .layoutPriority(1)
                        .simultaneousGesture(zoom.magnifyGesture)
                        .simultaneousGesture(zoom.doubleTapToResetGesture)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                }

                Button("Next (→)") { model.reviewMove(1) }
                    .buttonStyle(.glass)
            }

            actionButtons(itemIndex: itemIndex)
                .frame(maxWidth: .infinity)

            filmstrip(groupIndex: groupIndex, itemIndex: itemIndex, groupPaths: groupPaths)
        }
        .padding()
        .onAppear {
            model.loadLoupeImage(path)
            model.viewed.insert(path)
            zoom.installScrollPanMonitor()
        }
        .onDisappear {
            zoom.removeScrollPanMonitor()
        }
        .onChange(of: path) { _, newPath in
            model.loadLoupeImage(newPath)
            model.viewed.insert(newPath)
            zoom.reset()
        }
        .background(shortcuts)
    }

    /// Every action here reads current state from `model.review`/
    /// `model.currentReviewPath()` at call time — never a locally captured
    /// snapshot — so it can't go stale regardless of which render created
    /// the closure instance SwiftUI happens to invoke.
    @ViewBuilder
    private var shortcuts: some View {
        ShortcutButton(key: .leftArrow) { model.reviewMove(-1) }
        ShortcutButton(key: .rightArrow) { model.reviewMove(1) }
        ShortcutButton(key: .tab) { model.reviewMoveBurst(1) }
        ShortcutButton(key: .tab, modifiers: [.shift]) { model.reviewMoveBurst(-1) }
        ShortcutButton(key: KeyEquivalent("k")) { decide(.keep) }
        ShortcutButton(key: KeyEquivalent("x")) { decide(.reject) }
        ShortcutButton(key: KeyEquivalent("u")) { decide(.undecided) }
        ShortcutButton(key: KeyEquivalent("2")) { expandToCompare(2) }
        ShortcutButton(key: KeyEquivalent("3")) { expandToCompare(3) }
        ShortcutButton(key: KeyEquivalent("4")) { expandToCompare(4) }
    }

    /// Mouse-clickable equivalents of the same keyboard shortcuts, for
    /// discoverability — every action here is identical to (and shares the
    /// implementation with) its `shortcuts` counterpart above.
    @ViewBuilder
    private func actionButtons(itemIndex: Int) -> some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Back to grid (Esc)") { model.review = nil }
                .keyboardShortcut(.escape, modifiers: [])
            Button("Keep (K)") { decide(.keep) }
                .padding(.leading, 20)
            Button("Reject (X)") { decide(.reject) }
            Button("Undo (U)") { decide(.undecided) }
            Button("Split burst here (S)") {
                // Reads fresh from model.review rather than the itemIndex
                // parameter above — see ShortcutButton's doc comment on
                // the stale-closure SwiftUI bug this avoids.
                guard let review = model.review else { return }
                model.splitGroup(before: review.itemIndex, in: review.groupIndex)
            }
            .keyboardShortcut(KeyEquivalent("s"), modifiers: [])
            .disabled(itemIndex == 0)
            .help("This photo and everything after it becomes a new burst — use when continuous shooting merged unrelated moments together.")
            .padding(.leading, 20)
            Button("Previous Burst (Shift+Tab)") { model.reviewMoveBurst(-1) }
            Button("Next Burst (Tab)") { model.reviewMoveBurst(1) }
            Spacer()
        }
        .buttonStyle(.glass)
    }

    private func decide(_ decision: Decision) {
        guard let path = model.currentReviewPath() else { return }
        model.decisions[path] = decision
        model.reviewMove(1)
    }

    private func expandToCompare(_ count: Int) {
        guard let review = model.review else { return }
        let seed = model.activePaths(from: review.groupIndex, startIndex: review.itemIndex, count: count)
        model.enterCompare(groupIndex: review.groupIndex, paths: seed)
    }

    @ViewBuilder
    private func filmstrip(groupIndex: Int, itemIndex: Int, groupPaths: [URL]) -> some View {
        // Explicit height: a horizontal-only ScrollView has no bounded
        // intrinsic height of its own (unlike its fixed-size thumbnail
        // content), so left unconstrained it was competing with the main
        // image for the VStack's leftover vertical space — splitting it
        // roughly evenly instead of giving nearly all of it to the photo.
        ScrollView(.horizontal) {
            LazyHStack(spacing: 4) {
                ForEach(Array(model.groups[groupIndex].items.enumerated()), id: \.offset) { i, item in
                    if (model.decisions[item.path] ?? .undecided) != .reject {
                        Button {
                            model.review?.itemIndex = i
                        } label: {
                            BorderedThumbnail(
                                image: model.thumbnails[item.path],
                                decisionColor: model.borderColor(for: item.path),
                                accentRing: i == itemIndex,
                                size: 56
                            )
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
            }
        }
        .frame(height: 76)
    }
}
