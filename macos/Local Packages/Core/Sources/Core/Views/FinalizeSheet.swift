import SwiftUI

struct FinalizeSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rejectedCount = model.rejectedPaths().count
        let keeperCount = model.keeperPaths(treatUndecidedAsKeepers: model.finalizeTreatUndecidedAsKeepers).count
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
                            model.validateFinalizeDestination()
                        }
                    }
                }

                // Caught here, before Confirm, rather than only surfacing
                // as a wall of per-photo copy failures after the fact —
                // this is exactly the App Sandbox permission failure that
                // first showed up as Finalize silently failing to copy
                // anything off an SD card.
                if let error = model.finalizeDestinationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if model.finalizeCopyKeepers && undecidedCount > 0 {
                Toggle(
                    "Treat \(undecidedCount) undecided photo\(plural(undecidedCount)) as keeper\(plural(undecidedCount))",
                    isOn: $model.finalizeTreatUndecidedAsKeepers
                )
                .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    model.showFinalize = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Confirm") {
                    if model.finalizeCopyKeepers {
                        model.validateFinalizeDestination()
                        guard model.finalizeDestinationError == nil else { return }
                    }
                    let destination = model.finalizeCopyKeepers ? model.finalizeDestination : nil
                    model.runFinalize(
                        trashRejected: model.finalizeTrashRejected,
                        copyDestination: destination,
                        treatUndecidedAsKeepers: model.finalizeTreatUndecidedAsKeepers
                    )
                    model.showFinalize = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.finalizeCopyKeepers && keeperCount > 0
                        && (model.finalizeDestination == nil || model.finalizeDestinationError != nil)
                )
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { model.validateFinalizeDestination() }
    }
}
