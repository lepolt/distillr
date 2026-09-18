import SwiftUI

/// An invisible button that exists purely to carry a `.keyboardShortcut`.
/// Confirmed (Apple docs + community reports) that a SwiftUI keyboard
/// shortcut stays active as long as its button is present in the view
/// hierarchy — it doesn't need to be visible or focused, unlike
/// `.onKeyPress`. Scoping a shortcut to "only active in Review" is just a
/// matter of only including this button while Review is showing, which
/// happens for free since GridView/ReviewView/CompareView are already
/// mutually-exclusive conditional content in ContentView.
///
/// `action` must read whatever state it needs from `model` (a reference
/// type) *inside the closure body* — never from a value captured from the
/// surrounding view's local `let` bindings. There's a real, documented
/// SwiftUI bug where a `.keyboardShortcut`-carrying button can keep firing
/// a stale closure instance from an earlier render; a closure that only
/// touches `model`'s current properties is immune to that, since it reads
/// fresh state at call time regardless of which render created it.
struct ShortcutButton: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
