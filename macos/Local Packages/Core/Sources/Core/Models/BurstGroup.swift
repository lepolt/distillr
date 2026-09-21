import Foundation

struct BurstItem: Equatable, Hashable {
    let path: URL
    /// The paired RAW file, when `path` is a JPEG with a RAW file alongside
    /// it (see `PhotoSource`). Carried through grouping so Finalize can
    /// trash/copy it together with `path`.
    let sidecar: URL?
    let captureTime: Date
}

struct BurstGroup: Equatable {
    var items: [BurstItem]

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
}
