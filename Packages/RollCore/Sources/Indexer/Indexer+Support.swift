import CoreGraphics
import Embedding
import Foundation
import Library
import os
import Signals
import Store
import Synchronization

/// Thread-safe run bookkeeping that cancellation handlers can reach without hopping to the actor:
/// how many callers wait, whether the Indexer itself keeps the run alive, and its task.
final class RunControl: Sendable {
  let state = Mutex<(waiters: Int, keepAlive: Bool, cancelled: Bool, task: Task<Void, Never>?)>((0, false, false, nil))

  var isCancelled: Bool { state.withLock { $0.cancelled } }
  var keepsAlive: Bool { state.withLock { $0.keepAlive } }
  var task: Task<Void, Never>? { state.withLock { $0.task } }

  func join() { state.withLock { $0.waiters += 1 } }
  func keepAlive() { state.withLock { $0.keepAlive = true } }

  func setTask(_ task: Task<Void, Never>) {
    let cancelNow = state.withLock { s in
      s.task = task
      return s.cancelled
    }
    if cancelNow { task.cancel() }
  }

  /// One caller stopped waiting; the last one (unless kept alive) stops the run.
  func leave() {
    let task: Task<Void, Never>?? = state.withLock { s in
      s.waiters = max(0, s.waiters - 1)
      guard s.waiters == 0, !s.keepAlive, !s.cancelled else { return .none }
      s.cancelled = true
      return .some(s.task)
    }
    if case .some(let task) = task { task?.cancel() }
  }

  func stop() {
    let task = state.withLock { s in
      s.cancelled = true
      return s.task
    }
    task?.cancel()
  }
}

/// Which run a caller is waiting on; moved when an embedder swap carries callers over to the next run.
final class WaiterTicket: Sendable {
  let control: Mutex<RunControl>

  init(_ control: RunControl) { self.control = Mutex(control) }

  func move(to next: RunControl) {
    control.withLock { $0 = next }
    next.join()
  }

  func leave() { control.withLock { $0 }.leave() }
}

/// How far a write got before failing (signals 1, failed loads 2), so only the rest is re-buffered.
final class WriteStage: Sendable {
  let stage = Mutex(0)
  func reached(_ value: Int) { stage.withLock { $0 = value } }
  var value: Int { stage.withLock { $0 } }
}

extension AssetRecord {
  /// A library row for `upsertAssets`; computed columns keep their defaults (the upsert never overwrites them).
  init(_ snapshot: AssetSnapshot, estBytes: Int64) {
    self.init(id: snapshot.id, mediaType: snapshot.mediaType, subtypes: snapshot.subtypes, created: snapshot.created,
              pixelW: snapshot.pixelW, pixelH: snapshot.pixelH, duration: snapshot.duration,
              isFavorite: snapshot.isFavorite, burstId: snapshot.burstId, uti: snapshot.uti, estBytes: estBytes,
              modified: snapshot.modified, lat: snapshot.lat, lon: snapshot.lon, locationChecked: true)
  }
}

extension SignalFields {
  init(id: String, computed s: AssetSignals, cloudOnly: Bool, source: AnalysisSource, previewSide: Int?) {
    self.init(id: id, signalsDone: true, blur: s.blur.map(Double.init), aesthetic: s.aesthetic.map(Double.init),
              isUtility: s.isUtility, sensitive: s.sensitive, phash: s.phash, featurePrint: s.featurePrint,
              cloudOnly: cloudOnly, source: source, previewSide: previewSide)
  }

  /// The row's current signals with a new `cloudOnly` flag (`commitSignals` writes every signal column).
  init(keeping record: AssetRecord, cloudOnly: Bool) {
    self.init(id: record.id, signalsDone: record.signalsDone, blur: record.blur, aesthetic: record.aesthetic,
              isUtility: record.isUtility, sensitive: record.sensitive, phash: record.phash,
              featurePrint: record.featurePrint, cloudOnly: cloudOnly, source: record.source,
              previewSide: record.previewSide)
  }
}
