#if DEBUG
import CoreGraphics
import Embedding
import Foundation
import Indexer
import Library
import ModelInstall
import Signals
import Store
import SwiftUI

/// Synthetic library for SwiftUI previews: an in-memory Store seeded with records, `StubEmbedder` vectors in a
/// temporary index, generated thumbnails and no PhotoKit, RevenueCat or network.
enum PreviewData {
  enum Kind: String, CaseIterable {
    case shot, blur, video, dup, similar, meme, receipt, photo

    /// Words whose stub query vectors stand in for the image embedding (StubEmbedder maps shared words close).
    var words: String {
      switch self {
      case .shot: "screenshot phone screen"
      case .blur: "blurry out of focus photo"
      case .video: "video clip"
      case .dup, .similar: "beach sunset"
      case .meme: "meme caption text reaction internet"
      case .receipt: "receipt document whiteboard"
      case .photo: "family dinner"
      }
    }

    var color: (CGFloat, CGFloat, CGFloat) {
      switch self {
      case .shot: (0.35, 0.45, 0.85)
      case .blur: (0.6, 0.6, 0.65)
      case .video: (0.85, 0.35, 0.35)
      case .dup: (0.95, 0.6, 0.3)
      case .similar: (0.9, 0.75, 0.35)
      case .meme: (0.55, 0.8, 0.4)
      case .receipt: (0.92, 0.92, 0.88)
      case .photo: (0.4, 0.7, 0.75)
      }
    }
  }

  static let now = Date(timeIntervalSince1970: 1_792_000_000).timeIntervalSince1970

  static func kind(of id: String) -> Kind { Kind(rawValue: String(id.prefix { $0 != "-" })) ?? .photo }

  /// About 60 assets: screenshots, blurry shots, big videos, an exact-duplicate trio, a similar-shot trio,
  /// memes, receipts and ordinary photos.
  static let records: [AssetRecord] = {
    var out: [AssetRecord] = []
    var t = now
    func add(_ kind: Kind, _ i: Int, media: Int = MediaKind.image, subtypes: Int = 0, bytes: Int64 = 2_400_000,
             blur: Double = 180, aesthetic: Double = 0.4, phash: UInt64? = nil, print: [Float]? = nil,
             duration: Double? = nil, step: Double = 900) {
      t -= step
      out.append(AssetRecord(
        id: "\(kind.rawValue)-\(i)", mediaType: media, subtypes: subtypes, created: t, pixelW: 4032, pixelH: 3024,
        duration: duration, uti: "public.heic", estBytes: bytes, embedded: true, signalsDone: true, blur: blur,
        aesthetic: aesthetic, isUtility: kind == .receipt, sensitive: nil,
        phash: phash ?? UInt64(truncatingIfNeeded: (kind.rawValue + "\(i)").hashValue) | 0x0F0F_0000_0000_0F0F,
        featurePrint: FeaturePrints.encode(values: print ?? [Float(i), Float(kind.rawValue.count), 0, 1].map { $0 * 3 })))
    }
    for i in 0..<12 { add(.shot, i, subtypes: MediaSubtype.screenshot, bytes: 1_300_000 + Int64(i) * 40_000, aesthetic: -0.1) }
    for i in 0..<6 { add(.blur, i, blur: 6 + Double(i) * 2, aesthetic: -0.5) }
    for i in 0..<4 {
      add(.video, i, media: MediaKind.video, bytes: 180_000_000 - Int64(i) * 30_000_000, duration: 95 - Double(i) * 10)
    }
    let dupHash: UInt64 = 0x5A5A_F0F0_3C3C_A5A5
    for i in 0..<3 { add(.dup, i, bytes: 3_100_000, aesthetic: 0.2 + Double(i) * 0.1, phash: dupHash, step: 20) }
    for i in 0..<3 {
      add(.similar, i, bytes: 2_900_000, aesthetic: 0.5 - Double(i) * 0.1, phash: 0x1234_5678_9ABC_DEF0 &* UInt64(i + 3),
          print: [1, 0.1 * Float(i), 0, 0], step: 15)
    }
    for i in 0..<8 { add(.meme, i, bytes: 400_000) }
    for i in 0..<5 { add(.receipt, i, bytes: 1_800_000) }
    for i in 0..<14 { add(.photo, i) }
    return out
  }()

  /// An AppModel over the synthetic library. `modelReady` attaches `StubEmbedder`; otherwise the model is
  /// "not ready" and only signal-based features work.
  @MainActor
  static func appModel(onboarded: Bool = true, modelReady: Bool = true, access: AccessState = .full) async throws
    -> AppModel {
    let database = try AppDatabase.inMemory()
    let repositories = Repositories(database)
    try await repositories.upsertAssets(records)
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("roll-preview-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    let embedder = StubEmbedder()
    let vectors = try await VectorStore(url: try VectorStore.defaultURL(in: base), dimensions: embedder.dimensions,
                                        revision: embedder.revision, database: database)
    var batch: [(id: String, vector: [Float])] = []
    for record in records {
      batch.append((record.id, try await embedder.embed(query: kind(of: record.id).words + " \(record.id)")))
    }
    try await vectors.upsert(batch)
    try await vectors.save()
    try await repositories.markEmbedded(ids: records.map(\.id))

    let defaults = UserDefaults(suiteName: "roll-preview-\(UUID().uuidString)")!
    defaults.set(onboarded, forKey: AppModel.onboardingKey)
    let model = try AppModel(environment: AppEnvironment(
      database: database, supportDirectory: base, library: PreviewLibrary(), access: FixedAccess(state: access),
      loader: modelReady ? StubLoader() : FailingLoader(), thumbnails: PreviewThumbnails(), defaults: defaults,
      isLive: false))
    model.start()
    return model
  }
}

/// The model "isn't published yet".
private struct FailingLoader: EmbedderLoader {
  func load(allowCellular: Bool, report: @escaping @Sendable (InstallStep) -> Void) async throws -> any Embedder {
    throw ModelInstallError.notPublished
  }
}

/// A library that reports the synthetic records (so an accidental sync deletes nothing) and generated images.
struct PreviewLibrary: LibrarySource {
  func fetchAll() async -> [AssetSnapshot] { PreviewData.records.map(Self.snapshot) }
  func snapshots(ids: [String]) async -> [AssetSnapshot] {
    let wanted = Set(ids)
    return PreviewData.records.filter { wanted.contains($0.id) }.map(Self.snapshot)
  }
  func utis(for ids: [String]) async -> [String: String] { [:] }
  func thumbnails(ids: [String], side: Int, allowNetwork: Bool) async -> [String: ThumbnailResult] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, PreviewThumbnails.make($0, side: side).map(ThumbnailResult.image) ?? .failed) })
  }
  func videoFrame(id: String, at fraction: Double, side: Int, allowNetwork: Bool) async -> ThumbnailResult {
    PreviewThumbnails.make(id, side: side).map(ThumbnailResult.image) ?? .failed
  }

  private static func snapshot(_ r: AssetRecord) -> AssetSnapshot {
    AssetSnapshot(id: r.id, mediaType: r.mediaType, subtypes: r.subtypes, created: r.created, pixelW: r.pixelW ?? 0,
                  pixelH: r.pixelH ?? 0, duration: r.duration ?? 0, isFavorite: r.isFavorite, burstId: r.burstId)
  }
}

/// Flat colored squares with a lighter band, tinted by the asset's kind.
struct PreviewThumbnails: ThumbnailProvider {
  func image(for id: String, side: Int) async -> CGImage? { Self.make(id, side: min(side, 120)) }

  static func make(_ id: String, side: Int) -> CGImage? {
    let (r, g, b) = PreviewData.kind(of: id).color
    let shade = CGFloat(abs(id.hashValue % 20)) / 100
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(red: r - shade, green: g - shade, blue: b - shade, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.25)
    ctx.fill(CGRect(x: 0, y: side / 3, width: side, height: side / 6))
    return ctx.makeImage()
  }
}

/// Builds the preview AppModel, then shows `content` with it in the environment.
struct PreviewHost<Content: View>: View {
  var onboarded = true
  var modelReady = true
  @ViewBuilder var content: () -> Content
  @State private var model: AppModel?

  var body: some View {
    if let model {
      content()
        .environment(model)
        .environment(\.thumbnails, model.thumbnails)
    } else {
      ProgressView()
        .task { model = try? await PreviewData.appModel(onboarded: onboarded, modelReady: modelReady) }
    }
  }
}
#endif
