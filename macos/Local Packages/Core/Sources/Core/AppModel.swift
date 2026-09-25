import CoreGraphics
import Foundation
import Observation
import SwiftUI

struct ReviewState: Equatable {
    var groupIndex: Int
    var itemIndex: Int
}

let maxComparePanels = 4

/// How many photos on each side of the current review position to
/// proactively decode ahead of time, so arrow-key navigation feels instant
/// instead of waiting on a fresh decode.
let loupePrefetchRadius = 4
/// How many photos on each side of the current position `loupeCache`
/// keeps once loaded — wider than the prefetch radius so browsing back and
/// forth a little doesn't keep re-decoding photos you just moved past.
let loupeCacheKeepRadius = 9

struct CompareState: Equatable {
    var groupIndex: Int
    /// One entry per visible panel. `nil` means the slot ran out of
    /// replacement photos (everything else in the group got decided).
    var slots: [URL?]
    var focused: Int
}

/// Keyboard cursor over the grid's thumbnails. `activeIndex` indexes into
/// that group's list of currently-visible (non-rejected) thumbnails, not
/// the group's full item list.
struct GridFocus: Equatable {
    var groupIndex: Int
    var activeIndex: Int
}

@MainActor
@Observable
public final class AppModel {
    /// Explicit and public even though every stored property already has a
    /// default (which would otherwise synthesize this for free): a
    /// synthesized init only ever matches the *type's* access level when
    /// the type is a struct — for a class it's `internal` regardless, so
    /// the app target (a separate module) couldn't call `AppModel()`
    /// without this.
    public init() {}

    var sourceFolder: URL?
    var groups: [BurstGroup] = []
    var thumbnails: [URL: CGImage] = [:]
    var thumbnailsTotal: Int = 0
    var unreadableCount: Int = 0
    var status: String = ""
    var decisions: [URL: Decision] = [:]
    var viewed: Set<URL> = []
    var review: ReviewState?
    var loupeCache: [URL: CGImage] = [:]
    private var loupeLoadsInFlight: Set<URL> = []
    var showFinalize = false
    var finalizeTrashRejected = true
    var finalizeCopyKeepers = true
    /// Whether an Undecided photo counts as a keeper for Finalize's copy
    /// step. Defaults on, matching the old unconditional behavior (a
    /// review pass mostly presses X on the bad shots, so a photo you
    /// never explicitly marked shouldn't be silently excluded) — but now
    /// it's an explicit choice in `FinalizeSheet` rather than baked in.
    var finalizeTreatUndecidedAsKeepers = true
    var finalizeDestination: URL?
    /// Set by `validateFinalizeDestination()` — a human-readable reason
    /// `finalizeDestination` can't actually be written to, or `nil` if it's
    /// fine (or unchecked). Surfaced inline in `FinalizeSheet` so a
    /// permission problem (e.g. App Sandbox denying write access to a
    /// folder that otherwise looks fine) is caught before Finalize runs,
    /// not after it's already failed to copy anything.
    var finalizeDestinationError: String?
    var commitStatus: String?
    /// Multi-selected thumbnails in the grid, used to seed Compare mode.
    /// Entirely separate from `reviewSelection` below — deliberately so,
    /// to keep a Grid Cmd-click selection in one burst from ever being
    /// swept up by a bulk Keep/Reject made while reviewing a different one.
    var selected: Set<URL> = []
    /// The run of photos a `Shift`-extended selection in Review currently
    /// spans — `K`/`X`/`U` apply to all of them when non-empty, instead of
    /// just the current photo. See `extendReviewSelection`.
    var reviewSelection: Set<URL> = []
    /// Where the current Review range-select gesture started — an index
    /// into `review!.groupIndex`'s full item list (the same addressing
    /// `review.itemIndex` itself uses), not Grid's active-list-relative
    /// `GridFocus.activeIndex`. `nil` when there's no selection in progress.
    private var reviewSelectionAnchor: Int?
    var compare: CompareState?
    var gridFocus: GridFocus?
    /// Kept in sync by `GridView` from its `GeometryReader` width, so the
    /// Return-key shortcut (which has no view geometry of its own) can
    /// pass the right row stride to `moveGridFocus`.
    var gridColumnsPerRow = 1

    private var thumbnailLoadTask: Task<Void, Never>?

    // MARK: - Loading

    func loadFolder(_ folder: URL) {
        groups = []
        thumbnails = [:]
        thumbnailLoadTask?.cancel()
        thumbnailLoadTask = nil
        decisions = [:]
        viewed = []
        review = nil
        loupeCache = [:]
        showFinalize = false
        finalizeDestination = nil
        finalizeDestinationError = nil
        commitStatus = nil
        selected = []
        reviewSelection = []
        reviewSelectionAnchor = nil
        compare = nil
        gridFocus = nil

        let sources: [PhotoSource]
        do {
            sources = try PhotoScanner.scanFolder(folder)
        } catch {
            status = "Could not read \(folder.path): \(error.localizedDescription)"
            sourceFolder = folder
            return
        }

        // Metadata is a cheap EXIF-header read, so grouping by capture time
        // can happen synchronously and show the grid immediately — full
        // image decode (thumbnails) happens in the background afterward.
        // Bursts group by capture-time proximity only; if continuous
        // shooting merges unrelated moments together, split the group
        // manually from Review (see `splitGroup(before:in:)`).
        var items: [BurstItem] = []
        var unreadable = 0
        for source in sources {
            if let meta = try? MetadataReader.readMetadata(source.primary) {
                items.append(BurstItem(path: source.primary, sidecar: source.sidecar, captureTime: meta.captureTime))
            } else {
                unreadable += 1
            }
        }

        groups = BurstGrouping.groupBursts(items)

        let pathsToLoad = groups.flatMap { $0.items.map(\.path) }
        thumbnailsTotal = pathsToLoad.count
        unreadableCount = unreadable
        refreshStatus()
        sourceFolder = folder

        thumbnailLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (URL, CGImage?).self) { group in
                for path in pathsToLoad {
                    group.addTask {
                        // No resolution verification for grid thumbnails —
                        // see ThumbnailLoader.decodeImage's doc comment:
                        // trusting the cheap embedded preview outright
                        // (skipping a full JPEG decode/demosaic for every
                        // photo) is what makes the initial folder load fast.
                        (path, ThumbnailLoader.decodeImage(path, maxPixelSize: thumbnailMaxSide, verifyResolution: false))
                    }
                }
                for await (path, image) in group {
                    guard let image else { continue }
                    await self?.recordThumbnail(image, for: path)
                }
            }
        }
    }

    private func recordThumbnail(_ image: CGImage, for path: URL) {
        thumbnails[path] = image
    }

    /// Recomputes the "N photos in M burst groups" status line from current
    /// counts. Called after the initial load, and again whenever a manual
    /// split changes the group count, so the text never goes stale.
    func refreshStatus() {
        var text = "\(thumbnailsTotal) photos in \(groups.count) burst groups"
        if unreadableCount > 0 {
            text += " (\(unreadableCount) could not be read)"
        }
        status = text
    }

    // MARK: - Manual burst split

    /// Manually splits `groupIndex` into two groups at `itemIndex`: the
    /// items before it stay in place, `itemIndex` and everything after it
    /// become a new group immediately following. For continuous-shooting
    /// bursts where capture-time proximity alone merged unrelated moments
    /// together. A no-op if `itemIndex` is 0 (nothing to split off) or out
    /// of range.
    func splitGroup(before itemIndex: Int, in groupIndex: Int) {
        guard let group = groups[safe: groupIndex] else { return }
        guard itemIndex > 0, itemIndex < group.items.count else { return }

        var first = group
        let secondItems = Array(first.items[itemIndex...])
        first.items = Array(first.items[..<itemIndex])
        let second = BurstGroup(items: secondItems)
        groups.replaceSubrange(groupIndex...groupIndex, with: [first, second])
        refreshStatus()

        if var r = review {
            if r.groupIndex == groupIndex, r.itemIndex >= itemIndex {
                r.groupIndex += 1
                r.itemIndex -= itemIndex
                review = r
            } else if r.groupIndex > groupIndex {
                r.groupIndex += 1
                review = r
            }
        }
        if let c = compare, c.groupIndex == groupIndex {
            // Slots may now span both halves — no single group to point
            // back at, so drop out rather than leave it stale.
            compare = nil
        }
        if var c = compare, c.groupIndex > groupIndex {
            c.groupIndex += 1
            compare = c
        }
        if let f = gridFocus, f.groupIndex == groupIndex {
            // activeIndex is into the pre-split active list; simplest to
            // just drop the cursor than to recompute which half it now
            // falls in.
            gridFocus = nil
        }
        if var f = gridFocus, f.groupIndex > groupIndex {
            f.groupIndex += 1
            gridFocus = f
        }
    }

    // MARK: - Review

    /// Opens review on `itemIndex`, or the nearest non-rejected item if
    /// that one has already been rejected (e.g. the plain "Review" action
    /// always requests index 0, which may itself be rejected).
    func enterReview(groupIndex: Int, itemIndex: Int) {
        let target = nearestActiveIndex(groupIndex: groupIndex, from: itemIndex) ?? itemIndex
        review = ReviewState(groupIndex: groupIndex, itemIndex: target)
        clearReviewSelection()
        prefetchLoupeNeighbors()
    }

    func currentReviewPath() -> URL? {
        guard let review, let group = groups[safe: review.groupIndex] else { return nil }
        return group.items[safe: review.itemIndex]?.path
    }

    func isActive(_ group: BurstGroup, _ index: Int) -> Bool {
        guard let item = group.items[safe: index] else { return false }
        return (decisions[item.path] ?? .undecided) != .reject
    }

    /// Finds the nearest non-rejected item to `fromIndex` in `groupIndex`:
    /// `fromIndex` itself if active, otherwise the closest active item
    /// scanning forward, then backward. `nil` if every item is rejected.
    func nearestActiveIndex(groupIndex: Int, from fromIndex: Int) -> Int? {
        guard let group = groups[safe: groupIndex] else { return nil }
        if isActive(group, fromIndex) { return fromIndex }
        let forwardStart = fromIndex + 1
        if forwardStart < group.items.count,
           let found = (forwardStart..<group.items.count).first(where: { isActive(group, $0) }) {
            return found
        }
        if fromIndex > 0, let found = (0..<fromIndex).reversed().first(where: { isActive(group, $0) }) {
            return found
        }
        return nil
    }

    /// True once every photo in the group currently under review has been
    /// rejected — nothing left to show, so review should fall back to the
    /// grid.
    func reviewGroupExhausted() -> Bool {
        guard let review else { return false }
        return nearestActiveIndex(groupIndex: review.groupIndex, from: review.itemIndex) == nil
    }

    /// True once every item in `groupIndex` has an explicit decision (Keep
    /// or Reject) — nothing left undecided, as opposed to
    /// `reviewGroupExhausted`, which is about nothing left *active*
    /// (non-rejected) to show.
    func groupFullyDecided(_ groupIndex: Int) -> Bool {
        guard let group = groups[safe: groupIndex] else { return true }
        return group.items.allSatisfy { (decisions[$0.path] ?? .undecided) != .undecided }
    }

    /// Moves Review to the first active item of the next (`delta` = 1) or
    /// previous (`delta` = -1) burst group. Clamped at the ends — no
    /// wraparound — and a no-op when not currently in Review.
    func reviewMoveBurst(_ delta: Int) {
        guard let groupIndex = review?.groupIndex else { return }
        let target = groupIndex + delta
        guard target >= 0, target < groups.count else { return }
        enterReview(groupIndex: target, itemIndex: 0)
    }

    /// Up to `count` active photos in `groupIndex`, starting at
    /// `startIndex` and scanning forward — used to seed Compare mode from
    /// within single-photo Review (current photo + the next few). Backfills
    /// from earlier active photos when the forward scan comes up short
    /// (e.g. starting near the end of a short burst), so a burst with
    /// exactly `count` active photos always shows all of them regardless of
    /// which one you started on.
    func activePaths(from groupIndex: Int, startIndex: Int, count: Int) -> [URL] {
        guard let group = groups[safe: groupIndex] else { return [] }

        var indices: [Int] = []
        if startIndex < group.items.count {
            indices = Array((startIndex..<group.items.count).filter { isActive(group, $0) }.prefix(count))
        }

        if indices.count < count {
            let missing = count - indices.count
            var backward: [Int] = []
            if startIndex > 0 {
                backward = Array((0..<startIndex).reversed().filter { isActive(group, $0) }.prefix(missing))
            }
            backward.reverse()
            indices = backward + indices
        }

        return indices.map { group.items[$0].path }
    }

    /// Active (non-rejected) index `delta` steps from `start` in `group`,
    /// skipping over rejected items along the way and clamping at either
    /// end — shared stepping logic for `reviewMove` and
    /// `extendReviewSelection`, so a plain arrow and a Shift-extended one
    /// always land on the same photo for the same delta.
    private func steppedActiveIndex(from start: Int, delta: Int, in group: BurstGroup) -> Int? {
        let len = group.items.count
        guard len > 0 else { return nil }

        let active: [Bool] = (0..<len).map { isActive(group, $0) }
        let step = delta >= 0 ? 1 : -1
        var idx = start
        var target: Int? = (start < active.count && active[start]) ? start : nil
        var remaining = abs(delta)

        while remaining > 0 {
            let next = idx + step
            if next < 0 || next >= len { break }
            idx = next
            if active[idx] {
                target = idx
                remaining -= 1
            }
        }
        return target
    }

    /// Moves the current review item by `delta` steps, counting only
    /// non-rejected items and skipping over rejected ones — so arrowing
    /// through a group never lands on (or passes visibly through) a photo
    /// that's already been rejected. Clamps at the nearest active item to
    /// either end once there's nothing further to move to. A plain
    /// (non-extending) move always collapses any in-progress Shift-range
    /// selection, matching how Finder/text selection behaves elsewhere.
    func reviewMove(_ delta: Int) {
        guard let review else { return }
        let groupIndex = review.groupIndex
        let start = review.itemIndex
        guard let group = groups[safe: groupIndex] else { return }

        // Nothing found in the requested direction — this happens when the
        // starting item was just rejected and was the last active item
        // that way (e.g. rejecting the last photo in the group). Fall back
        // to the nearest active item in either direction, so rejecting the
        // last photo re-selects the previous one instead of leaving the
        // just-rejected photo showing.
        let target = steppedActiveIndex(from: start, delta: delta, in: group)
            ?? nearestActiveIndex(groupIndex: groupIndex, from: start)

        if let target {
            self.review?.itemIndex = target
            clearReviewSelection()
            prefetchLoupeNeighbors()
        }
    }

    /// Extends (or starts) a Finder-style anchored range selection by
    /// `delta` active steps from the current position — the arrow-key
    /// entry point, sharing `reviewMove`'s own stepping logic so a
    /// Shift-held arrow always lands on the same photo a plain one would.
    func extendReviewSelection(_ delta: Int) {
        guard let review else { return }
        let groupIndex = review.groupIndex
        guard let group = groups[safe: groupIndex] else { return }
        guard let target = steppedActiveIndex(from: review.itemIndex, delta: delta, in: group) else { return }
        applyReviewSelectionRange(to: target, groupIndex: groupIndex, group: group)
    }

    /// Click entry point for the filmstrip's Shift-click range-select —
    /// same anchored-range behavior as `extendReviewSelection(_:)`, just
    /// from a direct target index instead of a step count.
    func extendReviewSelection(to targetIndex: Int) {
        guard let review else { return }
        let groupIndex = review.groupIndex
        guard let group = groups[safe: groupIndex], group.items[safe: targetIndex] != nil else { return }
        applyReviewSelectionRange(to: targetIndex, groupIndex: groupIndex, group: group)
    }

    /// Shared by both `extendReviewSelection` entry points: seeds the
    /// anchor from the current position if this is a fresh gesture, moves
    /// `review.itemIndex` to `target`, then recomputes `reviewSelection`
    /// as exactly the active items between anchor and target (inclusive)
    /// — a full recompute every call, not an incremental add, so moving
    /// back genuinely shrinks the selection instead of just stopping.
    private func applyReviewSelectionRange(to target: Int, groupIndex: Int, group: BurstGroup) {
        let anchor = reviewSelectionAnchor ?? review!.itemIndex
        reviewSelectionAnchor = anchor
        review?.itemIndex = target

        let lo = min(anchor, target)
        let hi = max(anchor, target)
        reviewSelection = Set((lo...hi).compactMap { i in
            isActive(group, i) ? group.items[i].path : nil
        })
        prefetchLoupeNeighbors()
    }

    /// Clears any in-progress Review range selection.
    func clearReviewSelection() {
        reviewSelection = []
        reviewSelectionAnchor = nil
    }

    /// Records `decision` for the current review photo — or, if a
    /// Shift-extended range is active, for every photo in it at once —
    /// then advances: mirrors `reviewMove(1)`'s usual "step to the next
    /// active item" EXCEPT when this decision was the last undecided item
    /// in the burst, in which case there's nothing left to review here, so
    /// it jumps straight to the next burst instead of leaving you cycling
    /// back and forth through already-decided (kept) photos. A no-op burst
    /// jump at the very last group (same clamping `reviewMoveBurst` always
    /// does) just leaves the final decided photo on screen.
    func decideCurrentReviewItem(_ decision: Decision) {
        guard let review else { return }

        guard !reviewSelection.isEmpty else {
            guard let path = currentReviewPath() else { return }
            decisions[path] = decision
            if groupFullyDecided(review.groupIndex) {
                reviewMoveBurst(1)
            } else {
                reviewMove(1)
            }
            return
        }

        let groupIndex = review.groupIndex
        let fromIndex = review.itemIndex
        for path in reviewSelection {
            decisions[path] = decision
        }
        clearReviewSelection()

        if groupFullyDecided(groupIndex) {
            reviewMoveBurst(1)
        } else {
            // `groupFullyDecided` false guarantees at least one Undecided
            // (and so active) item remains somewhere in the group, so
            // `nearestActiveIndex` always finds one from here.
            self.review?.itemIndex = nearestActiveIndex(groupIndex: groupIndex, from: fromIndex) ?? fromIndex
            prefetchLoupeNeighbors()
        }
    }

    /// Decodes off the main actor — a synchronous decode here would block
    /// the UI thread on every arrow-key press, which is exactly what made
    /// navigating Review feel slow. `loupeCache` fills in once the
    /// background decode finishes; the view shows a spinner until then.
    /// Returns the underlying task (`nil` if there was nothing to do — see
    /// `prefetchLoupeNeighbors`, which awaits it before starting on
    /// neighbors) so the current photo's decode isn't racing several
    /// prefetch decodes for a slot nobody's looking at yet.
    @discardableResult
    func loadLoupeImage(_ path: URL) -> Task<Void, Never>? {
        if loupeCache[path] != nil || loupeLoadsInFlight.contains(path) { return nil }
        loupeLoadsInFlight.insert(path)
        return Task.detached(priority: .userInitiated) { [weak self] in
            let image = ThumbnailLoader.decodeImage(path, maxPixelSize: loupeMaxSide)
            await self?.finishLoupeLoad(path, image: image)
        }
    }

    private func finishLoupeLoad(_ path: URL, image: CGImage?) {
        loupeLoadsInFlight.remove(path)
        if let image {
            loupeCache[path] = image
        }
        pruneLoupeCache()
    }

    /// Bounds `loupeCache` to roughly what's on screen or about to be — the
    /// current review item and its prefetched neighbors, plus everything
    /// visible in Compare — rather than letting it grow for the whole
    /// session. At `loupeMaxSide`, each cached decode is tens of MB;
    /// reviewing a few hundred photos before Finalize (nothing is removed
    /// from `loupeCache` just by deciding a photo, only by trashing it)
    /// would otherwise keep every one of them resident at once. Runs after
    /// every load, i.e. essentially every navigation step, rather than on
    /// a timer — cheap enough that there's no reason to defer it.
    private func pruneLoupeCache() {
        var keep: Set<URL> = []
        if let review, let group = groups[safe: review.groupIndex] {
            for offset in -loupeCacheKeepRadius...loupeCacheKeepRadius {
                if let path = group.items[safe: review.itemIndex + offset]?.path {
                    keep.insert(path)
                }
            }
        }
        if let compare {
            keep.formUnion(compare.slots.compactMap { $0 })
        }
        loupeCache = loupeCache.filter { keep.contains($0.key) }
    }

    /// Kicks off (backgrounded) decode of the current review photo, then —
    /// only once that one's actually done — its next `loupePrefetchRadius`
    /// neighbors on each side, so by the time you press the arrow key
    /// again the next image is very likely already cached instead of
    /// decoding on the keypress itself.
    ///
    /// The neighbors deliberately wait on the current photo's own decode
    /// rather than firing off alongside it: entering Review used to kick
    /// off 3 full-resolution decodes simultaneously (current + 2
    /// neighbors), which was enough concurrent pressure on ImageIO's
    /// decode pipeline to intermittently log "IOSurface creation failed"
    /// (harmless — everything still decoded fine — but avoidable). There's
    /// no real need for the neighbors to race the one photo you're
    /// actually looking at right now.
    private func prefetchLoupeNeighbors() {
        guard let review, let group = groups[safe: review.groupIndex] else { return }
        guard let currentPath = group.items[safe: review.itemIndex]?.path else { return }

        let currentLoad = loadLoupeImage(currentPath)
        Task { [weak self] in
            await currentLoad?.value
            guard let self else { return }
            for offset in 1...loupePrefetchRadius {
                if let path = group.items[safe: review.itemIndex + offset]?.path {
                    self.loadLoupeImage(path)
                }
                if let path = group.items[safe: review.itemIndex - offset]?.path {
                    self.loadLoupeImage(path)
                }
            }
        }
    }

    // MARK: - Compare

    func enterCompare(groupIndex: Int, paths: [URL]) {
        guard !paths.isEmpty else { return }
        // `review` is deliberately left as-is (not nilled out): when Compare
        // was reached from Review (2/3/4), leaving it set means Esc — which
        // just clears `compare` — naturally falls back to the single-photo
        // Review view instead of skipping past it to the grid. When Compare
        // is reached from the grid's multi-select instead, `review` is
        // already nil, so this is a no-op there.
        compare = CompareState(groupIndex: groupIndex, slots: Array(paths.prefix(maxComparePanels)).map { $0 }, focused: 0)
    }

    /// Up to `needed` active photos in `groupIndex` not already occupying a
    /// Compare slot — used to refill a slot after its photo is decided, or
    /// to add slots when the panel count grows.
    func compareBackfillCandidates(groupIndex: Int, exclude: Set<URL>, needed: Int) -> [URL] {
        guard let group = groups[safe: groupIndex] else { return [] }
        return Array(
            (0..<group.items.count)
                .filter { isActive(group, $0) }
                .map { group.items[$0].path }
                .filter { !exclude.contains($0) }
                .prefix(needed)
        )
    }

    /// Resizes the visible panel count, backfilling new slots with active
    /// photos not already shown. Shrinking just drops the trailing slots —
    /// nothing is decided for them, so no state needs cleaning up.
    func resizeCompare(_ requestedPanelCount: Int) {
        let panelCount = min(max(requestedPanelCount, 1), maxComparePanels)
        guard let compareState = compare else { return }
        let groupIndex = compareState.groupIndex
        let currentLen = compareState.slots.count

        if panelCount <= currentLen {
            compare?.slots = Array(compareState.slots.prefix(max(panelCount, 1)))
            if let focused = compare?.focused, let count = compare?.slots.count, focused >= count {
                compare?.focused = max(count - 1, 0)
            }
            return
        }

        let shown = Set(compareState.slots.compactMap { $0 })
        let missing = panelCount - currentLen
        var freshIterator = compareBackfillCandidates(groupIndex: groupIndex, exclude: shown, needed: missing).makeIterator()
        while let count = compare?.slots.count, count < panelCount {
            compare?.slots.append(freshIterator.next())
        }
    }

    /// Moves panel focus by `deltaCol` (Left/Right, one panel at a time)
    /// and `deltaRow` (Up/Down). In the 2x2 layout (4 panels) a row step is
    /// 2 positions, matching the two-column grid; in the single-row layout
    /// (2-3 panels) a row step wraps back to the same panel, since there's
    /// nothing above or below to move to. Wraps around at the ends.
    func moveCompareFocus(deltaCol: Int, deltaRow: Int) {
        guard let compareState = compare else { return }
        let len = compareState.slots.count
        guard len > 0 else { return }
        let rowStride = len > 3 ? 2 : len
        let delta = deltaCol + deltaRow * rowStride
        compare?.focused = ((compareState.focused + delta) % len + len) % len
    }

    /// Moves Compare to the next (`delta` = 1) or previous (`delta` = -1)
    /// burst group, keeping the same panel count and re-seeding from that
    /// group's first active photos. Clamped at the ends — no wraparound —
    /// and a no-op when not currently in Compare.
    func compareMoveBurst(_ delta: Int) {
        guard let compareState = compare else { return }
        let target = compareState.groupIndex + delta
        guard target >= 0, target < groups.count else { return }
        let seed = activePaths(from: target, startIndex: 0, count: compareState.slots.count)
        enterCompare(groupIndex: target, paths: seed)
    }

    /// Records `decision` for whichever photo is in the focused panel, then
    /// refills that panel with the next available undecided photo from the
    /// group — mirrors how single-photo review auto-advances after any
    /// decision. When there's nothing left to refill it with, the panel
    /// count shrinks by one instead of leaving a dead empty slot; shrinking
    /// to a single panel isn't really "comparing" anymore, so that falls
    /// back to single-photo Review on whatever's left, and shrinking to
    /// zero (the group's now fully decided) exits Compare entirely.
    func decideFocusedComparePanel(_ decision: Decision) {
        guard let compareState = compare else { return }
        let groupIndex = compareState.groupIndex
        let focused = compareState.focused
        guard let path = compareState.slots[safe: focused] ?? nil else { return }

        decisions[path] = decision

        let shown = Set((compare?.slots ?? []).compactMap { $0 })
        let replacement = compareBackfillCandidates(groupIndex: groupIndex, exclude: shown, needed: 1).first

        if let replacement {
            compare?.slots[focused] = replacement
            return
        }

        compare?.slots.remove(at: focused)
        guard let remainingCount = compare?.slots.count else { return }
        if remainingCount <= 1 {
            let remainingPath = compare?.slots.first ?? nil
            compare = nil
            if let remainingPath, let itemIndex = groups[safe: groupIndex]?.items.firstIndex(where: { $0.path == remainingPath }) {
                enterReview(groupIndex: groupIndex, itemIndex: itemIndex)
            } else {
                reconcileReviewAfterExitingCompare()
            }
        } else if focused >= remainingCount {
            compare?.focused = remainingCount - 1
        }
    }

    /// Clears Compare and returns to whichever of Review/Grid was
    /// underneath — the shared exit path for Esc/"Back to review" and for
    /// auto-exiting when there's nothing left to compare.
    func exitCompare() {
        compare = nil
        reconcileReviewAfterExitingCompare()
    }

    /// `review.itemIndex` is a frozen snapshot from whenever Compare was
    /// entered — deciding a photo *in* Compare (on any panel, not just the
    /// one Review happened to be on) doesn't keep it in sync. Without this,
    /// closing Compare could resurface a photo that's since been rejected,
    /// showing it selected with its reject border instead of advancing
    /// past it the way single-photo Review always does. Nudges to the
    /// nearest still-active item, or drops to the grid if the whole group
    /// is now decided.
    private func reconcileReviewAfterExitingCompare() {
        guard let review else { return }
        if let target = nearestActiveIndex(groupIndex: review.groupIndex, from: review.itemIndex) {
            self.review?.itemIndex = target
        } else {
            self.review = nil
        }
    }

    // MARK: - Grid focus

    /// For every group, the full-group item indices of its currently
    /// visible (non-rejected) thumbnails, in display order.
    func computeActiveLists() -> [[Int]] {
        groups.map { group in
            group.items.indices.filter { i in
                (decisions[group.items[i].path] ?? .undecided) != .reject
            }
        }
    }

    /// Moves the grid's keyboard cursor by `deltaCol` and `deltaRow` (row
    /// steps count `columnsPerRow` positions), clamped within the focused
    /// group's visible thumbnails — mirrors Finder icon-view arrow
    /// navigation. Starts a cursor at the first visible thumbnail of the
    /// first non-empty group if there wasn't one yet.
    func moveGridFocus(deltaCol: Int, deltaRow: Int, columnsPerRow: Int) {
        let activeLists = computeActiveLists()
        let current: (groupIndex: Int, activeIndex: Int, len: Int)? = gridFocus.flatMap { f in
            guard let len = activeLists[safe: f.groupIndex]?.count, len > 0 else { return nil }
            return (f.groupIndex, min(f.activeIndex, len - 1), len)
        }

        if let current {
            let delta = deltaCol + deltaRow * columnsPerRow
            let newIndex = min(max(current.activeIndex + delta, 0), current.len - 1)
            gridFocus = GridFocus(groupIndex: current.groupIndex, activeIndex: newIndex)
        } else if let firstNonEmpty = activeLists.firstIndex(where: { !$0.isEmpty }) {
            gridFocus = GridFocus(groupIndex: firstNonEmpty, activeIndex: 0)
        }
    }

    /// Resolves the grid cursor to `(groupIndex, itemIndex)` in the group's
    /// full item list, for opening review on it.
    func focusedGridItem() -> (groupIndex: Int, itemIndex: Int)? {
        guard let focus = gridFocus else { return nil }
        let activeLists = computeActiveLists()
        guard let itemIndex = activeLists[safe: focus.groupIndex]?[safe: focus.activeIndex] else { return nil }
        return (focus.groupIndex, itemIndex)
    }

    // MARK: - Decisions / Finalize

    func rejectedPaths() -> [URL] { pathsMatching { $0 == .reject } }

    /// Everything that counts as a keeper for Finalize's copy step: always
    /// excludes Rejected, and — per `treatUndecidedAsKeepers` — either
    /// includes Undecided too (the default: a review pass mostly presses X
    /// on the bad shots, so a photo you never explicitly marked shouldn't
    /// be silently excluded) or requires an explicit Keep.
    func keeperPaths(treatUndecidedAsKeepers: Bool = true) -> [URL] {
        pathsMatching(isKeeper(treatUndecidedAsKeepers: treatUndecidedAsKeepers))
    }

    private func isKeeper(treatUndecidedAsKeepers: Bool) -> (Decision) -> Bool {
        treatUndecidedAsKeepers ? { $0 != .reject } : { $0 == .keep }
    }

    func undecidedCount() -> Int { pathsMatching { $0 == .undecided }.count }

    func keepCount() -> Int { pathsMatching { $0 == .keep }.count }

    /// (primary, sidecar) pairs for every item whose decision matches.
    func itemsMatching(_ predicate: (Decision) -> Bool) -> [(URL, URL?)] {
        groups.flatMap(\.items)
            .filter { predicate(decisions[$0.path] ?? .undecided) }
            .map { ($0.path, $0.sidecar) }
    }

    /// Primary paths only — one per photo, regardless of a RAW sidecar.
    func pathsMatching(_ predicate: (Decision) -> Bool) -> [URL] {
        itemsMatching(predicate).map(\.0)
    }

    /// Primary path plus RAW sidecar (when present) for every matching
    /// item — the actual file list Finalize needs so a RAW+JPEG pair moves
    /// or copies together as a unit, not just its JPEG half.
    func filesMatching(_ predicate: (Decision) -> Bool) -> [URL] {
        itemsMatching(predicate).flatMap { primary, sidecar in [primary] + (sidecar.map { [$0] } ?? []) }
    }

    /// Re-checks whether `finalizeDestination` can actually be written to,
    /// updating `finalizeDestinationError`. Called right after a
    /// destination is chosen and whenever the Finalize sheet appears
    /// (covers a destination picked earlier in the session whose
    /// volume/permissions may have changed since), so a permission problem
    /// is caught up front rather than surfacing as a wall of per-photo
    /// copy failures after Confirm.
    func validateFinalizeDestination() {
        guard let destination = finalizeDestination else {
            finalizeDestinationError = nil
            return
        }
        finalizeDestinationError = FileActions.writeAccessError(for: destination)
    }

    /// Runs whichever of the two Finalize actions the user checked:
    /// optionally copies every keeper to `destination` — Keep, plus
    /// Undecided too unless `treatUndecidedAsKeepers` is off — and
    /// optionally moves every rejected photo to the OS trash (removing it
    /// from the loaded groups). Each action is independent.
    func runFinalize(trashRejected: Bool, copyDestination: URL?, treatUndecidedAsKeepers: Bool = true) {
        var messages: [String] = []

        if let dest = copyDestination {
            let isKeeper = isKeeper(treatUndecidedAsKeepers: treatUndecidedAsKeepers)
            let keeperPhotos = pathsMatching(isKeeper)
            let keeperFiles = filesMatching(isKeeper)
            let report = FileActions.copyPaths(keeperFiles, to: dest)
            let copied = Set(report.copied)
            let copiedPhotoCount = keeperPhotos.filter { copied.contains($0) }.count
            messages.append("Copied \(copiedPhotoCount) photo\(plural(copiedPhotoCount)) to \(dest.path).")
            if !report.skippedExisting.isEmpty {
                messages.append("\(report.skippedExisting.count) already existed at the destination and were left as-is.")
            }
            if !report.failed.isEmpty {
                messages.append("\(report.failed.count) failed to copy — \(describeFailures(report.failed))")
            }
        }

        if trashRejected {
            let rejectedPhotos = rejectedPaths()
            let rejectedFiles = filesMatching { $0 == .reject }
            if !rejectedFiles.isEmpty {
                let report = FileActions.trashPaths(rejectedFiles)
                let trashed = Set(report.trashed)
                let trashedPhotoCount = rejectedPhotos.filter { trashed.contains($0) }.count

                for i in groups.indices {
                    groups[i].items.removeAll { trashed.contains($0.path) }
                }
                groups.removeAll { $0.items.isEmpty }

                for path in trashed {
                    decisions.removeValue(forKey: path)
                    viewed.remove(path)
                    thumbnails.removeValue(forKey: path)
                    loupeCache.removeValue(forKey: path)
                    selected.remove(path)
                }

                messages.append("Trashed \(trashedPhotoCount) photo\(plural(trashedPhotoCount)).")
                if !report.failed.isEmpty {
                    messages.append("\(report.failed.count) failed to trash — \(describeFailures(report.failed))")
                }
            }
        }

        if !messages.isEmpty {
            commitStatus = messages.joined(separator: " ")
        }
    }

    /// Border color reflecting both the decision and whether this photo has
    /// ever been shown in the loupe: green (kept), red (rejected), yellow
    /// (viewed but still undecided), gray (never viewed).
    func borderColor(for path: URL) -> Color {
        switch decisions[path] ?? .undecided {
        case .keep: Decision.keep.color
        case .reject: Decision.reject.color
        case .undecided: viewed.contains(path) ? viewedUndecidedColor : unviewedColor
        }
    }
}
