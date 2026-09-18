import SwiftUI

struct FinalizeSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rejectedCount = model.rejectedPaths().count
        let keeperCount = model.keeperPaths().count
        let undecidedCount = model.undecidedCount()

        VStack(alignment: .leading, spacing: 14) {
            Text("Finalize").font(.title2.bold())
            Text("Choose what to do with this session's decisions.")
                .foregroundStyle(.secondary)

            Toggle(
                "Move \(rejectedCount) rejected photo\(plural(rejectedCount)) to the trash",
                isOn: $model.finalizeTrashRejected
            )
            .disabled(rejectedCount == 0)

            Toggle(
                "Copy \(keeperCount) keeper\(plural(keeperCount)) to a folder",
                isOn: $model.finalizeCopyKeepers
            )
            .disabled(keeperCount == 0)

            if model.finalizeCopyKeepers {
                HStack {
                    if let dest = model.finalizeDestination {
                        Text(dest.path).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("No destination chosen").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose…") {
                        if let folder = FolderPicker.pickDestinationFolder() {
                            model.finalizeDestination = folder
                        }
                    }
                }
            }

            if undecidedCount > 0 {
                Text("\(undecidedCount) undecided photo\(plural(undecidedCount)) will be treated as keepers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showFinalize = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Confirm") {
                    let destination = model.finalizeCopyKeepers ? model.finalizeDestination : nil
                    model.runFinalize(trashRejected: model.finalizeTrashRejected, copyDestination: destination)
                    model.showFinalize = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.finalizeCopyKeepers && model.finalizeDestination == nil && keeperCount > 0)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
