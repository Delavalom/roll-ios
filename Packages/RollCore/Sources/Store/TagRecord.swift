import Foundation

/// One scene label of a photo (Vision `VNClassifyImageRequest` identifier and confidence 0…1).
public struct TagLabel: Sendable, Equatable, Hashable {
  public var label: String
  public var confidence: Double

  public init(label: String, confidence: Double) {
    self.label = label
    self.confidence = confidence
  }
}

/// What the tag pass read for one photo, for `Repositories.commitTags`. `side` is the long side in pixels of the image
/// classified; nil means no local image could be loaded, so `labels` is empty and the photo is recorded "unread" (a pass
/// with `retryUnread` tries it again).
public struct TagFields: Sendable, Equatable {
  public var id: String
  public var labels: [TagLabel]
  /// The classifier and image size (`TagIndexer.revision`). Photos read at another revision are read again.
  public var revision: String
  public var side: Int?

  public init(id: String, labels: [TagLabel], revision: String, side: Int?) {
    self.id = id; self.labels = labels; self.revision = revision; self.side = side
  }
}
