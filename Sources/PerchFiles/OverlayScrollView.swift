import AppKit
import SwiftUI

class OverlayScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollerStyle = .overlay
        autohidesScrollers = true
    }

    required init?(coder: NSCoder) { nil }

    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set {
            if super.scrollerStyle != .overlay { super.scrollerStyle = .overlay }
        }
    }
}

struct OverlayScrollIndicators: NSViewRepresentable {
    func makeNSView(context: Context) -> Attachment { Attachment() }
    func updateNSView(_ attachment: Attachment, context: Context) { attachment.applyStyle() }

    final class Attachment: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard window != nil else { return }
            applyStyle()
            NotificationCenter.default.addObserver(self, selector: #selector(applyAfterPreferenceChange),
                name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func applyStyle() {
            if let scroll = enclosingScrollView, scroll.scrollerStyle != .overlay {
                scroll.scrollerStyle = .overlay
            }
        }

        @objc private func applyAfterPreferenceChange() {
            DispatchQueue.main.async { [weak self] in self?.applyStyle() }
        }
    }
}
