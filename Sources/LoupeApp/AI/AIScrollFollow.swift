import AppKit
import SwiftUI

/// Whether the transcript keeps up with new output. It does until the user scrolls up, and starts
/// again when they come back to the bottom. Only the user's own scrolling counts: the view's own
/// jumps to the end, and the content growing underneath, don't change it.
@MainActor
final class AIScrollFollow: ObservableObject {
    /// What the button goes by. It changes a beat after `sticking`: laying the button out in the
    /// middle of a wheel event loses that event's scroll.
    @Published private(set) var following = true
    /// What the view goes by, up to date the moment the user moves.
    private var sticking = true {
        didSet {
            guard sticking != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.following != self.sticking else { return }
                self.following = self.sticking
            }
        }
    }
    /// Holding the scroller or mid-gesture. The view never moves under the user's hand, even at the bottom.
    private(set) var userScrolling = false
    /// When the wheel or trackpad last moved toward the top. It only says anything about the
    /// movement that lands right after it, not a later drag of the scroller.
    private var wheeledUpAt = Date.distantPast
    private var wheelingUp: Bool { Date().timeIntervalSince(wheeledUpAt) < 0.5 }
    /// How close to the bottom counts as "at the bottom".
    private let nearBottom: CGFloat = 24
    private(set) weak var scrollView: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private var wheelMonitor: Any?

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
    }

    var shouldStick: Bool { sticking && !userScrolling }

    func resume() {
        sticking = true
        userScrolling = false
        wheeledUpAt = .distantPast
    }

    func attach(_ view: NSScrollView) {
        guard view !== scrollView else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        scrollView = view
        // Delivered on the spot rather than queued, so a jump to the end can't slip in between the
        // user taking hold of the scroller and this hearing about it.
        func on(_ name: Notification.Name, _ act: @escaping @MainActor (AIScrollFollow) -> Void) {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { if let self { act(self) } }
            })
        }
        on(NSScrollView.willStartLiveScrollNotification) { $0.userScrolling = true }
        on(NSScrollView.didLiveScrollNotification) { $0.userMoved() }
        on(NSScrollView.didEndLiveScrollNotification) {
            $0.userMoved()
            $0.userScrolling = false
        }
        // A wheel's movement lands a moment later, by which time a jump to the end may have undone
        // it, so where the view ended up can't say which way the user went. The event itself can.
        if wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.wheel(event) }
                return event
            }
        }
    }

    private func wheel(_ event: NSEvent) {
        guard let view = scrollView, event.window === view.window,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
        wheelMoved(deltaY: event.scrollingDeltaY)
    }

    /// Positive moves toward the top, whichever way the user has scrolling set up.
    func wheelMoved(deltaY: CGFloat) {
        guard deltaY != 0, let view = scrollView, let doc = view.documentView else { return }
        wheeledUpAt = deltaY > 0 ? Date() : .distantPast
        if deltaY > 0, doc.bounds.height > view.contentView.bounds.height { sticking = false }
    }

    private func userMoved() {
        let distance = distanceToBottom
        if distance <= nearBottom {
            if !wheelingUp { sticking = true }
        } else if userScrolling {
            // Only while holding on: a lone wheel tick can land just after the content grew, which
            // looks like being far from the bottom without the user having gone anywhere.
            sticking = false
        }
    }

    var distanceToBottom: CGFloat {
        guard let view = scrollView, let doc = view.documentView else { return 0 }
        return doc.bounds.height - view.contentView.bounds.maxY
    }
}

/// Finds the NSScrollView behind the SwiftUI ScrollView, which is what reports the user's scrolling.
struct AIScrollFollowProbe: NSViewRepresentable {
    let follow: AIScrollFollow

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.follow = follow
        return v
    }

    func updateNSView(_ v: Probe, context: Context) {
        v.follow = follow
        v.attach()
    }

    final class Probe: NSView {
        var follow: AIScrollFollow?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() {
            if let s = enclosingScrollView { follow?.attach(s) }
        }
    }
}
