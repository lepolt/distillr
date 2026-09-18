import Foundation
import Testing
@testable import Distillr

func loadRealItems() throws -> [BurstItem] {
    try PhotoScanner.scanFolder(examplesDir()).map { source in
        let meta = try MetadataReader.readMetadata(source.primary)
        return BurstItem(path: source.primary, sidecar: source.sidecar, captureTime: meta.captureTime)
    }
}

func syntheticItem(_ name: String, _ captureTime: Date) -> BurstItem {
    BurstItem(path: URL(fileURLWithPath: name), sidecar: nil, captureTime: captureTime)
}

struct BurstGroupingTests {
    @Test func groupsRealBurstsByCaptureGap() throws {
        let items = try loadRealItems()
        let groups = BurstGrouping.groupBursts(items)

        let sizes = groups.map(\.count)
        // Original 6 JPEG bursts, then a 9-shot RAW+JPEG burst
        // (DSC_3742-3750), then three portrait-JPEG bursts, then the
        // DSC_3900/3901 pair (unrelated shots ~1.2s apart, correctly one
        // *time*-based group — splitting them is a manual action, see
        // AppModelTests).
        #expect(sizes == [20, 17, 6, 5, 12, 6, 9, 7, 8, 10, 2])

        #expect(groups[0].items.first?.path.lastPathComponent == "DSC_3676.JPG")
        #expect(groups[0].items.last?.path.lastPathComponent == "DSC_3695.JPG")
        #expect(groups[1].items.first?.path.lastPathComponent == "DSC_3696.JPG")
        #expect(groups[5].items.first?.path.lastPathComponent == "DSC_3736.JPG")
        #expect(groups[5].items.last?.path.lastPathComponent == "DSC_3741.JPG")

        #expect(groups[6].items.first?.path.lastPathComponent == "DSC_3742.JPG")
        #expect(groups[6].items.first?.sidecar?.lastPathComponent == "DSC_3742.NEF")
        #expect(groups[6].items.last?.path.lastPathComponent == "DSC_3750.JPG")

        #expect(groups[7].items.first?.path.lastPathComponent == "DSC_3751.JPG")
        #expect(groups[8].items.first?.path.lastPathComponent == "DSC_3758.JPG")
        #expect(groups[9].items.first?.path.lastPathComponent == "DSC_3766.JPG")
        #expect(groups[9].items.last?.path.lastPathComponent == "DSC_3775.JPG")

        #expect(groups[10].items.first?.path.lastPathComponent == "DSC_3900.JPG")
        #expect(groups[10].items.last?.path.lastPathComponent == "DSC_3901.JPG")
    }

    @Test func groupsAreInternallySortedByCaptureTime() throws {
        let items = try loadRealItems()
        let groups = BurstGrouping.groupBursts(items)
        for group in groups {
            for i in 1..<group.items.count {
                #expect(group.items[i - 1].captureTime <= group.items[i].captureTime)
            }
        }
    }

    @Test func emptyInputYieldsNoGroups() {
        #expect(BurstGrouping.groupBursts([]).isEmpty)
    }

    @Test func singleItemYieldsOneGroup() {
        let groups = BurstGrouping.groupBursts([syntheticItem("a.jpg", Date(timeIntervalSince1970: 0))])
        #expect(groups.count == 1)
        #expect(groups[0].count == 1)
    }

    @Test func gapLargerThanThresholdSplitsGroups() {
        let base = Date(timeIntervalSince1970: 0)
        let items = [
            syntheticItem("a.jpg", base),
            syntheticItem("b.jpg", base.addingTimeInterval(0.1)),
            syntheticItem("c.jpg", base.addingTimeInterval(10)),
        ]
        let groups = BurstGrouping.groupBursts(items)
        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
    }
}
