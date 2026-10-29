import Foundation
import Store

enum CF {
  static func asset(_ id: String, bytes: Int64 = 1_000, deleted: Bool = false, mediaType: Int = 1) -> AssetRecord {
    AssetRecord(id: id, mediaType: mediaType, subtypes: 0, created: 0, estBytes: bytes, deleted: deleted)
  }

  static func swipefile(_ id: String, _ action: SwipefileAction = .delete, name: String = "Pile",
                        album: String? = nil) -> SwipefileRecord {
    SwipefileRecord(id: id, name: name, kind: .custom, prompts: ["x"], action: action, albumName: album, created: 0)
  }

  static func decision(_ sf: String, _ asset: String, _ verdict: Verdict = .action, at: Double = 0,
                       applied: Bool = false) -> DecisionRecord {
    DecisionRecord(swipefileId: sf, assetId: asset, verdict: verdict, decidedAt: at, applied: applied)
  }

  static func key(_ sf: String, _ asset: String) -> DecisionKey { DecisionKey(swipefileId: sf, assetId: asset) }

  static func byId<T: Identifiable>(_ items: [T]) -> [T.ID: T] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
  }
}
