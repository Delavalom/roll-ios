#if DEBUG
import CryptoKit
import Foundation
import Library
import Photos
import SwiftUI
import Synchronization
import UIKit
import UniformTypeIdentifiers
import Vision

/// DEBUG-only (`-QAFindExport`): exports what the Find accuracy eval needs from this iPhone's library
/// (docs/superpowers/plans/2026-11-15-find.md, "Data contracts") into `Documents/qa/find/`, pulled with
/// `devicectl device copy from`. The files hold identifiers, coordinates, album titles and thumbnails: they stay on the
/// phone and in the private evidence folder, never in the repo.
///
/// In this mode `RollApp` builds no `AppModel`: Roll's database and vector index are never opened, the embedding model
/// never loads, and the indexer, text pass and candidate checks never run. The library is only read (fetches and local
/// image requests with network access off). The screen stays on.
///
/// Files:
/// - `assets.jsonl`: one line per image or video (the set Roll indexes: hidden assets excluded), newest first:
///   `{"id","created","lat","lon","hacc","mediaType","subtypes","albums":[albumKey]}` (`created` in seconds since 1970;
///   `mediaType` and `subtypes` are PhotoKit's raw values, like Roll's database; nulls when absent). Written to a temp
///   file and renamed, so it exists only once complete.
/// - `albums.json`: `[{"key","title","count"}]` for user albums (regular and synced, Roll-made ones included); `key` is
///   `al` + 10 hex of the SHA-1 of the album's local identifier (stable across runs).
/// - `vision.jsonl`: per asset (images, and the poster frame of videos), Vision's `VNClassifyImageRequest` on the best
///   local image around 360 px: `{"id","labels":[["identifier",confidence]]}` (confidence >= 0.1, top 10), or
///   `{"id","missing":true}` when there is no local image. Resumable (ids already in the file are skipped), in batches
///   of `visionBatch`, paused while the thermal state is `.serious` or worse and while thumbnails are pending.
/// - `progress.json`: `{done,total,missing,phase,thermal,itemsPerMinute,updated}`, after every vision batch.
/// - `thumb-request.txt` (written by the Mac, one id per line, replaced or appended any time): checked every 5 s. Each
///   requested id not yet in `thumbs/index.jsonl` gets `thumbs/<16 hex of SHA-1(id)>.jpg` (256 px longest side, JPEG
///   0.75, local image only) and a line `{"id","file","ok"}` in `thumbs/index.jsonl`.
/// - `done.json`: counts after each phase and thumbnail batch.
enum QAFindExport {
  static let flag = "-QAFindExport"
  static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(flag) }

  static let root = URL.documentsDirectory.appending(path: "qa/find", directoryHint: .isDirectory)
  static let thumbsDir = root.appending(path: "thumbs", directoryHint: .isDirectory)
  static let visionSide = 360
  static let thumbSide = 256
  static let visionBatch = 16
  static let minConfidence: Float = 0.1
  static let maxLabels = 10
}

// MARK: - Screen

/// The whole app in export mode: a status page that keeps the screen on.
struct QAFindExportView: View {
  @State private var model = QAFindExportModel()
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Find export (QA)").font(.title2.bold())
      Text("Read-only. Roll's database is not opened.").font(.footnote).foregroundStyle(.secondary)
      Divider()
      ForEach(model.lines, id: \.self) { Text($0).font(.body.monospacedDigit()) }
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(uiColor: .systemBackground))
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      model.start()
    }
    .onChange(of: scenePhase) { _, phase in if phase == .active { UIApplication.shared.isIdleTimerDisabled = true } }
  }
}

@Observable @MainActor
final class QAFindExportModel {
  private(set) var access = "checking"
  private(set) var assets = "assets: waiting"
  private(set) var vision = "vision: waiting"
  private(set) var thumbs = "thumbs: 0"
  @ObservationIgnored private var started = false

  var lines: [String] { ["Photos: \(access)", assets, vision, thumbs] }

  func start() {
    guard !started else { return }
    started = true
    Task { await run() }
  }

  private func run() async {
    var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
    access = switch status {
    case .authorized: "full"
    case .limited: "limited"
    default: "no access (\(status.rawValue))"
    }
    guard status == .authorized || status == .limited else { return }

    let exporter = QAFindExporter()
    do { try exporter.prepare() } catch {
      assets = "assets: can't create folder (\(error.localizedDescription))"
      return
    }
    // Thumbnails are served from now on, with priority over the vision pass.
    Task.detached(priority: .userInitiated) { [weak self] in
      await exporter.serveThumbnails { done, ok in
        await MainActor.run { self?.thumbs = "thumbs: \(done) done, \(ok) ok" }
      }
    }
    assets = "assets: reading library"
    let summary = await Task.detached(priority: .userInitiated) { exporter.exportAssets() }.value
    guard let summary else { assets = "assets: write failed"; return }
    assets = "assets: \(summary.assets) (\(summary.withLocation) with location), albums: \(summary.albums)"
    await Task.detached(priority: .utility) { [weak self] in
      await exporter.runVision(ids: summary.ids) { line in
        await MainActor.run { self?.vision = line }
      }
    }.value
  }
}

#endif
