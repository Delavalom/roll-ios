import Foundation

/// Downloads one file. `BackgroundTransport` in the app; fakes in tests (no network).
public protocol ModelTransport: Sendable {
  /// Downloads `url` to `destination` (replacing it), resuming an earlier interrupted attempt where it can.
  /// `allowCellular` false means `DownloadPolicy`'s default: the download waits for Wi-Fi without Low Data Mode. `progress` gets the bytes
  /// received so far for this file, on an arbitrary thread. Cancelling the calling task stops the download.
  func download(_ url: URL, to destination: URL, allowCellular: Bool,
                progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// The current network path, as `NWPathMonitor` reports it.
public struct NetworkPath: Sendable, Equatable {
  public var isSatisfied: Bool
  /// Wi-Fi or wired.
  public var isWiFi: Bool
  /// Cellular or a personal hotspot.
  public var isExpensive: Bool
  /// Low Data Mode.
  public var isConstrained: Bool

  public init(isSatisfied: Bool, isWiFi: Bool, isExpensive: Bool, isConstrained: Bool) {
    self.isSatisfied = isSatisfied
    self.isWiFi = isWiFi
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
  }

  public static let wifi = NetworkPath(isSatisfied: true, isWiFi: true, isExpensive: false, isConstrained: false)
  public static let cellular = NetworkPath(isSatisfied: true, isWiFi: false, isExpensive: true, isConstrained: false)
  public static let offline = NetworkPath(isSatisfied: false, isWiFi: false, isExpensive: false, isConstrained: false)
}

/// Why the model download is waiting.
public enum NetworkWait: Sendable, Equatable {
  /// Not on Wi-Fi (offline, cellular, or a personal hotspot).
  case wifi
  /// On Wi-Fi, but Low Data Mode is on.
  case lowDataMode
}

/// When the model may download. By default only on Wi-Fi that is neither expensive nor in Low Data Mode (Low Data
/// Mode is treated like cellular); the background session enforces the same rule (`BackgroundTransport`), so a
/// download also pauses when the path changes. Allowing mobile data, which only the person can do, lifts both.
/// Deliberately stricter than the app's `WiFi.isAvailable()`, which lets small, user-initiated iCloud views through in
/// Low Data Mode.
public enum DownloadPolicy {
  /// nil if the download may run on `path`.
  public static func wait(on path: NetworkPath, allowCellular: Bool) -> NetworkWait? {
    if allowCellular { return nil }
    guard path.isSatisfied, path.isWiFi, !path.isExpensive else { return .wifi }
    return path.isConstrained ? .lowDataMode : nil
  }
}

/// What getting the model needs from the device, injectable for tests.
public struct InstallConditions: Sendable {
  /// The current network path (the app reads it with `NWPathMonitor`).
  public var network: @Sendable () async -> NetworkPath
  /// Free bytes on the volume of a folder; nil if unknown (then the check is skipped).
  public var availableCapacity: @Sendable (URL) -> Int64?

  public init(network: @escaping @Sendable () async -> NetworkPath,
              availableCapacity: @escaping @Sendable (URL) -> Int64? = InstallConditions.volumeCapacity) {
    self.network = network
    self.availableCapacity = availableCapacity
  }

  /// Free space for "important" data (what iOS would free up for it), else plain free space.
  public static let volumeCapacity: @Sendable (URL) -> Int64? = { url in
    let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
    let v = try? url.resourceValues(forKeys: keys)
    return v?.volumeAvailableCapacityForImportantUsage ?? v?.volumeAvailableCapacity.map(Int64.init)
  }
}

/// Free space needed before the download starts: the archive (what is still missing of it) plus twice its extracted
/// size, about 2.5 times the archive. The extracted size is the manifest's `unpacked_size` when it has one, else
/// `estimatedRatio` of the archive. The real peak is the larger of two moments, and this covers both:
/// - extracting: the archive and the extracted files (archive + 1x);
/// - compiling: the archive is deleted once the extracted folder is in place, the package moves the files into its
///   store (a rename, nothing copied) and compiles the model, about the size of the extracted package (2x). Then
///   the extracted package is deleted, so about 1x stays.
/// Asking for the sum keeps it simple and over-asks by at most one extracted size (the smaller of it and the archive).
public enum InstallSpace {
  public static let estimatedRatio = 0.75

  public static func required(_ manifest: ModelManifest, alreadyDownloaded: Int64) -> Int64 {
    let unpacked = manifest.unpackedSize ?? Int64((Double(manifest.size) * estimatedRatio).rounded(.up))
    return max(0, manifest.size - alreadyDownloaded) + 2 * unpacked
  }

  /// Throws `.insufficientSpace` when `available` is known and short.
  public static func check(_ manifest: ModelManifest, alreadyDownloaded: Int64, available: Int64?) throws {
    let need = required(manifest, alreadyDownloaded: alreadyDownloaded)
    if let available, available < need { throw ModelInstallError.insufficientSpace(required: need, available: available) }
  }
}

public enum ModelInstallError: Error, Equatable, Sendable {
  /// `PublishedModel.current(budget:)` is still the placeholder.
  case notPublished
  /// The downloaded `manifest.json` isn't the pinned one.
  case manifestMismatch
  case invalidManifest(String)
  /// The downloaded archive's size or SHA-256 differs from the manifest; it was deleted.
  case checksumMismatch(file: String)
  /// The archive couldn't be extracted, or lacks a file the package needs.
  case badArchive(String)
  case insufficientSpace(required: Int64, available: Int64)
  /// The network or the server failed (the description of the underlying error).
  case downloadFailed(String)
  /// Reading or writing Roll's model folder failed.
  case storageFailed(String)
}

extension ModelInstallError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .notPublished: "The on-device model isn't published yet."
    case .manifestMismatch: "The model's manifest doesn't match the expected one."
    case .invalidManifest(let why): "The model's manifest is invalid: \(why)."
    case .checksumMismatch(let file): "The downloaded file \(file) doesn't match its checksum."
    case .badArchive(let why): "The model archive couldn't be unpacked: \(why)"
    case .insufficientSpace(let r, let a): "Not enough free space: \(r) bytes needed, \(a) available."
    case .downloadFailed(let why): "Downloading the model failed: \(why)"
    case .storageFailed(let why): "Storing the model failed: \(why)"
    }
  }
}
