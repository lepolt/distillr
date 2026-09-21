import AppKit
import SwiftUI

struct GridView: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let columnsPerRow = max(Int(geometry.size.width / 132), 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { groupIndex, group in
                        BurstSectionView(model: model, groupIndex: groupIndex, group: group)
                    }
                }
                .padding()
            }
            .onAppear { model.gridColumnsPerRow = columnsPerRow }
            .onChange(of: columnsPerRow) { _, newValue in model.gridColumnsPerRow = newValue }
            .background(shortcuts)
        }
    }

    @ViewBuilder
    private var shortcuts: some View {
        ShortcutButton(key: .leftArrow) { model.moveGridFocus(deltaCol: -1, deltaRow: 0, columnsPerRow: model.gridColumnsPerRow) }
        ShortcutButton(key: .rightArrow) { model.moveGridFocus(deltaCol: 1, deltaRow: 0, columnsPerRow: model.gridColumnsPerRow) }
        ShortcutButton(key: .upArrow) { model.moveGridFocus(deltaCol: 0, deltaRow: -1, columnsPerRow: model.gridColumnsPerRow) }
        ShortcutButton(key: .downArrow) { model.moveGridFocus(deltaCol: 0, deltaRow: 1, columnsPerRow: model.gridColumnsPerRow) }
        ShortcutButton(key: .return) {
            guard let focused = model.focusedGridItem() else { return }
            model.enterReview(groupIndex: focused.groupIndex, itemIndex: focused.itemIndex)
        }
    }
}

/// One burst's section of the grid — its own view (rather than a plain
/// function) so the "Rejected" disclosure can hold its own collapsed/
/// expanded `@State` per burst.
private struct BurstSectionView: View {
    @Bindable var model: AppModel
    let groupIndex: Int
    let group: BurstGroup

    @State private var showRejected = false

    var body: some View {
        let activeItems = group.items.enumerated().filter { (model.decisions[$0.element.path] ?? .undecided) != .reject }
        let rejectedItems = group.items.enumerated().filter { (model.decisions[$0.element.path] ?? .undecided) == .reject }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Burst \(groupIndex + 1)").font(.headline)
                Text("\(group.items.count) photos").foregroundStyle(.secondary)
                Button("Review") {
                    model.enterReview(groupIndex: groupIndex, itemIndex: 0)
                }
                let selectedHere = group.items.map(\.path).filter { model.selected.contains($0) }
                if selectedHere.count >= 2 {
                    Button("Compare (\(selectedHere.count))") {
                        model.enterCompare(groupIndex: groupIndex, paths: selectedHere)
                    }
                }
                Spacer()
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(Array(activeItems.enumerated()), id: \.element.offset) { activeIndex, entry in
                        let (itemIndex, item) = entry
                        thumbnail(groupIndex: groupIndex, itemIndex: itemIndex, activeIndex: activeIndex, path: item.path)
                    }
                }
            }

            if !rejectedItems.isEmpty {
                DisclosureGroup(isExpanded: $showRejected) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 4) {
                            ForEach(Array(rejectedItems), id: \.offset) { _, item in
                                Button {
                                    model.decisions[item.path] = .undecided
                                } label: {
                                    BorderedThumbnail(image: model.thumbnails[item.path], decisionColor: model.borderColor(for: item.path), size: 60)
                                }
                                .buttonStyle(.plain)
                                .focusable(false)
                                .help("Click to restore")
                            }
                        }
                        .padding(.top, 4)
                    }
                } label: {
                    Text("Rejected (\(rejectedItems.count))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(groupIndex: Int, itemIndex: Int, activeIndex: Int, path: URL) -> some View {
        let isFocusedItem = model.gridFocus?.groupIndex == groupIndex && model.gridFocus?.activeIndex == activeIndex
        let isSelected = model.selected.contains(path)

        Button {
            model.gridFocus = GridFocus(groupIndex: groupIndex, activeIndex: activeIndex)
            if NSApp.currentEvent?.isDoubleClick == true {
                model.enterReview(groupIndex: groupIndex, itemIndex: itemIndex)
            } else if NSEvent.modifierFlags.contains(.command) {
                if isSelected { model.selected.remove(path) } else { model.selected.insert(path) }
            }
        } label: {
            BorderedThumbnail(
                image: model.thumbnails[path],
                decisionColor: model.borderColor(for: path),
                accentRing: isFocusedItem || isSelected
            )
        }
        .buttonStyle(.plain)
        // Keyboard navigation is handled entirely by the ShortcutButtons
        // above; without this, AppKit's own native arrow-key focus-
        // traversal between these many repeated buttons competes with it
        // and beeps when it can't find a next control in some direction.
        .focusable(false)
        .help("Click to select, Cmd-click to multi-select for Compare, Enter to review the focused photo")
    }
}
