import SwiftUI
import UIKit

/// Swipe to select, as in Photos: a drag that starts sideways over the grid selects (or deselects) every photo it
/// passes; a drag that starts up or down still scrolls. Holding the finger near the top or bottom edge of the scroll
/// view scrolls it, and the selection follows the photo under the finger. Reports grid indexes, each change once.
struct DragSelectGesture: UIGestureRecognizerRepresentable {
  /// The photo index under a point in the grid's own coordinates (may be out of range; the selection clamps it).
  var index: (CGPoint) -> Int
  var began: (Int) -> Void
  var moved: (Int) -> Void
  var ended: () -> Void

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator(converter: converter)
  }

  func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
    let pan = UIPanGestureRecognizer()
    pan.maximumNumberOfTouches = 1
    pan.delegate = context.coordinator
    return pan
  }

  func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
    context.coordinator.gesture = self
  }

  func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
    let coordinator = context.coordinator
    coordinator.gesture = self
    switch recognizer.state {
    case .began:
      // Where the finger went down, not where the pan was recognized (a few points later).
      let start = context.converter.localLocation - (context.converter.localTranslation ?? .zero)
      coordinator.begin(recognizer, at: index(start))
    case .changed:
      coordinator.move(to: index(context.converter.localLocation))
    default:
      coordinator.end()
    }
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var gesture: DragSelectGesture?
    private let converter: CoordinateSpaceConverter
    private weak var pan: UIPanGestureRecognizer?
    private weak var scrollView: UIScrollView?
    private var link: CADisplayLink?
    private var last: Int?

    /// Points from the scroll view's visible top or bottom where autoscroll starts, and its top speed (points/s).
    private let edge: CGFloat = 72
    private let topSpeed: CGFloat = 1100

    init(converter: CoordinateSpaceConverter) {
      self.converter = converter
    }

    func begin(_ pan: UIPanGestureRecognizer, at index: Int) {
      self.pan = pan
      scrollView = Self.enclosingScrollView(of: pan)
      last = index
      gesture?.began(index)
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    func move(to index: Int) {
      guard last != nil, index != last else { return }
      last = index
      gesture?.moved(index)
    }

    func end() {
      link?.invalidate()
      link = nil
      guard last != nil else { return }
      last = nil
      gesture?.ended()
    }

    /// Autoscroll while the finger rests near an edge; the photo under it changes as the content moves.
    @objc private func tick(_ link: CADisplayLink) {
      guard let pan, let scrollView, let gesture else { return }
      let y = pan.location(in: scrollView).y - scrollView.contentOffset.y
      let insets = scrollView.adjustedContentInset
      let top = insets.top + edge
      let bottom = scrollView.bounds.height - insets.bottom - edge
      let depth: CGFloat = y < top ? -min(1, (top - y) / edge) : y > bottom ? min(1, (y - bottom) / edge) : 0
      guard depth != 0 else { return }
      let minY = -insets.top
      let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + insets.bottom)
      let step = depth * topSpeed * CGFloat(link.targetTimestamp - link.timestamp)
      let next = min(max(scrollView.contentOffset.y + step, minY), maxY)
      guard next != scrollView.contentOffset.y else { return }
      scrollView.contentOffset.y = next
      move(to: gesture.index(converter.localLocation))
    }

    // MARK: UIGestureRecognizerDelegate

    /// Only a sideways start selects; up or down is left to the scroll view.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
      let t = pan.translation(in: pan.view)
      return abs(t.x) > abs(t.y)
    }

    /// The scroll view waits until this pan decides, so a sideways drag never scrolls as well.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
      guard let scroll = other.view as? UIScrollView else { return false }
      return other === scroll.panGestureRecognizer
    }

    private static func enclosingScrollView(of pan: UIPanGestureRecognizer) -> UIScrollView? {
      var view = pan.view
      if let host = view, let hit = host.hitTest(pan.location(in: host), with: nil) { view = hit }
      while let current = view {
        if let scroll = current as? UIScrollView { return scroll }
        view = current.superview
      }
      return nil
    }
  }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
