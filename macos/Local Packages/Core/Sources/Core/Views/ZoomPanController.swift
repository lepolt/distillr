import AppKit
import SwiftUI

/// Pinch-zoom / two-finger-pan / double-click-to-reset state, shared by
/// `ReviewView`'s single image and `CompareView`'s several (which all
/// read the same controller, so they zoom/pan together). Extracted here
/// once both views needed it, rather than duplicating the whole
/// gesture/clamping machinery a second time.
@MainActor
@Observable
final class ZoomPanController {
    /// What the Slider and Reset Zoom button actually read/write. Updated
    /// directly by a slider drag, but — see `installGestureMonitors` —
    /// only written ONCE per pinch, right when the gesture ends, never on
    /// every event during it.
    var zoomScale: CGFloat = 1
    /// What the image's `scaleEffect` actually reads. Updated on every
    /// single magnify event for a smooth live zoom, without ever touching
    /// `zoomScale` (and so never touching the Slider) mid-gesture.
    var liveScale: CGFloat = 1
    var panOffset: CGSize = .zero
    /// True only while the cursor is actually over the image this
    /// controller belongs to. Pinch and two-finger-pan are both read from
    /// app-wide `NSEvent` monitors (see `installGestureMonitors`), which
    /// have no spatial scoping of their own — without this check, either
    /// would fire no matter where the cursor was in the window, not just
    /// over the image. Set via `.onHover` on the image view.
    var isHovering = false
    private var magnifyMonitor: Any?
    private var scrollMonitor: Any?

    func reset() {
        zoomScale = 1
        liveScale = 1
        panOffset = .zero
    }

    /// Called when the zoom slider finishes a drag, to re-clamp pan for
    /// the new scale and keep the live (image) value in sync with the
    /// slider-driven one.
    func syncAfterSliderEdit() {
        liveScale = zoomScale
        panOffset = clampedPan(panOffset, zoomScale: zoomScale)
    }

    /// A real double-tap gesture rather than reading `NSApp.currentEvent`'s
    /// clickCount — that approach proved unreliable specifically on views
    /// that also carried a magnify gesture. Unlike the magnify gesture
    /// itself (see `installGestureMonitors`), this is a discrete,
    /// non-continuous SwiftUI gesture, which doesn't have the same
    /// window-wide event-capture behavior, so it's left as-is.
    var doubleTapToResetGesture: some Gesture {
        TapGesture(count: 2).onEnded { self.reset() }
    }

    /// Pinch-to-zoom and two-finger-pan are both implemented as passive
    /// local `NSEvent` monitors, not SwiftUI's `MagnifyGesture`/
    /// `DragGesture` — avoids a real AppKit `NSGestureRecognizer` fighting
    /// SwiftUI's own gesture handling elsewhere in the view.
    ///
    /// KNOWN ISSUE, shelved (not fixed): right after a pinch, the Zoom
    /// slider row (the `Slider` and "Reset Zoom" button in
    /// `ZoomSliderRow` below) can take several taps before one registers.
    /// Ruled out by direct testing, not just reasoning: a real
    /// `MagnifyGesture` recognizer capturing window-wide event delivery
    /// (removed entirely — no change); re-render churn during the pinch
    /// (already isolated to just this gesture's own subviews — no
    /// change); stale `isHovering` (verified via logging to transition
    /// cleanly); update rate of the write to `zoomScale`, the property
    /// the Slider is bound to (throttled to 30Hz — no change); writing to
    /// `zoomScale` at all mid-gesture (split into `zoomScale`, written
    /// once at `.ended`, and `liveScale` for the image, updated every
    /// event — no change). It reproduces only in this one row, never on
    /// other buttons in the same window, including ones physically
    /// closer to the pinch (the nav chevrons beside the image). The
    /// `zoomScale`/`liveScale` split and the `isHovering` gating are kept
    /// because they're correct/harmless on their own merits, not because
    /// either fixed this. There is a working user-side workaround
    /// (tapping repeatedly eventually registers), so this is parked
    /// rather than actively worked — pick it back up with real
    /// diagnostics (e.g. Instruments' view hierarchy / hit-testing during
    /// repro) rather than another guess if revisited.
    ///
    /// Both are gated on `isHovering`, so they only ever act while the
    /// cursor is actually over the image — install while the owning view
    /// is on screen and remove when it isn't.
    func installGestureMonitors() {
        if magnifyMonitor == nil {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, self.isHovering else { return event }
                if event.phase == .began {
                    self.liveScale = self.zoomScale
                }
                // `event.magnification` is the incremental change since
                // the previous magnify event, not a cumulative
                // since-gesture-start factor — apply it directly against
                // the running live scale rather than tracking a separate
                // gesture-start "base" the way SwiftUI's MagnifyGesture
                // needed.
                let newScale = min(max(self.liveScale * (1 + event.magnification), 1), 8)
                self.liveScale = newScale
                self.panOffset = self.clampedPan(self.panOffset, zoomScale: newScale)
                if event.phase == .ended || event.phase == .cancelled {
                    self.zoomScale = newScale
                }
                return event
            }
        }
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.isHovering, self.liveScale > 1.01 else { return event }
                let proposed = CGSize(
                    width: self.panOffset.width + event.scrollingDeltaX,
                    height: self.panOffset.height + event.scrollingDeltaY
                )
                self.panOffset = self.clampedPan(proposed, zoomScale: self.liveScale)
                return event
            }
        }
    }

    func removeGestureMonitors() {
        if let magnifyMonitor {
            NSEvent.removeMonitor(magnifyMonitor)
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
        magnifyMonitor = nil
        scrollMonitor = nil
    }

    /// Keeps the panned image from drifting further than it can zoom back
    /// to — bounded proportionally to how far past 1x the image is zoomed,
    /// and exactly zero at 1x, so returning to 1x always recenters.
    private func clampedPan(_ offset: CGSize, zoomScale: CGFloat) -> CGSize {
        let maxOffset = 260 * (zoomScale - 1)
        guard maxOffset > 0 else { return .zero }
        return CGSize(
            width: min(max(offset.width, -maxOffset), maxOffset),
            height: min(max(offset.height, -maxOffset), maxOffset)
        )
    }
}

/// "Zoom" label + slider + reset button, identical between Review and
/// Compare.
///
/// The slider is split out into its own `ZoomSliderControl` rather than
/// reading `controller.zoomScale` directly in this view's own body, so a
/// slider-only re-render never touches this row's label or Reset Zoom
/// button. This row can still take several taps to respond right after a
/// pinch — see the KNOWN ISSUE note on `ZoomPanController.installGestureMonitors`.
struct ZoomSliderRow: View {
    var controller: ZoomPanController

    var body: some View {
        HStack(spacing: 12) {
            Text("Zoom").foregroundStyle(.secondary)
            ZoomSliderControl(controller: controller)
                .frame(width: 160)
            Button("Reset Zoom") { controller.reset() }
        }
        .buttonStyle(.glass)
    }
}

private struct ZoomSliderControl: View {
    // @Bindable specifically so `$controller.zoomScale` below is the
    // native, stable binding the Observation macro generates — not a
    // fresh `Binding(get:set:)` closure allocated on every access (which
    // is what this used to do via a computed `sliderBinding` property,
    // itself a separate cause of unresponsiveness now fixed alongside
    // this one).
    @Bindable var controller: ZoomPanController

    var body: some View {
        Slider(value: $controller.zoomScale, in: 1...8) { editing in
            if !editing {
                controller.syncAfterSliderEdit()
            }
        }
    }
}
