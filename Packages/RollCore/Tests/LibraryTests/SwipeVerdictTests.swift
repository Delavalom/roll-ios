import Testing
@testable import Library

/// The rule the review confirmed and this pins: no card the user hasn't seen is deleted, kept, moved or learned from.
struct SwipeVerdictTests {
  /// Store's `Verdict`, which Library doesn't import.
  enum Verdict: Sendable, Equatable, CaseIterable { case action, keep, album }

  struct Card: Identifiable, Equatable { let id: String }

  @Test func onlyACardOnScreenRecordsAVerdict() {
    for verdict in Verdict.allCases {
      #expect(SwipeVerdict.resolve(gate: .decide, requested: verdict) == .record(verdict))
      #expect(SwipeVerdict.resolve(gate: .skipOnly, requested: verdict) == .skip,
              "nothing on screen: a swipe or button skips, never records")
      #expect(SwipeVerdict.resolve(gate: .wait, requested: verdict) == .ignore, "still loading: nothing happens")
    }
  }

  @Test func skipWorksOnlyOnACardThatCantBeShown() {
    #expect(SwipeVerdict<Verdict>.resolve(gate: .skipOnly, requested: nil) == .skip)
    #expect(SwipeVerdict<Verdict>.resolve(gate: .decide, requested: nil) == .ignore,
            "a photo on screen gets a verdict, not a skip")
    #expect(SwipeVerdict<Verdict>.resolve(gate: .wait, requested: nil) == .ignore)
  }

  @Test func everyGateAndRequestRecordsOnlyWhenDecidable() {
    let gates: [CardGate] = [.decide, .wait, .skipOnly]
    let requests: [Verdict?] = Verdict.allCases + [nil]
    for gate in gates {
      for requested in requests {
        if case .record = SwipeVerdict.resolve(gate: gate, requested: requested) {
          #expect(gate == .decide && requested != nil)
        }
      }
    }
  }

  @Test func skippedCardsStayOutOfRefills() {
    let fresh = SwipeRefill.fresh([Card(id: "a"), Card(id: "b"), Card(id: "c"), Card(id: "d")],
                                  showing: ["a"], skipped: ["c"])
    #expect(fresh.map(\.id) == ["b", "d"], "already showing (a) and skipped this session (c) are left out")
  }
}
