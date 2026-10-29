# ADR-0003: Free quota lives in SQLite

**Status:** accepted, 2026-10-22

## Context

Applying changes (deletes, album moves, squishes) is free for the first 50 items, then needs Pro. The count has to survive relaunches. Options: SQLite (the app's own database), Keychain (survives reinstall), or RevenueCat customer attributes (needs the network).

## Decision

The counter is a row in the Store's `quota` table, spent through `Repositories.consumeCounter` (one write transaction, overflow-safe). `FreeQuota` only holds the policy. Quota is spent after the change has actually succeeded.

Deleting and reinstalling the app resets the 50 free items. We accept that: the free items cost us nothing, abusing it means re-scanning a whole library each time, and Keychain or server-side tracking would add complexity and privacy surface that doesn't fit "nothing leaves your phone".

## Consequences

No network dependency and nothing to explain in the privacy manifest. If abuse ever matters, move the counter to Keychain behind the same `Repositories` call; callers don't change.
