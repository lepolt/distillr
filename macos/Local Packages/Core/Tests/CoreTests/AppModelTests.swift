import Foundation
import Testing
@testable import Core

@MainActor
struct AppModelTests {
    /// Exercises the full scan -> metadata -> burst -> background-thumbnail
    /// pipeline against the real sample photos.
    @Test func loadsRealFolderIntoBurstGroupsWithThumbnails() async {
        let model = AppModel()
        model.loadFolder(examplesDir())

        let totalPhotos = model.thumbnailsTotal
        let sizes = model.groups.map(\.count)
        // DSC_3900/3901 (unrelated shots ~1.2s apart, continuous shooting)
        // land in one group here — pure time-based grouping merges them;
        // splitting a mis-grouped burst like this is a manual action from
        // Review (see `splitGroup(before:in:)`), not automatic.
        #expect(sizes == [20, 17, 6, 5, 12, 6, 9, 7, 8, 10, 2])
        #expect(model.status.contains("\(totalPhotos) photos"))
        #expect(model.status.contains("11 burst groups"))

        await waitForThumbnails(model, total: totalPhotos)
        #expect(model.thumbnails.count == totalPhotos)
    }

    @Test func reviewNavigationAndDecisionsWorkOnRealGroup() async {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let totalPhotos = model.groups.reduce(0) { $0 + $1.count }
        await waitForThumbnails(model, total: totalPhotos)

        model.enterReview(groupIndex: 0, itemIndex: 0) // Burst 1, 20 photos
        #expect(model.review?.itemIndex == 0)

        let firstPath = model.currentReviewPath()!
        model.decisions[firstPath] = .keep
        model.reviewMove(1)
        #expect(model.review?.itemIndex == 1)

        let secondPath = model.currentReviewPath()!
        #expect(firstPath != secondPath)
        model.decisions[secondPath] = .reject

        // Can't move past the start or end of the group.
        model.reviewMove(-100)
        #expect(model.review?.itemIndex == 0)
        model.reviewMove(100)
        #expect(model.review?.itemIndex == 19)

        #expect(model.decisions[firstPath] == .keep)
    }

    @Test func loupeImageLoadsForCurrentReviewItem() async {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0) // also kicks off a prefetch

        let path = model.currentReviewPath()!
        model.loadLoupeImage(path)
        await waitForLoupeImage(model, path: path)
        #expect(model.loupeCache[path] != nil)
    }

    @Test func loupeCacheEvictsPhotosFarFromCurrentReviewPosition() async {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path } // Burst 1, 20 photos

        model.enterReview(groupIndex: 0, itemIndex: 0)
        model.loadLoupeImage(pathAt(0))
        await waitForLoupeImage(model, path: pathAt(0))
        #expect(model.loupeCache[pathAt(0)] != nil)

        model.enterReview(groupIndex: 0, itemIndex: 15)
        await waitForLoupeImage(model, path: pathAt(15))

        #expect(model.loupeCache[pathAt(0)] == nil, "photos far from the current position should be evicted, not held for the whole session")
        #expect(model.loupeCache[pathAt(15)] != nil)
    }

    @Test func enterReviewOpensOnTheRequestedItem() {
        let model = AppModel()
        model.loadFolder(examplesDir())

        let expectedPath = model.groups[0].items[5].path
        model.enterReview(groupIndex: 0, itemIndex: 5)

        #expect(model.review?.itemIndex == 5)
        #expect(model.currentReviewPath() == expectedPath)
    }

    @Test func activePathsFromBackfillsWhenStartingNearTheEndOfAShortBurst() {
        let dir = disposableCopyOfExamples(["DSC_3719.JPG", "DSC_3720.JPG", "DSC_3721.JPG", "DSC_3722.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        model.loadFolder(dir)
        #expect(model.groups.count == 1)
        #expect(model.groups[0].count == 4)

        // Double-clicking the 3rd of 4 photos then pressing "4" should show
        // all 4 photos, not just this one and the one after it.
        let seed = model.activePaths(from: 0, startIndex: 2, count: 4)

        let expected = model.groups[0].items.map(\.path)
        #expect(seed == expected)
    }

    @Test func activePathsFromStillPrefersForwardWhenEnoughPhotosAreAhead() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }

        let seed = model.activePaths(from: 0, startIndex: 0, count: 3)

        #expect(seed == [pathAt(0), pathAt(1), pathAt(2)])
    }

    @Test func reviewMoveBurstMovesToNextAndPreviousGroup() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0)

        model.reviewMoveBurst(1)
        #expect(model.review?.groupIndex == 1)

        model.reviewMoveBurst(-1)
        #expect(model.review?.groupIndex == 0)
    }

    @Test func reviewMoveBurstClampsAtBounds() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let lastGroup = model.groups.count - 1

        model.enterReview(groupIndex: 0, itemIndex: 0)
        model.reviewMoveBurst(-1)
        #expect(model.review?.groupIndex == 0)

        model.enterReview(groupIndex: lastGroup, itemIndex: 0)
        model.reviewMoveBurst(1)
        #expect(model.review?.groupIndex == lastGroup)
    }

    @Test func reviewMoveBurstIsANoopWhenNotReviewing() {
        let model = AppModel()
        model.loadFolder(examplesDir())

        model.reviewMoveBurst(1)

        #expect(model.review == nil)
    }

    @Test func compareMoveBurstPreservesPanelCountAndReseeds() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (g: Int, i: Int) in model.groups[g].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0, 0), pathAt(0, 1), pathAt(0, 2)])

        model.compareMoveBurst(1)

        #expect(model.compare?.groupIndex == 1)
        #expect(model.compare?.slots == [pathAt(1, 0), pathAt(1, 1), pathAt(1, 2)])
    }

    @Test func compareMoveBurstClampsAtBounds() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1)])

        model.compareMoveBurst(-1)

        #expect(model.compare?.groupIndex == 0)
    }

    @Test func borderColorReflectsDecisionAndViewedState() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let path = model.groups[0].items[0].path

        // Never viewed, no decision: gray.
        #expect(model.borderColor(for: path) == unviewedColor)

        // Viewed (as review does on every frame it shows a photo), still
        // undecided: yellow.
        model.viewed.insert(path)
        #expect(model.borderColor(for: path) == viewedUndecidedColor)

        // Kept: green, regardless of viewed state.
        model.decisions[path] = .keep
        #expect(model.borderColor(for: path) == Decision.keep.color)

        // Rejected: red.
        model.decisions[path] = .reject
        #expect(model.borderColor(for: path) == Decision.reject.color)
    }

    @Test func reviewNavigationSkipsOverRejectedItems() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }

        // Reject index 1 up front, as if it had been rejected in an earlier
        // review pass or from the grid's rejected row.
        model.decisions[pathAt(1)] = .reject

        // Opening review right on the rejected index snaps forward to the
        // nearest active item instead of showing the rejected photo.
        model.enterReview(groupIndex: 0, itemIndex: 1)
        #expect(model.currentReviewPath() == pathAt(2))

        // Arrowing left from there skips back over the rejected item 1 and
        // lands on 0, never stopping on 1.
        model.reviewMove(-1)
        #expect(model.currentReviewPath() == pathAt(0))

        // Arrowing right again skips 1 and returns to 2.
        model.reviewMove(1)
        #expect(model.currentReviewPath() == pathAt(2))
    }

    // MARK: - Manual split

    @Test func splitGroupBeforeDividesAGroupAtTheGivenIndex() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let groupCountBefore = model.groups.count
        let itemsBefore = model.groups[0].items.map(\.path)

        model.splitGroup(before: 5, in: 0)

        #expect(model.groups.count == groupCountBefore + 1)
        #expect(model.groups[0].items.count == 5)
        #expect(model.groups[1].items.count == itemsBefore.count - 5)
        let rejoined = model.groups[0].items.map(\.path) + model.groups[1].items.map(\.path)
        #expect(rejoined == itemsBefore, "no items lost or reordered")
        #expect(model.status.contains("\(groupCountBefore + 1) burst groups"))
    }

    @Test func splitGroupBeforeIsANoopAtTheStartOfAGroup() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let groupCountBefore = model.groups.count

        model.splitGroup(before: 0, in: 0)

        #expect(model.groups.count == groupCountBefore, "nothing to split off before index 0")
    }

    @Test func splitGroupBeforeMovesReviewToTheNewGroupAtTheSplitPoint() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let splitPath = model.groups[0].items[5].path

        model.enterReview(groupIndex: 0, itemIndex: 5)
        model.splitGroup(before: 5, in: 0)

        #expect(model.review?.groupIndex == 1)
        #expect(model.review?.itemIndex == 0)
        #expect(model.groups[1].items[0].path == splitPath)
    }

    @Test func splitGroupBeforeShiftsReviewStatePointingAtALaterGroup() {
        let model = AppModel()
        model.loadFolder(examplesDir())

        model.enterReview(groupIndex: 1, itemIndex: 2) // burst 2 (17 photos), some photo mid-way
        let pathBefore = model.currentReviewPath()!

        model.splitGroup(before: 5, in: 0) // split the earlier burst 1

        #expect(model.review?.groupIndex == 2, "burst 2 shifted to index 2")
        #expect(model.currentReviewPath() == pathBefore)
    }

    @Test func splitGroupBeforeFixesTheRealReportedBugPair() {
        let dir = disposableCopyOfExamples(["DSC_3900.JPG", "DSC_3901.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        model.loadFolder(dir)

        // Continuous-shooting pair ~1.2s apart, merged into one time-based
        // group (the reported bug).
        #expect(model.groups.count == 1)
        #expect(model.groups[0].items.count == 2)

        model.splitGroup(before: 1, in: 0)

        #expect(model.groups.count == 2)
        #expect(model.groups[0].items.count == 1)
        #expect(model.groups[1].items.count == 1)
        #expect(model.groups[0].items[0].path != model.groups[1].items[0].path)
    }

    // MARK: - Rejection / active-item fallback

    @Test func rejectingCurrentItemAdvancesPastItToTheNextActiveItem() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }

        model.enterReview(groupIndex: 0, itemIndex: 0)
        let rejectedPath = model.currentReviewPath()!

        // Mirrors what the Review view does on X: record the decision,
        // then advance by one active step.
        model.decisions[rejectedPath] = .reject
        model.reviewMove(1)

        let nowShowing = model.currentReviewPath()!
        #expect(nowShowing == pathAt(1))
        #expect(nowShowing != rejectedPath)
    }

    @Test func rejectingTheLastActivePhotoReselectsThePreviousOne() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }

        // Reject everything except the last two photos in the burst, then
        // open review right on the last one.
        for i in 0..<18 {
            model.decisions[pathAt(i)] = .reject
        }
        model.enterReview(groupIndex: 0, itemIndex: 19)
        #expect(model.currentReviewPath() == pathAt(19))

        let lastPath = model.currentReviewPath()!
        model.decisions[lastPath] = .reject
        model.reviewMove(1) // mirrors the auto-advance the Review view does on X

        #expect(model.currentReviewPath() == pathAt(18), "rejecting the last active photo should fall back to the previous active one")
        #expect(!model.reviewGroupExhausted())
    }

    @Test func rejectingTheOnlyRemainingPhotoLeavesTheGroupExhausted() async {
        let dir = disposableCopyOfExamples(["DSC_3683.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 1)
        model.enterReview(groupIndex: 0, itemIndex: 0)
        let onlyPath = model.currentReviewPath()!

        model.decisions[onlyPath] = .reject
        model.reviewMove(1)

        #expect(model.reviewGroupExhausted(), "no active photos remain, so review should treat the group as exhausted")
    }

    @Test func decidingAnItemWhenBurstStillHasUndecidedPhotosJustAdvancesNormally() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0) // Burst 1, 20 photos
        let pathAt = { (i: Int) in model.groups[0].items[i].path }

        model.decideCurrentReviewItem(.keep)

        #expect(model.decisions[pathAt(0)] == .keep)
        #expect(model.review?.groupIndex == 0)
        #expect(model.review?.itemIndex == 1, "burst still has undecided photos, so it just steps to the next one")
    }

    @Test func decidingTheLastUndecidedItemInABurstAdvancesToTheNextBurst() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0) // Burst 1, 20 photos
        for item in model.groups[0].items {
            model.decisions[item.path] = .keep
        }
        let lastPath = model.groups[0].items.last!.path
        model.decisions[lastPath] = nil // leave exactly one undecided
        model.review?.itemIndex = model.groups[0].items.count - 1

        model.decideCurrentReviewItem(.keep)

        #expect(model.decisions[lastPath] == .keep)
        #expect(model.review?.groupIndex == 1, "deciding the last undecided photo in a burst should jump straight to the next one")
        #expect(model.review?.itemIndex == 0)
    }

    @Test func decidingTheLastUndecidedItemInTheLastBurstStaysPut() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let lastGroup = model.groups.count - 1
        model.enterReview(groupIndex: lastGroup, itemIndex: 0)
        for item in model.groups[lastGroup].items {
            model.decisions[item.path] = .keep
        }
        let lastPath = model.groups[lastGroup].items.last!.path
        model.decisions[lastPath] = nil
        model.review?.itemIndex = model.groups[lastGroup].items.count - 1

        model.decideCurrentReviewItem(.keep)

        #expect(model.decisions[lastPath] == .keep)
        #expect(model.review?.groupIndex == lastGroup, "no next burst to jump to, so review stays on the last group")
    }

    @Test func extendReviewSelectionGrowsAndShrinksAnchoredRange() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterReview(groupIndex: 0, itemIndex: 0)

        model.extendReviewSelection(1)
        model.extendReviewSelection(1)
        model.extendReviewSelection(1)
        #expect(model.reviewSelection == Set([pathAt(0), pathAt(1), pathAt(2), pathAt(3)]))

        model.extendReviewSelection(-1)
        #expect(
            model.reviewSelection == Set([pathAt(0), pathAt(1), pathAt(2)]),
            "moving back toward the anchor should shrink the range, not just stop growing"
        )
    }

    @Test func extendReviewSelectionExcludesRejectedItemsInTheRange() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.decisions[pathAt(2)] = .reject
        model.enterReview(groupIndex: 0, itemIndex: 0)

        model.extendReviewSelection(1) // active index 1
        model.extendReviewSelection(1) // active index 3, skipping rejected index 2
        model.extendReviewSelection(1) // active index 4

        #expect(model.reviewSelection == Set([pathAt(0), pathAt(1), pathAt(3), pathAt(4)]))
        #expect(!model.reviewSelection.contains(pathAt(2)))
    }

    @Test func extendReviewSelectionToAClickedIndexGrowsAndShrinksFromTheAnchor() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterReview(groupIndex: 0, itemIndex: 5)

        model.extendReviewSelection(to: 8)
        #expect(model.reviewSelection == Set([pathAt(5), pathAt(6), pathAt(7), pathAt(8)]))
        #expect(model.review?.itemIndex == 8)

        model.extendReviewSelection(to: 6)
        #expect(model.reviewSelection == Set([pathAt(5), pathAt(6)]), "the anchor stays at 5 across both Shift-clicks")
    }

    @Test func plainReviewMoveCollapsesAnActiveSelection() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0)
        model.extendReviewSelection(1)
        model.extendReviewSelection(1)
        #expect(model.reviewSelection.count == 3)

        model.reviewMove(1)

        #expect(model.reviewSelection.isEmpty)
    }

    @Test func reviewMoveBurstClearsASelectionFromTheBurstLeftBehind() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.enterReview(groupIndex: 0, itemIndex: 0)
        model.extendReviewSelection(1)
        #expect(!model.reviewSelection.isEmpty)

        model.reviewMoveBurst(1)

        #expect(model.review?.groupIndex == 1)
        #expect(model.reviewSelection.isEmpty)
    }

    @Test func decideCurrentReviewItemAppliesToTheWholeSelectionAndClearsIt() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterReview(groupIndex: 0, itemIndex: 0)
        model.extendReviewSelection(1)
        model.extendReviewSelection(1) // selects indices 0, 1, 2

        model.decideCurrentReviewItem(.reject)

        #expect(model.decisions[pathAt(0)] == .reject)
        #expect(model.decisions[pathAt(1)] == .reject)
        #expect(model.decisions[pathAt(2)] == .reject)
        #expect(model.reviewSelection.isEmpty)
        #expect(model.review?.itemIndex == 3, "should land on the next still-active photo past the rejected range")
    }

    @Test func decideCurrentReviewItemFallsBackToTheSinglePhotoWhenNothingIsSelected() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterReview(groupIndex: 0, itemIndex: 0)
        #expect(model.reviewSelection.isEmpty, "no Shift-extend happened, so this is the ordinary single-photo path")

        model.decideCurrentReviewItem(.keep)

        #expect(model.decisions[pathAt(0)] == .keep)
        #expect(model.decisions[pathAt(1)] == nil, "only the current photo should be decided, not neighbors")
    }

    // MARK: - Compare

    @Test func enterCompareSeedsSlotsAndFocusesFirstPanel() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        let seed = [pathAt(0), pathAt(1), pathAt(2)]

        model.enterCompare(groupIndex: 0, paths: seed)

        #expect(model.compare?.groupIndex == 0)
        #expect(model.compare?.focused == 0)
        #expect(model.compare?.slots == seed)
    }

    @Test func moveCompareFocusWrapsAround() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1), pathAt(2)])

        model.moveCompareFocus(deltaCol: 1, deltaRow: 0)
        #expect(model.compare?.focused == 1)
        model.moveCompareFocus(deltaCol: 1, deltaRow: 0)
        #expect(model.compare?.focused == 2)
        model.moveCompareFocus(deltaCol: 1, deltaRow: 0)
        #expect(model.compare?.focused == 0, "should wrap forward")
        model.moveCompareFocus(deltaCol: -1, deltaRow: 0)
        #expect(model.compare?.focused == 2, "should wrap backward")
    }

    @Test func moveCompareFocusUpDownMovesByRowIn2x2Layout() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1), pathAt(2), pathAt(3)])
        // Panel layout is 2x2, row-major: [0 1] / [2 3].
        #expect(model.compare?.focused == 0)

        model.moveCompareFocus(deltaCol: 0, deltaRow: 1) // Down: top-left -> bottom-left
        #expect(model.compare?.focused == 2)
        model.moveCompareFocus(deltaCol: 1, deltaRow: 0) // Right: bottom-left -> bottom-right
        #expect(model.compare?.focused == 3)
        model.moveCompareFocus(deltaCol: 0, deltaRow: -1) // Up: bottom-right -> top-right
        #expect(model.compare?.focused == 1)
    }

    @Test func moveCompareFocusUpDownIsANoOpInSingleRowLayout() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1), pathAt(2)])

        model.moveCompareFocus(deltaCol: 0, deltaRow: 1) // Down: nothing below a single row
        #expect(model.compare?.focused == 0)
        model.moveCompareFocus(deltaCol: 0, deltaRow: -1) // Up: nothing above a single row
        #expect(model.compare?.focused == 0)
    }

    @Test func decidingFocusedPanelRecordsDecisionAndRefillsFromGroup() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        let (p0, p1, p2, p3) = (pathAt(0), pathAt(1), pathAt(2), pathAt(3))
        model.enterCompare(groupIndex: 0, paths: [p0, p1, p2])

        model.decideFocusedComparePanel(.keep)

        #expect(model.decisions[p0] == .keep)
        #expect(model.compare?.slots == [p3, p1, p2], "the decided slot should refill with the next photo not already shown")
        #expect(model.compare?.focused == 0, "focus stays on the refilled slot")
    }

    @Test func decidingPanelWithNoReplacementShrinksPanelCountByOne() async {
        let dir = disposableCopyOfExamples(["DSC_3684.JPG", "DSC_3685.JPG", "DSC_3686.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        model.loadFolder(dir)
        await waitForThumbnails(model, total: 3)
        #expect(model.groups.count == 1, "fixture precondition: all three group together")
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        let (p0, p1, p2) = (pathAt(0), pathAt(1), pathAt(2))
        model.enterCompare(groupIndex: 0, paths: [p0, p1, p2])

        model.decideFocusedComparePanel(.reject)

        #expect(model.decisions[p0] == .reject)
        #expect(model.compare?.slots == [p1, p2], "panel count drops by one instead of leaving a dead empty slot")
        #expect(model.compare?.focused == 0)
    }

    @Test func decidingPanelWithNoReplacementFallsBackToReviewWhenOnePanelWouldRemain() async {
        let dir = disposableCopyOfExamples(["DSC_3684.JPG", "DSC_3685.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        model.loadFolder(dir)
        await waitForThumbnails(model, total: 2)
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        let (p0, p1) = (pathAt(0), pathAt(1))
        model.enterCompare(groupIndex: 0, paths: [p0, p1])

        model.decideFocusedComparePanel(.reject)

        #expect(model.decisions[p0] == .reject)
        #expect(model.compare == nil, "down to a single remaining photo isn't really comparing anymore")
        #expect(model.review?.groupIndex == 0)
        #expect(model.currentReviewPath() == p1)
    }

    @Test func decidingPanelWithNoReplacementAndNoneRemainingExitsCompare() async {
        let dir = disposableCopyOfExamples(["DSC_3686.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()
        model.loadFolder(dir)
        await waitForThumbnails(model, total: 1)
        let onlyPath = model.groups[0].items[0].path
        model.enterCompare(groupIndex: 0, paths: [onlyPath])

        model.decideFocusedComparePanel(.reject)

        #expect(model.decisions[onlyPath] == .reject)
        #expect(model.compare == nil, "nothing left at all to compare or review")
        #expect(model.review == nil)
    }

    @Test func resizeCompareGrowsWithFreshPhotosInOrder() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1)])

        model.resizeCompare(4)

        #expect(model.compare?.slots == [pathAt(0), pathAt(1), pathAt(2), pathAt(3)])
    }

    @Test func resizeCompareShrinksByDroppingTrailingPanels() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.enterCompare(groupIndex: 0, paths: [pathAt(0), pathAt(1), pathAt(2), pathAt(3)])
        model.moveCompareFocus(deltaCol: 3, deltaRow: 0) // focus the last panel (index 3)

        model.resizeCompare(2)

        #expect(model.compare?.slots == [pathAt(0), pathAt(1)])
        #expect(model.compare?.focused == 1, "focus should clamp into range after shrinking")
    }

    // MARK: - Grid focus

    @Test func moveGridFocusStartsACursorWhenNoneExists() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        #expect(model.gridFocus == nil)

        model.moveGridFocus(deltaCol: 0, deltaRow: 1, columnsPerRow: 5)

        #expect(model.gridFocus?.groupIndex == 0)
        #expect(model.gridFocus?.activeIndex == 0)
    }

    @Test func moveGridFocusMovesByRowAndColumn() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.gridFocus = GridFocus(groupIndex: 0, activeIndex: 0)

        model.moveGridFocus(deltaCol: 1, deltaRow: 0, columnsPerRow: 5) // right one column
        #expect(model.gridFocus?.activeIndex == 1)

        model.moveGridFocus(deltaCol: 0, deltaRow: 1, columnsPerRow: 5) // down one row (5 columns/row)
        #expect(model.gridFocus?.activeIndex == 6)

        model.moveGridFocus(deltaCol: 0, deltaRow: -1, columnsPerRow: 5) // back up one row
        #expect(model.gridFocus?.activeIndex == 1)
    }

    @Test func moveGridFocusClampsAtGroupBounds() {
        let model = AppModel()
        model.loadFolder(examplesDir()) // Burst 1 has 20 photos
        model.gridFocus = GridFocus(groupIndex: 0, activeIndex: 0)

        model.moveGridFocus(deltaCol: -1, deltaRow: 0, columnsPerRow: 5)
        #expect(model.gridFocus?.activeIndex == 0)

        model.gridFocus = GridFocus(groupIndex: 0, activeIndex: 19)
        model.moveGridFocus(deltaCol: 0, deltaRow: 1, columnsPerRow: 5) // one more row past the end
        #expect(model.gridFocus?.activeIndex == 19)
    }

    @Test func moveGridFocusOnlyCountsVisibleNonRejectedPhotos() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        // Reject item 1, so the visible sequence is [0, 2, 3, 4, ...].
        model.decisions[pathAt(1)] = .reject
        model.gridFocus = GridFocus(groupIndex: 0, activeIndex: 0)

        model.moveGridFocus(deltaCol: 1, deltaRow: 0, columnsPerRow: 5) // one step right in the visible list

        let focused = model.focusedGridItem()!
        #expect(focused.groupIndex == 0)
        #expect(focused.itemIndex == 2, "should skip the rejected item at index 1")
    }

    @Test func focusedGridItemResolvesToFullGroupItemIndex() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        model.gridFocus = GridFocus(groupIndex: 0, activeIndex: 5)

        let focused = model.focusedGridItem()!
        #expect(focused.groupIndex == 0)
        #expect(focused.itemIndex == 5)
    }

    // MARK: - RAW+JPEG pairing / Finalize

    @Test func rawJPEGPairLoadsAsOneItemWithSidecar() {
        let dir = disposableCopyOfExamples(["DSC_3742.JPG", "DSC_3742.NEF"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()

        model.loadFolder(dir)

        #expect(model.groups.count == 1)
        #expect(model.groups[0].count == 1)
        let item = model.groups[0].items[0]
        #expect(item.path.lastPathComponent == "DSC_3742.JPG")
        #expect(item.sidecar?.lastPathComponent == "DSC_3742.NEF")
    }

    @Test func finalizeTrashesRAWJPEGPairTogether() {
        let dir = disposableCopyOfExamples(["DSC_3742.JPG", "DSC_3742.NEF"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()

        model.loadFolder(dir)
        let jpgPath = model.groups[0].items[0].path
        let nefPath = model.groups[0].items[0].sidecar!
        model.decisions[jpgPath] = .reject

        model.runFinalize(trashRejected: true, copyDestination: nil)

        #expect(!FileManager.default.fileExists(atPath: jpgPath.path), "JPEG half should be trashed")
        #expect(!FileManager.default.fileExists(atPath: nefPath.path), "RAW half should be trashed together with it")
        #expect(model.commitStatus == "Trashed 1 photo.")
    }

    @Test func finalizeCopiesRAWJPEGPairTogether() {
        let dir = disposableCopyOfExamples(["DSC_3742.JPG", "DSC_3742.NEF"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-finalize-raw-pair-\(UUID().uuidString)")
        let model = AppModel()

        model.loadFolder(dir)
        // Left Undecided on purpose — "keeper" means "not rejected", and
        // that should still pull the RAW sidecar along.

        model.runFinalize(trashRejected: false, copyDestination: dest)

        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("DSC_3742.JPG").path))
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("DSC_3742.NEF").path))
        #expect(model.commitStatus == "Copied 1 photo to \(dest.path).")

        try? FileManager.default.removeItem(at: dest)
    }

    @Test func finalizeTrashesRejectedAndCopiesKeepersLeavingOriginals() async {
        let dir = disposableCopyOfExamples(["DSC_3676.JPG", "DSC_3677.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-finalize-\(UUID().uuidString)")
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 2)
        #expect(model.groups.count == 1)
        #expect(model.groups[0].count == 2)

        let rejectedPath = model.groups[0].items[0].path
        // Second photo is left Undecided on purpose: "keeper" means
        // anything not explicitly rejected, so it should still get copied.
        let keptPath = model.groups[0].items[1].path
        model.decisions[rejectedPath] = .reject

        #expect(model.rejectedPaths() == [rejectedPath])
        #expect(model.keeperPaths() == [keptPath])
        model.runFinalize(trashRejected: true, copyDestination: dest)

        #expect(!FileManager.default.fileExists(atPath: rejectedPath.path), "trashed file should be gone")
        #expect(FileManager.default.fileExists(atPath: keptPath.path), "untouched original should remain")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(keptPath.lastPathComponent).path), "keeper should be copied to the destination")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(rejectedPath.lastPathComponent).path))

        #expect(model.groups.count == 1)
        #expect(model.groups[0].count == 1)
        #expect(model.groups[0].items[0].path == keptPath)
        #expect(model.decisions[rejectedPath] == nil)
        #expect(model.thumbnails[rejectedPath] == nil)
        let status = model.commitStatus!
        #expect(status.contains("Copied 1 photo"))
        #expect(status.contains("Trashed 1 photo."))

        try? FileManager.default.removeItem(at: dest)
    }

    @Test func finalizeCanEmptyAGroupEntirely() async {
        let dir = disposableCopyOfExamples(["DSC_3678.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 1)
        let onlyPath = model.groups[0].items[0].path
        model.decisions[onlyPath] = .reject

        // No keepers, so no destination is needed at all.
        #expect(model.keeperPaths().isEmpty)
        model.runFinalize(trashRejected: true, copyDestination: nil)

        #expect(model.groups.isEmpty)
    }

    @Test func finalizeCanTrashWithoutCopyingKeepers() async {
        let dir = disposableCopyOfExamples(["DSC_3679.JPG", "DSC_3680.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 2)
        let rejectedPath = model.groups[0].items[0].path
        let keptPath = model.groups[0].items[1].path
        model.decisions[rejectedPath] = .reject

        // "Move to trash" checked, "copy keepers" unchecked: no destination
        // passed at all, so the keeper must be left untouched in place.
        model.runFinalize(trashRejected: true, copyDestination: nil)

        #expect(!FileManager.default.fileExists(atPath: rejectedPath.path), "rejected file should be trashed")
        #expect(FileManager.default.fileExists(atPath: keptPath.path), "keeper should still be at its original path")
        #expect(model.groups.count == 1)
        #expect(model.groups[0].items[0].path == keptPath)
        let status = model.commitStatus!
        #expect(status.contains("Trashed 1 photo."))
        #expect(!status.contains("Copied"))
    }

    @Test func finalizeCanCopyKeepersWithoutTrashingRejected() async {
        let dir = disposableCopyOfExamples(["DSC_3681.JPG", "DSC_3682.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-finalize-copy-only-\(UUID().uuidString)")
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 2)
        let rejectedPath = model.groups[0].items[0].path
        let keptPath = model.groups[0].items[1].path
        model.decisions[rejectedPath] = .reject

        // "Copy keepers" checked, "move to trash" unchecked: the rejected
        // photo must still be sitting right where it was, still marked
        // Reject, so it shows up in next time's Rejected row.
        model.runFinalize(trashRejected: false, copyDestination: dest)

        #expect(FileManager.default.fileExists(atPath: rejectedPath.path), "rejected file should be untouched when trashing is unchecked")
        #expect(model.groups[0].count == 2, "nothing removed from the group")
        #expect(model.decisions[rejectedPath] == .reject, "still marked rejected for a future Finalize")
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(keptPath.lastPathComponent).path))
        let status = model.commitStatus!
        #expect(status.contains("Copied 1 photo"))
        #expect(!status.contains("Trashed"))

        try? FileManager.default.removeItem(at: dest)
    }

    @Test func keeperPathsExcludesUndecidedWhenAsked() {
        let model = AppModel()
        model.loadFolder(examplesDir())
        let pathAt = { (i: Int) in model.groups[0].items[i].path }
        model.decisions[pathAt(0)] = .keep
        model.decisions[pathAt(1)] = .reject
        // pathAt(2) left undecided on purpose.

        #expect(model.keeperPaths(treatUndecidedAsKeepers: false) == [pathAt(0)])
        #expect(model.keeperPaths().contains(pathAt(2)), "default call still treats undecided as a keeper")
    }

    @Test func finalizeCanExcludeUndecidedFromKeepersWhenToggledOff() async {
        let dir = disposableCopyOfExamples(["DSC_3676.JPG", "DSC_3677.JPG"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-finalize-exclude-undecided-\(UUID().uuidString)")
        let model = AppModel()

        model.loadFolder(dir)
        await waitForThumbnails(model, total: 2)
        let keptPath = model.groups[0].items[0].path
        let undecidedPath = model.groups[0].items[1].path
        model.decisions[keptPath] = .keep
        // undecidedPath is left Undecided on purpose.

        model.runFinalize(trashRejected: false, copyDestination: dest, treatUndecidedAsKeepers: false)

        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(keptPath.lastPathComponent).path), "explicit keeper should still be copied")
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent(undecidedPath.lastPathComponent).path), "undecided photo should be excluded when the toggle is off")
        #expect(model.decisions[undecidedPath] == nil, "excluding it from this Finalize pass shouldn't force a decision")
        #expect(model.groups[0].count == 2, "nothing removed since nothing was rejected")
        let status = model.commitStatus!
        #expect(status.contains("Copied 1 photo"))

        try? FileManager.default.removeItem(at: dest)
    }

    @Test func validateFinalizeDestinationClearsErrorWhenThereIsNoDestination() {
        let model = AppModel()
        model.finalizeDestinationError = "stale error from a previous destination"

        model.validateFinalizeDestination()

        #expect(model.finalizeDestinationError == nil)
    }

    @Test func validateFinalizeDestinationAcceptsAWritableFolder() {
        let model = AppModel()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-validate-dest-ok-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dest) }
        model.finalizeDestination = dest

        model.validateFinalizeDestination()

        #expect(model.finalizeDestinationError == nil)
    }

    @Test func validateFinalizeDestinationFlagsAnUnwritableFolder() throws {
        let model = AppModel()
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("distillr-validate-dest-denied-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dest.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dest.path)
            try? FileManager.default.removeItem(at: dest)
        }
        model.finalizeDestination = dest

        model.validateFinalizeDestination()

        #expect(model.finalizeDestinationError != nil, "an unwritable destination (e.g. an App Sandbox permission denial) should be caught before Finalize runs")
    }
}
