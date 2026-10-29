/// SplitMix64: a small, fast, seedable `RandomNumberGenerator` so test data is reproducible.
struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// `v / |v|`.
func unitVector(_ v: [Float]) -> [Float] {
  let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
  return v.map { $0 / n }
}

/// A random unit vector.
func randomUnit(_ dims: Int, using g: inout SeededRNG) -> [Float] {
  unitVector((0..<dims).map { _ in Float.random(in: -1...1, using: &g) })
}
