import SwiftUI

/// Shown in place of the grid when no folder is loaded yet. Two large,
/// side-by-side tiles instead of a small toolbar button — the point is
/// discoverability: a first-time user should immediately see that dropping
/// a folder is an option, not just clicking one.
struct WelcomeView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeting = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Text("Distillr").font(.largeTitle.bold())
                Text("Pick a folder of photos to start culling.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Tile(
                    systemImage: "folder.fill",
                    title: "Choose Folder…",
                    subtitle: "Browse for a folder of photos",
                    isDashed: false,
                    isHighlighted: false
                ) {
                    if let folder = FolderPicker.pickFolder() {
                        model.loadFolder(folder)
                    }
                }

                Tile(
                    systemImage: "square.and.arrow.down",
                    title: "or Drop Folder Here",
                    subtitle: "Drag a folder from Finder",
                    isDashed: true,
                    isHighlighted: isDropTargeting,
                    action: nil
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeting) { providers in
                    FolderPicker.resolveDroppedFolder(providers) { model.loadFolder($0) }
                }
            }
            .frame(maxWidth: 640)

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private struct Tile: View {
        let systemImage: String
        let title: String
        let subtitle: String
        let isDashed: Bool
        let isHighlighted: Bool
        var action: (() -> Void)?

        var body: some View {
            let content = VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                VStack(spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isHighlighted ? Color.accentColor : Color(nsColor: .separatorColor),
                        style: StrokeStyle(lineWidth: isHighlighted ? 2 : 1, dash: isDashed ? [7, 6] : [])
                    )
            }

            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }
}
