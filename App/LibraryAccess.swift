import Library
import Photos

/// Photos permission, as the app needs it.
enum AccessState: Sendable, Equatable {
  case notDetermined
  case full
  /// Limited access: Roll works on the photos the user selected.
  case limited
  case denied

  var canRead: Bool { self == .full || self == .limited }
}

protocol LibraryAccess: Sendable {
  func current() -> AccessState
  func request() async -> AccessState
}

struct PhotoKitAccess: LibraryAccess {
  func current() -> AccessState { Self.map(PhotoLibrary().currentAuthorization()) }
  func request() async -> AccessState { Self.map(await PhotoLibrary().authorization()) }

  private static func map(_ status: PHAuthorizationStatus) -> AccessState {
    switch status {
    case .authorized: .full
    case .limited: .limited
    case .notDetermined: .notDetermined
    case .denied, .restricted: .denied
    @unknown default: .denied
    }
  }
}

#if DEBUG
/// A fixed answer, for previews.
struct FixedAccess: LibraryAccess {
  var state: AccessState
  func current() -> AccessState { state }
  func request() async -> AccessState { state == .notDetermined ? .full : state }
}
#endif
