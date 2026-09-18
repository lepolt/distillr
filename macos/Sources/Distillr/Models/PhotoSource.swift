import Foundation

/// Extensions recognized as RAW formats. Only NEF is verified against real
/// camera files; the rest go through the same ImageIO path and cost
/// nothing extra to attempt.
let rawExtensions: Set<String> = [
    "nef", "nrw", "cr2", "cr3", "crw", "arw", "srf", "sr2", "orf", "rw2",
    "raf", "pef", "dng", "srw", "x3f", "3fr", "iiq", "erf", "mrw",
]

let jpegExtensions: Set<String> = ["jpg", "jpeg"]

func isRAWExtension(_ url: URL) -> Bool {
    rawExtensions.contains(url.pathExtension.lowercased())
}

func isJPEGExtension(_ url: URL) -> Bool {
    jpegExtensions.contains(url.pathExtension.lowercased())
}

/// One photo as found on disk. When a camera writes RAW+JPEG together,
/// both halves share a base filename (`DSC_1234.JPG` / `DSC_1234.NEF`) and
/// are folded into a single `PhotoSource` rather than appearing as two
/// separate photos.
struct PhotoSource: Equatable, Hashable {
    /// Used for metadata reading, thumbnails/loupe display, and as the key
    /// everywhere decisions are tracked. The JPEG half of a pair when one
    /// exists (cheaper to decode than extracting a RAW preview), otherwise
    /// whichever single file is there.
    let primary: URL
    /// The paired RAW file, when `primary` is a JPEG with a same-named RAW
    /// file alongside it. Never read directly for display — only trashed
    /// or copied together with `primary` so the pair moves as a unit.
    let sidecar: URL?
}
