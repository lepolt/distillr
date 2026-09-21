import SwiftUI
import UniformTypeIdentifiers

/// The one public entry point into Core's UI — everything it composes
/// (`GridView`, `ReviewView`, `CompareView`, `WelcomeView`, ...) stays
/// internal. The app target just hosts this inside its own `WindowGroup`,
/// alongside whatever's actually an app-lifecycle concern (window
/// activation, icon, sizing) rather than part of the culling UI itself.
public struct ContentView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeting = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.groups.isEmpty {
                header
            }

            Group {
                if model.compare != nil {
                    CompareView(model: model)
                } else if model.review != nil {
                    ReviewView(model: model)
                } else if model.groups.isEmpty {
                    WelcomeView(model: model)
                } else {
                    GridView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $model.showFinalize) {
            FinalizeSheet(model: model)
        }
    }

    /// The compact folder/status bar shown once a folder is loaded. Before
    /// that, `WelcomeView`'s large tiles are the only "choose/drop a
    /// folder" affordance; once a folder's loaded there's nothing left for
    /// a "Choose Folder…" button here to do that dropping a new one on
    /// this row doesn't already cover, so it's just the path plus Finalize
    /// — but the row stays a functional drop target, so switching to a
    /// different folder later doesn't require going back to an empty
    /// state first.
    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let folder = model.sourceFolder {
                    Text(folder.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Finalize…") {
                    model.showFinalize = true
                }
                .buttonStyle(.glassProminent)
            }
            .padding([.horizontal, .top])
            .padding(.vertical, 6)
            .background(isDropTargeting ? Color.accentColor.opacity(0.12) : .clear)
            .overlay {
                if isDropTargeting {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                        .padding(2)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeting) { providers in
                FolderPicker.resolveDroppedFolder(providers) { model.loadFolder($0) }
            }

            if !model.status.isEmpty {
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            Text("Keep \(model.keepCount())   Reject \(model.rejectedPaths().count)   Undecided \(model.undecidedCount())")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            if let commitStatus = model.commitStatus {
                Text(commitStatus)
                    .font(.callout)
                    .padding(.horizontal)
            }
            if model.thumbnailsTotal > 0, model.thumbnails.count < model.thumbnailsTotal {
                Text("Loading thumbnails: \(model.thumbnails.count)/\(model.thumbnailsTotal)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }

            Divider()
        }
    }
}
