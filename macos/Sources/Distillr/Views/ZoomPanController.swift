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
    var zoomScale: CGFloat = 1
    var panOffset: CGSize = .zero
    /// Running base for the magnify gesture — its value at the start of
    /// the current gesture, so `onChanged` can apply the delta on top of
    /// it.
    private var zoomBase: CGFloat = 1
    /// Local NSEvent monitor token for two-finger scroll panning — see
    /// `installScrollPanMonitor`.
    private var scrollMonitor: Any?

    func reset() {
        zoomScale = 1
        panOffset = .zero
        zoomBase = 1
    }

    /// Slider-compatible binding — unlike a plain `$zoomScale`, moving the
    /// slider also keeps `zoomBase` in sync. Without that, a pinch right
    /// after using the slider would jump: it always multiplies from
    /// `zoomBase`, which would still be wherever the last *pinch* left it,
    /// not where the slider just moved to.
    var sliderBinding: Binding<CGFloat> {
        Binding(
            get: { self.zoomScale },
            set: { newValue in
                self.zoomScale = newValue
                self.zoomBase = newValue
                self.panOffset = self.clampedPan(self.panOffset, zoomScale: newValue)
            }
        )
    }

    var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = min(max(self.zoomBase * value.magnification, 1), 8)
                self.zoomScale = newScale
                self.panOffset = self.clampedPan(self.panOffset, zoomScale: newScale)
            }
            .onEnded { _ in
                self.zoomBase = self.zoomScale
            }
    }

    /// A real double-tap gesture rather than reading `NSApp.currentEvent`'s
    /// clickCount — that approach proved unreliable specifically on views
    /// that also carry a magnify gesture, most likely because the
    /// recognizer interferes with how promptly AppKit's own click-count
    /// timing sees two clicks as consecutive.
    var doubleTapToResetGesture: some Gesture {
        TapGesture(count: 2).onEnded { self.reset() }
    }

    /// SwiftUI has no gesture type for a raw two-finger trackpad pan
    /// outside of `ScrollView` (unlike pinch, which `MagnifyGesture`
    /// covers natively) — this is the one narrow, deliberate AppKit
    /// touchpoint here, reading `NSEvent.scrollWheel` directly via a local
    /// monitor. Install while the owning view is on screen and remove when
    /// it isn't. It only reads events; it always returns them unmodified,
    /// so nothing else in the app that might care about scrolling is
    /// affected.
    func installScrollPanMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.zoomScale > 1.01 else { return event }
            let proposed = CGSize(
                width: self.panOffset.width + event.scrollingDeltaX,
                height: self.panOffset.height + event.scrollingDeltaY
            )
            self.panOffset = self.clampedPan(proposed, zoomScale: self.zoomScale)
            return event
        }
    }

    func removeScrollPanMonitor() {
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
        }
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
struct ZoomSliderRow: View {
    var controller: ZoomPanController

    var body: some View {
        HStack(spacing: 12) {
            Text("Zoom").foregroundStyle(.secondary)
            Slider(value: controller.sliderBinding, in: 1...8)
                .frame(width: 160)
            Button("Reset Zoom") { controller.reset() }
        }
        .buttonStyle(.glass)
    }
}
