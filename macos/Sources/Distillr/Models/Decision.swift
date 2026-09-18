import SwiftUI

enum Decision: Equatable {
    case undecided
    case keep
    case reject

    var label: String {
        switch self {
        case .undecided: "undecided"
        case .keep: "KEEP"
        case .reject: "REJECT"
        }
    }

    var color: Color {
        switch self {
        case .undecided: .gray
        case .keep: Color(red: 90 / 255, green: 200 / 255, blue: 90 / 255)
        case .reject: Color(red: 220 / 255, green: 90 / 255, blue: 90 / 255)
        }
    }
}

let unviewedColor: Color = .gray
let viewedUndecidedColor = Color(red: 230 / 255, green: 200 / 255, blue: 60 / 255)
/// macOS system blue — used for the primary action / focus-ring accent.
/// Named `focusRingColor`, not `accentColor`, to avoid colliding with
/// SwiftUI's own (deprecated) `View.accentColor(_:)` modifier.
let focusRingColor = Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)

func plural(_ n: Int) -> String { n == 1 ? "" : "s" }

func describeFailures(_ failures: [(URL, String)]) -> String {
    failures.map { "\($0.0.path): \($0.1)" }.joined(separator: "; ")
}
