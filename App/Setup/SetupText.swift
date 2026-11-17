import Foundation
import Setup

/// The words for where setup stands, shared by the setup screen, Home's card and iOS's continued-task UI.
enum SetupText {
  /// The two stages the person sees.
  static let modelStage = "Getting the AI ready"
  static let libraryStage = "Reading your photos"

  /// The model stage's detail line: what it's doing right now.
  static func modelDetail(_ step: ModelStep) -> String {
    switch step {
    case .waiting(.wifi): "Waiting for Wi-Fi"
    case .waiting(.lowDataMode): "Waiting for Low Data Mode to be off"
    case .downloading(let done, let total) where total > 0:
      "Downloading, \(ByteFormat.short(done)) of \(ByteFormat.short(total))"
    case .downloading: "Downloading"
    case .installing: "Unpacking and loading"
    case .preparing(let done, let total): "Preparing for this iPhone, \(done) of \(total)"
    }
  }

  /// "12,345 of 30,000".
  static func libraryDetail(_ counts: LibraryCounts) -> String {
    "\(counts.read.formatted()) of \(counts.total.formatted())"
  }

  /// iOS's continued-task title and subtitle.
  static func backgroundTitle(for stage: SetupStage) -> (title: String, subtitle: String) {
    switch stage {
    case .unknown: ("Setting up Roll", "Starting")
    case .model(let step): (modelStage, modelDetail(step))
    case .library(let counts): (libraryStage, libraryDetail(counts))
    case .done(let counts): ("Roll is ready", "Read \(counts.total.formatted()) photos")
    }
  }
}
