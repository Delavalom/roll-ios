import Foundation
import CoreGraphics
import Testing
@testable import Library

struct OneShotTests {
  @Test func firstResolveWinsAndLateCallbacksAreIgnored() async {
    let shot = OneShot<Int>(cancelledValue: -1)
    let value = await shot.run { shot in
      shot.resolve(1)
      shot.resolve(2)  // a handler firing twice must not resume twice
    }
    #expect(value == 1)
    shot.resolve(3)
    #expect(shot.isResolved)
  }

  @Test func resolvesWhenTheHandlerFiresLater() async {
    let shot = OneShot<Int>(cancelledValue: -1)
    let value = await shot.run { shot in
      Task.detached { try? await Task.sleep(for: .milliseconds(20)); shot.resolve(7) }
    }
    #expect(value == 7)
  }

  @Test func cancellingTheTaskCancelsTheRequestAndResolvesWithTheCancelledValue() async {
    let cancelled = Counter()
    let started = AsyncStream<Void>.makeStream()
    let shot = OneShot<Int>(cancelledValue: -1)
    let task = Task {
      await shot.run { shot in
        shot.setCancelAction { cancelled.increment() }
        started.continuation.yield()  // the "request" never answers
      }
    }
    for await _ in started.stream { break }
    task.cancel()
    #expect(await task.value == -1)
    #expect(cancelled.value == 1)
    shot.resolve(5)  // late handler call after cancellation: ignored
  }

  @Test func cancelBeforeTheCancelActionIsRegisteredStillRunsIt() {
    let cancelled = Counter()
    let shot = OneShot<Int>(cancelledValue: -1)
    shot.cancel()
    shot.setCancelAction { cancelled.increment() }  // e.g. the request id arrived after onCancel
    #expect(cancelled.value == 1)
    #expect(shot.isResolved)
  }

  @Test func alreadyCancelledTaskNeverStartsTheRequest() async {
    let started = Counter()
    let task = Task { () async -> Int in
      withUnsafeCurrentTask { $0?.cancel() }
      let shot = OneShot<Int>(cancelledValue: -1)
      return await shot.run { _ in started.increment() }
    }
    #expect(await task.value == -1)
    #expect(started.value == 0)
  }
}

struct ThumbnailClassificationTests {
  let image: CGImage = {
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    return context.makeImage()!
  }()

  @Test func anImageIsAlwaysAnImage() {
    #expect(ThumbnailResult.classify(image: image, isInCloud: true, hasError: true, allowNetwork: false).image != nil)
  }

  @Test func cloudOnlyWithoutNetworkIsInCloudEvenWithAnError() {
    guard case .inCloud = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, allowNetwork: false)
    else { Issue.record("expected inCloud"); return }
    guard case .inCloud = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: false, allowNetwork: true)
    else { Issue.record("expected inCloud"); return }
  }

  @Test func downloadErrorWithNetworkAllowedIsFailed() {
    guard case .failed = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, allowNetwork: true)
    else { Issue.record("expected failed"); return }
  }

  @Test func cancelledWinsOverEverythingExceptAnImage() {
    guard case .cancelled = ThumbnailResult.classify(image: nil, isInCloud: true, hasError: true, cancelled: true, allowNetwork: false)
    else { Issue.record("expected cancelled"); return }
    #expect(ThumbnailResult.classify(image: image, isInCloud: false, hasError: false, cancelled: true, allowNetwork: false).image != nil)
  }

  @Test func noImageAndNoCloudFlagIsFailed() {
    guard case .failed = ThumbnailResult.classify(image: nil, isInCloud: false, hasError: false, allowNetwork: false)
    else { Issue.record("expected failed"); return }
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
