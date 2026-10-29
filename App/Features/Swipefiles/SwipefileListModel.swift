import Foundation
import LocalAuthentication
import Observation
import Overview
import Ranking
import Store

/// The swipefile list: presets first (in `Preset` order), then the user's own, newest last.
@Observable @MainActor
final class SwipefileListModel {
  private(set) var presets: [SwipefileRecord] = []
  private(set) var custom: [SwipefileRecord] = []
  var message: String?

  @ObservationIgnored private let app: AppModel

  init(app: AppModel) { self.app = app }

  func load() async {
    refreshLock()
    do {
      try await app.ensurePresetSwipefiles()
      let all = try await app.repositories.swipefiles().filter { !SystemSwipefile.isHidden($0) }
      let order = Dictionary(uniqueKeysWithValues: Preset.allCases.enumerated().map { ($1.rawValue, $0) })
      presets = all.filter { $0.kind == .preset }.sorted { (order[$0.preset ?? ""] ?? 99) < (order[$1.preset ?? ""] ?? 99) }
      custom = all.filter { $0.kind == .custom }
    } catch {
      message = "Your swipefiles couldn't load."
    }
  }

  func delete(_ swipefile: SwipefileRecord) async {
    do {
      try await app.repositories.deleteSwipefile(id: swipefile.id)
      await load()
      app.bumpLibrary()
    } catch {
      message = "That swipefile couldn't be deleted."
    }
  }

  static func isLocked(_ swipefile: SwipefileRecord) -> Bool { Preset(swipefile: swipefile) == .privateStuff }

  /// Shown on the Private pile when the iPhone has no passcode, so there is nothing to lock it with.
  static let noPasscodeNote = "Set a passcode in Settings to lock this pile."

  /// Whether the iPhone can check its owner (Face ID, Touch ID or the passcode). False only when no passcode is set;
  /// any other answer (biometry locked out, say) still asks, and `unlock()` decides.
  static var canLock: Bool {
    var error: NSError?
    if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) { return true }
    return (error as? LAError)?.code != .passcodeNotSet
  }

  /// Read when the list loads (and on return to the app): a passcode can be set or removed in Settings meanwhile.
  private(set) var deviceCanLock = true

  func refreshLock() { deviceCanLock = Self.canLock }

  /// Locked rows ask before opening; on an iPhone with no passcode the Private pile opens without a check and
  /// shows `noPasscodeNote` instead.
  func needsUnlock(_ swipefile: SwipefileRecord) -> Bool { Self.isLocked(swipefile) && deviceCanLock }

  /// Face ID / passcode before the Private pile opens. If the passcode was removed since `refreshLock()`, there is
  /// nothing to check against, so it opens (there's no lock to bypass) and the note shows.
  func unlock() async -> Bool {
    let context = LAContext()
    do {
      return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Open your Private swipefile")
    } catch let error as LAError where error.code == .passcodeNotSet {
      deviceCanLock = false
      return true
    } catch {
      return false
    }
  }

  /// One line under the name: the description, or the preset's purpose.
  func subtitle(_ swipefile: SwipefileRecord) -> String {
    if Self.isLocked(swipefile), !deviceCanLock { return Self.noPasscodeNote }
    return Self.subtitle(swipefile)
  }

  static func subtitle(_ swipefile: SwipefileRecord) -> String {
    switch Preset(swipefile: swipefile) {
    case .screenshots: "Screenshots, ranked by what's in them"
    case .blurry: "Out of focus photos"
    case .memes: "Memes and reaction images"
    case .receipts: "Receipts, documents and whiteboards"
    case .privateStuff: "Locked with Face ID"
    case .bigVideos: "The largest videos, to squish"
    case nil: swipefile.prompts.first ?? "\(swipefile.examples.count) examples"
    }
  }
}
