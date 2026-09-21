extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import AppKit

extension NSEvent {
    /// `clickCount` is only valid on mouse-click-family events — calling it
    /// on any other event type (e.g. a trailing Magnify/pinch event) raises
    /// `NSInternalInconsistencyException: Invalid message sent to event`.
    /// Compare's panel buttons sit under a simultaneous magnify/pan
    /// gesture, and a pinch ending can spuriously trigger the button's own
    /// tap recognizer while `NSApp.currentEvent` is still that Magnify
    /// event, so double-click detection has to check the event type first
    /// rather than assuming it's always a click.
    var isDoubleClick: Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return clickCount == 2
        default:
            return false
        }
    }
}
