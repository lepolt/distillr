import SwiftUI

/// A thumbnail with a decision-color border, and an optional outer accent
/// ring for "this is the focused/current/selected one" — mirrors the
/// nested-frame pattern used throughout the grid, review filmstrip, and
/// compare panels.
struct BorderedThumbnail: View {
    let image: CGImage?
    let decisionColor: Color
    var accentRing: Bool = false
    var size: CGFloat = 90

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(decisionColor, lineWidth: 2))
        .padding(3)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(accentRing ? focusRingColor : .clear, lineWidth: 3)
        )
    }
}
