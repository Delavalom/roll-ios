import Foundation
import Ranking
import Store
import Testing

private func asset(_ id: String = "a", mediaType: Int = Preset.imageMediaType, subtypes: Int = 0, bytes: Int64 = 1_000,
                   blur: Double? = nil, aesthetic: Double? = nil, utility: Bool? = nil, sensitive: Bool? = nil) -> AssetRecord {
  AssetRecord(id: id, mediaType: mediaType, subtypes: subtypes, estBytes: bytes, blur: blur, aesthetic: aesthetic,
              isUtility: utility, sensitive: sensitive, previewSide: 300)
}

private func custom(prompts: [String] = ["x"], classifier: Data? = nil) -> SwipefileRecord {
  SwipefileRecord(id: "c", name: "Custom", kind: .custom, prompts: prompts, action: .delete, classifier: classifier, created: 0)
}

private func close(_ a: Float, _ b: Float) -> Bool { abs(a - b) < 1e-6 }

struct PresetTests {
  @Test func promptsMatchTheSpecTable() {
    #expect(Preset.memes.prompts == ["a meme with caption text", "a reaction image", "an internet meme"])
    #expect(Preset.receipts.prompts == ["a photo of a receipt", "a photo of a document", "a whiteboard"])
    #expect(Preset.privateStuff.prompts == ["a nude photo", "an intimate private photo", "a photo in underwear"])
    #expect(Preset.screenshots.prompts == ["a screenshot of a phone screen"])
    #expect(Preset.blurry.prompts == ["a blurry out of focus photo"])
    #expect(Preset.bigVideos.prompts.isEmpty)
    #expect(Set(Preset.allCases.map(\.name)).count == Preset.allCases.count)
  }

  @Test func candidateFilters() {
    #expect(Preset.screenshots.candidateFilter(asset(subtypes: Preset.screenshotSubtype | 1)))
    #expect(!Preset.screenshots.candidateFilter(asset(subtypes: 1)))

    #expect(AssetRecord.blurryBelow == 25)  // the one canonical threshold lives in Store
    #expect(Preset.blurry.candidateFilter(asset(blur: 10)))
    #expect(Preset.blurry.candidateFilter(asset(blur: AssetRecord.blurryBelow.nextDown)))
    #expect(!Preset.blurry.candidateFilter(asset(blur: AssetRecord.blurryBelow)))
    #expect(!Preset.blurry.candidateFilter(asset(blur: 80, aesthetic: -0.5)), "a low aesthetic score isn't blurry")
    #expect(!Preset.blurry.candidateFilter(asset(blur: 80, aesthetic: -0.2)))
    #expect(!Preset.blurry.candidateFilter(asset()))  // no signals yet
    #expect(!Preset.blurry.candidateFilter(asset(mediaType: Preset.videoMediaType, blur: 3)), "photos only")
    #expect(Preset.blurry.candidateFilter(asset(blur: 3, aesthetic: 0.9)))

    #expect(Preset.memes.candidateFilter(asset()))
    #expect(!Preset.memes.candidateFilter(asset(mediaType: Preset.videoMediaType)))

    #expect(Preset.receipts.candidateFilter(asset(utility: false)))
    #expect(Preset.privateStuff.candidateFilter(asset(mediaType: Preset.videoMediaType)))

    #expect(Preset.bigVideos.candidateFilter(asset(mediaType: Preset.videoMediaType, bytes: 50_000_001)))
    #expect(!Preset.bigVideos.candidateFilter(asset(mediaType: Preset.videoMediaType, bytes: 50_000_000)))
    #expect(!Preset.bigVideos.candidateFilter(asset(mediaType: Preset.imageMediaType, bytes: 900_000_000)))
  }

  /// The SQL filters are exactly the spec's: checked field by field.
  @Test func presetFiltersAreTheSpecFilters() {
    #expect(Preset.screenshots.filter == CandidateFilter(subtypesAny: Preset.screenshotSubtype))
    #expect(Preset.memes.filter == CandidateFilter(mediaType: Preset.imageMediaType))
    #expect(Preset.bigVideos.filter == CandidateFilter(mediaType: Preset.videoMediaType, bytesAbove: 50_000_000))
    #expect(Preset.blurry.filter == CandidateFilter(mediaType: Preset.imageMediaType, blurBelow: AssetRecord.blurryBelow))
    #expect(Preset.receipts.filter == .none && Preset.privateStuff.filter == .none)
  }

  @Test func signalBoosts() {
    #expect(Preset.screenshots.signalBoost(asset(subtypes: Preset.screenshotSubtype)) == 1)
    #expect(Preset.screenshots.signalBoost(asset()) == 0)
    #expect(Preset.blurry.signalBoost(asset(blur: 5)) == 0.8)
    #expect(Preset.blurry.signalBoost(asset(blur: 0)) == 1)
    #expect(Preset.blurry.signalBoost(asset(blur: 50)) == 0)
    #expect(Preset.blurry.signalBoost(asset(blur: -3)) == 1)
    #expect(Preset.blurry.signalBoost(asset()) == 0)
    #expect(Preset.receipts.signalBoost(asset(utility: true)) == 0.3)
    #expect(Preset.receipts.signalBoost(asset(utility: false)) == 0)
    #expect(Preset.privateStuff.signalBoost(asset(sensitive: true)) == 0.5)
    #expect(Preset.privateStuff.signalBoost(asset(sensitive: nil)) == 0)
    #expect(Preset.memes.signalBoost(asset(utility: true, sensitive: true)) == 0)
  }

  @Test func defaultActionsAndRecords() {
    for preset in Preset.allCases {
      #expect(preset.defaultAction == (preset == .bigVideos ? .squish : .delete))
      let record = preset.swipefile(created: 42)
      #expect(record.kind == .preset && record.preset == preset.rawValue && record.prompts == preset.prompts)
      #expect(record.action == preset.defaultAction && record.created == 42 && record.name == preset.name)
      #expect(Preset(swipefile: record) == preset)
    }
    #expect(Preset(swipefile: custom()) == nil)
  }
}

struct ScorerTests {
  @Test func cosineIgnoresMagnitude() {
    #expect(close(Scorer.cosine([3, 4, 0], [2, 0, 0]), 0.6))
    #expect(Scorer.cosine([0, 0, 0], [1, 0, 0]) == 0)
  }

  @Test func untrainedTakesTheBestPrompt() {
    let s = Scorer.score(vector: [3, 4, 0], swipefile: custom(), promptVectors: [[2, 0, 0], [0, 1, 0]],
                         exampleVectors: [], record: asset())
    #expect(close(s, 0.8))
  }

  @Test func untrainedAddsHalfTheMeanExampleCosine() {
    // cos to examples: 0.6 and 0 -> mean 0.3 -> +0.15
    let s = Scorer.score(vector: [3, 4, 0], swipefile: custom(), promptVectors: [[0, 1, 0]],
                         exampleVectors: [[1, 0, 0], [0, 0, 5]], record: asset())
    #expect(close(s, 0.95))
  }

  @Test func untrainedAddsThePresetBoost() {
    let receipts = Preset.receipts.swipefile(created: 0)
    let s = Scorer.score(vector: [3, 4, 0], swipefile: receipts, promptVectors: [[0, 1, 0]], exampleVectors: [],
                         record: asset(utility: true))
    #expect(close(s, 1.1))
  }

  @Test func noPromptsOrExamplesLeavesOnlyTheBoost() {
    let s = Scorer.score(vector: [1, 0, 0], swipefile: Preset.privateStuff.swipefile(created: 0), promptVectors: [],
                         exampleVectors: [], record: asset(sensitive: true))
    #expect(s == 0.5)
  }

  @Test func trainedUsesTheClassifierProbabilityPlusBoost() {
    let blob = LogisticClassifier(w: [1, 0, 0], b: -3).blob
    var sf = Preset.receipts.swipefile(created: 0)
    sf.classifier = blob
    // logit = 3 - 3 = 0 -> 0.5, plus 0.3; prompts and examples are ignored once trained
    let s = Scorer.score(vector: [3, 4, 0], swipefile: sf, promptVectors: [[0, 1, 0]], exampleVectors: [[0, 1, 0]],
                         record: asset(utility: true))
    #expect(close(s, 0.8))
  }

  @Test func classifierOfTheWrongWidthIsIgnored() {
    let s = Scorer.score(vector: [3, 4, 0], swipefile: custom(classifier: LogisticClassifier(w: [1, 0], b: 9).blob),
                         promptVectors: [[0, 1, 0]], exampleVectors: [], record: asset())
    #expect(close(s, 0.8))
  }

  @Test func combineMatchesTheSpecFormula() {
    #expect(close(Scorer.combine(promptSimilarities: [0.1, 0.4], meanExampleSimilarity: 0.2, boost: 0.3), 0.8))
    #expect(Scorer.combine(promptSimilarities: [], meanExampleSimilarity: nil, boost: 0) == 0)
  }
}
