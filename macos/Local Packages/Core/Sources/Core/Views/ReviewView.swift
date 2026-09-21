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

            ReviewImageArea(model: model, path: path, decision: decision, zoom: zoom)
                .layoutPriority(1)

            actionButtons(itemIndex: itemIndex)
                .frame(maxWidth: .infinity)

            filmstrip(groupIndex: groupIndex, itemIndex: itemIndex, groupPaths: groupPaths)
        }
        .padding()
        .onAppear {
            model.loadLoupeImage(path)
            model.viewed.insert(path)
            zoom.installGestureMonitors()
        }
        .onDisappear {
            zoom.removeGestureMonitors()
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

/// Isolated from `ReviewView`'s main body so pinching only re-renders this
/// (the image, its border, the nav buttons) — not the header, action
/// button row, or filmstrip too. When this all lived inline in
/// `ReviewView.content`, reading `zoom.zoomScale`/`zoom.panOffset` here
/// made the *whole* body a dependent of them, so a pinch (driving those at
/// up to ~120Hz) re-evaluated everything else in the screen right along
/// with it — including, notably, the "Reset Zoom" button over in
/// `ZoomSliderRow`, whose underlying AppKit control being rebuilt that
/// rapidly is what was leaving it (and the slider) intermittently
/// unresponsive to clicks immediately after a pinch ended. Same fix
/// applied there for the same reason.
private struct ReviewImageArea: View {
    var model: AppModel
    let path: URL
    let decision: Decision
    var zoom: ZoomPanController

    var body: some View {
        // `.aspectRatio(ratio, .fit)` followed by
        // `.frame(maxWidth: .infinity, maxHeight: .infinity)` does NOT do
        // what it looks like it does: the flexible frame expands this
        // view's own reported bounds back to the full available area, so
        // anything overlaid *after* it (the border, the nav buttons) was
        // anchored to that full area, not the smaller letterboxed photo
        // inside it — confirmed by literally rendering the old version
        // with `ImageRenderer` and looking at the pixels. A GeometryReader
        // with the fitted size worked out explicitly sidesteps that
        // entirely: nothing here is asked to infer a shape from an
        // ambiguous modifier chain.
        GeometryReader { geo in
            let ratio = imageAspectRatio(model.loupeCache[path])
            let available = geo.size
            let center = CGPoint(x: available.width / 2, y: available.height / 2)
            // Nav buttons are a separate ZStack layer, not an overlay on
            // the photo's own frame — an overlay(alignment:) sits AT the
            // edge of (and so on top of) the view it's attached to, i.e.
            // on top of the photo, not outside it.
            let buttonRadius: CGFloat = 22
            let buttonGap: CGFloat = 12
            // Reserved BEFORE computing the photo's own fitted size —
            // clamping the button positions to the available area (the
            // previous approach) falls apart once the photo is zoomed
            // enough to fill that whole area itself: there's no room left
            // outside it, so the clamp just pulls the buttons back on top
            // of the photo. Reserving this margin up front means the
            // photo can never grow to consume it in the first place, so
            // the buttons always have somewhere to be, at any zoom level.
            let sideReserve = buttonRadius * 2 + buttonGap + 8
            let photoAvailableWidth = max(available.width - sideReserve * 2, 100)
            let fitted = photoAvailableWidth / available.height > ratio
                ? CGSize(width: available.height * ratio, height: available.height)
                : CGSize(width: photoAvailableWidth, height: photoAvailableWidth / ratio)
            // Grows past the letterboxed size as you zoom in — capped at
            // the (margin-reserved) available area — so zooming actually
            // reveals more of the photo instead of just cropping tighter
            // inside a frame stuck at the unzoomed size.
            let visible = CGSize(
                width: min(photoAvailableWidth, fitted.width * zoom.liveScale),
                height: min(available.height, fitted.height * zoom.liveScale)
            )
            let leftX = center.x - visible.width / 2 - buttonGap - buttonRadius
            let rightX = center.x + visible.width / 2 + buttonGap + buttonRadius

            ZStack {
                Group {
                    if let image = model.loupeCache[path] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(zoom.liveScale)
                            .offset(zoom.panOffset)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: visible.width, height: visible.height)
                .clipped()
                // Only an explicit Keep/Reject gets a border — an
                // "undecided" photo (viewed or not) showing a gray/yellow
                // border was never really conveying anything actionable,
                // just noise on every photo you hadn't decided on yet.
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(decision == .undecided ? .clear : decision.color, lineWidth: 6)
                        .shadow(color: decision == .undecided ? .clear : decision.color.opacity(0.8), radius: 6)
                )
                .overlay(alignment: .bottom) {
                    Text(path.lastPathComponent)
                        .font(.caption)
                        .padding(4)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(.white)
                }
                .position(x: center.x, y: center.y)
                .onHover { zoom.isHovering = $0 }
                .simultaneousGesture(zoom.doubleTapToResetGesture)

                Button {
                    model.reviewMove(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .position(x: leftX, y: center.y)

                Button {
                    model.reviewMove(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .position(x: rightX, y: center.y)
            }
        }
        .padding(4)
    }

    /// Width/height of the loaded image, falling back to a plain 3:2 while
    /// it's still decoding. Matches `CompareView.representativeAspectRatio`.
    private func imageAspectRatio(_ image: CGImage?) -> CGFloat {
        guard let image, image.height > 0 else { return 3.0 / 2.0 }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}
