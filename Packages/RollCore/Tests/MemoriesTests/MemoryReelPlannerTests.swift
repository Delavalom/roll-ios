import Foundation
import Testing
@testable import Memories

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func photo(_ id: Int, hour: Double, aesthetic: Double? = 0.1, group: String? = nil, keeper: Bool = true,
                   utility: Bool = false) -> ReelCandidate {
  ReelCandidate(id: "p\(id)", created: t0.addingTimeInterval(hour * 3600), aesthetic: aesthetic,
                isScreenshotOrDocument: utility, similarGroup: group, isKeeper: keeper)
}

private func trip(_ n: Int) -> [ReelCandidate] { (0..<n).map { photo($0, hour: Double($0), aesthetic: Double($0 % 7) / 10) } }

struct MemoryReelPlannerTests {
  @Test func fewerThanSixSaysNotEnoughPhotos() {
    let plan = MemoryReelPlanner.plan(candidates: trip(5))
    #expect(plan.problem == .notEnoughPhotos(have: 5, need: 6))
    #expect(plan.shots.isEmpty && !plan.isUsable)
    #expect(plan.problem?.message.contains("Not enough photos") == true)
  }

  @Test func dropsScreenshotsAndDocuments() {
    var list = trip(8)
    list += (100..<110).map { photo($0, hour: Double($0 - 100), utility: true) }
    let plan = MemoryReelPlanner.plan(candidates: list)
    #expect(plan.shots.allSatisfy { (Int($0.id.dropFirst()) ?? 0) < 100 })
    #expect(plan.shots.count == 8)
  }

  @Test func screenshotsDoNotCountTowardTheMinimum() {
    let list = trip(5) + (100..<110).map { photo($0, hour: 1, utility: true) }
    #expect(MemoryReelPlanner.plan(candidates: list).problem == .notEnoughPhotos(have: 5, need: 6))
  }

  @Test func keepsOnlyTheKeeperOfEachSimilarGroup() {
    var list = trip(8)
    list += [photo(50, hour: 2.1, aesthetic: 0.9, group: "g", keeper: false),
             photo(51, hour: 2.2, aesthetic: 0.2, group: "g", keeper: true),
             photo(52, hour: 2.3, aesthetic: 0.5, group: "g", keeper: false)]
    let ids = MemoryReelPlanner.plan(candidates: list).shots.map(\.id)
    #expect(ids.contains("p51"))
    #expect(!ids.contains("p50") && !ids.contains("p52"))
  }

  @Test func groupFallsBackToBestMemberWhenKeeperIsFilteredOut() {
    let list = trip(8) + [photo(60, hour: 1, aesthetic: 0.1, group: "g", keeper: true, utility: true),
                          photo(61, hour: 1, aesthetic: 0.3, group: "g", keeper: false),
                          photo(62, hour: 1, aesthetic: 0.8, group: "g", keeper: false)]
    let ids = MemoryReelPlanner.plan(candidates: list).shots.map(\.id)
    #expect(ids.contains("p62") && !ids.contains("p61"))
  }

  @Test func targetsAboutThirtySecondsOnTheBeatGrid() {
    let plan = MemoryReelPlanner.plan(candidates: trip(200))
    #expect(abs(plan.duration - 30) <= 2)
    let beat = 0.5
    for shot in plan.shots { #expect((shot.duration / beat).truncatingRemainder(dividingBy: 1) == 0) }
    #expect(plan.shots[1].duration == 2.0)
    #expect(plan.shots.first!.duration == 3.0 && plan.shots.last!.duration == 3.0)
  }

  @Test func targetsScaleWithFifteenAndSixty() {
    #expect(abs(MemoryReelPlanner.plan(candidates: trip(200), target: .short).duration - 15) <= 2)
    #expect(abs(MemoryReelPlanner.plan(candidates: trip(200), target: .long).duration - 60) <= 2)
  }

  @Test func finalCutIsChronologicalWithContiguousTimeline() {
    let shuffled = trip(60).shuffled()
    let plan = MemoryReelPlanner.plan(candidates: shuffled)
    let times = plan.shots.map { id in shuffled.first { $0.id == id.id }!.created }
    #expect(times == times.sorted())
    var clock = 0.0
    for shot in plan.shots { #expect(shot.start == clock); clock = shot.end }
  }

  @Test func spreadsAcrossTheTripNotJustTheBestDay() {
    // Day 1 holds the best photos by far; day 4 is weak but must still appear.
    var list: [ReelCandidate] = []
    for i in 0..<40 { list.append(photo(i, hour: Double(i) * 0.1, aesthetic: 0.9)) }
    for i in 40..<80 { list.append(photo(i, hour: 72 + Double(i - 40) * 0.1, aesthetic: 0.0)) }
    let plan = MemoryReelPlanner.plan(candidates: list)
    let late = plan.shots.filter { (Int($0.id.dropFirst()) ?? 0) >= 40 }.count
    #expect(late >= plan.shots.count / 3)
  }

  @Test func bestAestheticWinsEachBucket() {
    let list = (0..<12).map { photo($0, hour: Double($0), aesthetic: $0 == 3 ? 0.99 : 0.1) }
    let ids = MemoryReelPlanner.plan(candidates: list, target: ReelTarget(seconds: 15)).shots.map(\.id)
    #expect(ids.contains("p3"))
  }

  @Test func videoClipsRunFourToEightBeatsFromTheirMiddle() {
    var list = trip(30)
    list.append(ReelCandidate(id: "v1", created: t0.addingTimeInterval(15.5 * 3600), isVideo: true, duration: 20, aesthetic: 5))
    let plan = MemoryReelPlanner.plan(candidates: list)
    let v1 = plan.shots.first { $0.id == "v1" }
    #expect(v1?.kind == .video && v1?.duration == 4.0 && v1?.sourceStart == 8.0)
  }

  @Test func shortVideoUnderFourBeatsIsDropped() {
    let list = trip(10) + [ReelCandidate(id: "v", created: t0, isVideo: true, duration: 1.4, aesthetic: 9)]
    #expect(MemoryReelPlanner.plan(candidates: list).shots.contains { $0.id == "v" } == false)
  }

  @Test func deterministicForEqualScores() {
    let list = (0..<40).map { photo($0, hour: Double($0), aesthetic: 0.1) }
    #expect(MemoryReelPlanner.plan(candidates: list) == MemoryReelPlanner.plan(candidates: list.reversed()))
  }

  @Test func missingAestheticLosesToRealScores() {
    let list = (0..<12).map { i in photo(i, hour: Double(i) * 0.01, aesthetic: i == 7 ? -0.5 : nil) }
    #expect(MemoryReelPlanner.plan(candidates: list, target: ReelTarget(seconds: 15)).shots.map(\.id).contains("p7"))
  }
}
