/// The `count` largest of a stream of values, without keeping or sorting the rest (the nothing-found test needs the
/// best 50 z of ~30k photos). Ascending internally; insertion is a binary search into at most `count` values.
struct TopFloats {
  let count: Int
  private var values: [Float] = []

  init(count: Int) {
    self.count = max(count, 0)
    values.reserveCapacity(self.count)
  }

  mutating func insert(_ value: Float) {
    guard count > 0 else { return }
    if values.count == count {
      guard value > values[0] else { return }
      values.removeFirst()
    }
    var low = 0, high = values.count
    while low < high {
      let mid = (low + high) / 2
      if values[mid] < value { low = mid + 1 } else { high = mid }
    }
    values.insert(value, at: low)
  }

  /// Largest first.
  var descending: [Float] { values.reversed() }
}
