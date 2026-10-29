/// How long each step of one `SwipefileEngine.candidates` call took (ContinuousClock), for benchmarks and the
/// DEBUG-only QA search bench. Steps that didn't run stay zero. Identifier-free.
public struct SearchTimings: Sendable, Equatable {
  /// Reading the stored swipefile.
  public var lookup: Duration = .zero
  /// Reading candidate rows from SQL (zero when the in-memory pool was current).
  public var sql: Duration = .zero
  /// Reading this swipefile's decided asset ids (every call).
  public var decisions: Duration = .zero
  /// Building the scoring pool from the rows (filter, decisions, boosts, alignment with the vectors).
  public var pool: Duration = .zero
  /// Prompt vectors (cached per swipefile) and the mean example vector.
  public var queries: Duration = .zero
  /// The dot products of every stored vector with every query.
  public var dot: Duration = .zero
  /// Combining dots and boosts, the floor, and the top `limit`.
  public var score: Duration = .zero
  /// The whole call.
  public var total: Duration = .zero
  /// How many pool entries were scored.
  public var poolCount = 0

  public init() {}

  /// Step name → milliseconds, in call order (for logs and JSON).
  public var milliseconds: [(step: String, ms: Double)] {
    let steps: [(String, Duration)] = [("lookup", lookup), ("sql", sql), ("decisions", decisions), ("pool", pool),
                                       ("queries", queries), ("dot", dot), ("score", score), ("total", total)]
    return steps.map { ($0.0, Self.ms($0.1)) }
  }

  public static func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
  }
}
