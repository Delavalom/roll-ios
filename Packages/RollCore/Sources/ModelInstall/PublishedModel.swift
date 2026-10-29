import Foundation

/// A published revision of the EmbeddingGemma 2 Core ML model on the Hugging Face Hub.
///
/// The repo holds one package per image budget (embeddinggemma-coreml ADR-0010): `b70/` and `b280/`. A phone
/// downloads only its own budget's: one Apple Archive (LZFSE) plus a small manifest next to it, both at
/// `https://huggingface.co/<repo>/resolve/<revision>/b<budget>/<path>`: `manifest.json` (`ModelManifest`: the
/// archive's name, size and SHA-256) and the archive, which holds `EmbeddingGemma2.mlpackage/**` and
/// `tokenizer/{tokenizer.json,tokenizer_config.json}` at its root. Nothing else in the repo is fetched.
public struct PublishedModel: Sendable, Equatable {
  /// `owner/name` on the Hub.
  public let repo: String
  /// The 40-character commit SHA of the upload (never a branch: what the manifest says only holds for a fixed commit).
  public let revision: String
  /// The image budget (70 or 280) whose package this is. A phone's budget comes from its chip and never changes, so
  /// the install folders are keyed by revision alone.
  public let budget: Int
  /// Lowercase hex SHA-256 of that commit's `b<budget>/manifest.json`. Required (`isPublished` is false without
  /// it): the manifest carries the archive's hash, so this pin is what ties the downloaded model to the build, and a
  /// rewritten or compromised Hub file is rejected.
  public let manifestSHA256: String?

  public init(repo: String, revision: String, budget: Int = 70, manifestSHA256: String? = nil) {
    self.repo = repo
    self.revision = revision
    self.budget = budget
    self.manifestSHA256 = manifestSHA256
  }

  /// **The published model this build uses**: the Hugging Face repo, the commit SHA of the upload and the SHA-256 of
  /// each budget's `manifest.json` (`b70/`, `b280/`), as embeddinggemma-coreml's s7 reports them
  /// (`artifacts/s7_publish/report.json`, `details`; its `DefaultModel.swift` holds the same three values). Without
  /// all three `isPublished` is false and Home says the on-device AI isn't ready. A new value is a new model: Roll
  /// downloads it, switches over on a later launch (re-embedding the library) and then deletes the old one.
  public static let publishedRepo = "delavalom/embeddinggemma-2-coreml"
  public static let publishedRevision = "8036f0bbba34dad5093108601ac6d060c63bbe76"  // v1.0.0, 2026-10-29
  public static let publishedManifestSHA256: [Int: String] = [
    70: "1edc9907eb54de411e6df7ccfbc610224884ff4229b90e9732671e034f011b4f",
    280: "24f100644516fd6daba6fc57665b503baa59ac5e656896177d9e71c90a612cb5",
  ]

  /// This build's published model for image `budget` (70 or 280).
  public static func current(budget: Int) -> PublishedModel {
    PublishedModel(repo: publishedRepo, revision: publishedRevision, budget: budget,
                   manifestSHA256: publishedManifestSHA256[budget])
  }

  /// True once the repo, the commit and the manifest hash are all set and well formed; a missing hash is not
  /// published. The placeholder never is, so nothing is downloaded before then.
  public var isPublished: Bool {
    [70, 280].contains(budget)
      && repo.wholeMatch(of: /[A-Za-z0-9_.\-]+\/[A-Za-z0-9_.\-]+/) != nil
      && revision.wholeMatch(of: /[0-9a-f]{40}/) != nil
      && manifestSHA256?.wholeMatch(of: /[0-9a-f]{64}/) != nil
  }

  /// Where this budget's files of the revision are.
  public var baseURL: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/b\(budget)/")! }

  public func url(for path: String) -> URL { baseURL.appending(path: path) }

  /// The repo's folder in the install root (`owner--name`); the revision's folder is inside it.
  var repoFolderName: String { repo.replacingOccurrences(of: "/", with: "--") }
}
