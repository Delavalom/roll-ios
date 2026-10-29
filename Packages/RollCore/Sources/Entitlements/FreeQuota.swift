import Store

public enum QuotaError: Error, Equatable {
  /// The request would go past the free limit; nothing was consumed.
  case exceeded
}

/// Applying changes (deletes, album moves, squishes) is free for the first `limit` items.
///
/// The count lives in the Store's SQLite `quota` table, so deleting and reinstalling the app
/// resets it (accepted; see ADR-0003). This type only holds the policy; the atomic counter is
/// `Repositories.consumeCounter`.
public struct FreeQuota: Sendable {
  public static let limit = 50
  private static let key = "freeUsed"

  private let repositories: Repositories

  public init(_ database: AppDatabase) {
    self.repositories = Repositories(database)
  }

  public func remaining() async throws -> Int {
    max(0, Self.limit - (try await repositories.counter(key: Self.key)))
  }

  /// Spends `n` items. Throws `QuotaError.exceeded` and spends nothing if fewer than `n` remain.
  /// Zero or negative `n` does nothing. Callers spend only after the change itself succeeded.
  public func consume(_ n: Int) async throws {
    do {
      _ = try await repositories.consumeCounter(key: Self.key, n: n, limit: Self.limit)
    } catch CounterError.limitExceeded {
      throw QuotaError.exceeded
    }
  }

  /// Spends `min(n, remaining)` atomically and returns how many were spent. For a change that has already
  /// happened: if another commit spent the quota in the meantime, the remainder is still used up, so the
  /// next plan shows it as used. Zero or negative `n` spends nothing.
  @discardableResult
  public func consumeUpTo(_ n: Int) async throws -> Int {
    try await repositories.consumeCounterUpTo(key: Self.key, n: n, limit: Self.limit)
  }
}
