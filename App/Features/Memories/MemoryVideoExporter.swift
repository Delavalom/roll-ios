import AVFoundation
import CoreVideo
import Memories

/// Renders a `ReelPlan` to a 1080x1920, 30 fps `.mp4` on the device (HEVC where the hardware does it, else H.264).
/// Silent. Music seam: the finished file has one video track and no audio track, so a bundled CC0 track can be
/// muxed in afterwards (AVMutableComposition + export passthrough) without touching the frame loop.
/// Cancel by cancelling the calling task: the partial file is deleted.
struct MemoryVideoExporter: Sendable {
  struct Result: Sendable {
    var url: URL
    var codec: String
    var frames: Int
    var skippedShots: Int
    var renderSeconds: Double
    var fileBytes: Int64
    var peakFootprintBytes: UInt64
  }

  enum Failure: Error { case emptyPlan, cannotWrite(String) }

  static let fps = 30
  static let bitsPerSecond = 10_000_000

  let source: any ReelFrameSource

  func export(_ plan: ReelPlan, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Result {
    guard plan.isUsable else { throw Failure.emptyPlan }
    try? FileManager.default.removeItem(at: url)
    let started = ContinuousClock.now
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let (settings, codec) = Self.outputSettings(for: writer)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: ReelFrameRenderer.width,
      kCVPixelBufferHeightKey as String: ReelFrameRenderer.height,
    ])
    guard writer.canAdd(input) else { throw Failure.cannotWrite("cannot add video input") }
    writer.add(input)
    guard writer.startWriting() else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "startWriting") }
    writer.startSession(atSourceTime: .zero)

    let total = Int((plan.duration * Double(Self.fps)).rounded())
    var peak = ProcessMemory.footprint()
    var skipped = Set<String>()
    var current = -1
    var last: [Int: ReelFrame] = [:]  // the last good picture per shot, so a failed decode holds instead of going black
    do {
      for n in 0..<total {
        try Task.checkCancellation()
        let time = Double(n) / Double(Self.fps)
        guard let blend = ReelFrameRenderer.blend(at: time, shots: plan.shots) else { continue }
        var layers: [ReelFrameRenderer.Layer] = []
        for (index, alpha) in [(blend.index, 1.0), (blend.index + 1, blend.nextAlpha)] where alpha > 0 {
          let shot = plan.shots[index]
          let local = min(max(time - shot.start, 0), shot.duration)
          if let frame = await source.frame(for: shot, at: local) { last[index] = frame }
          guard let frame = last[index] else { skipped.insert(shot.id); continue }
          layers.append(.init(frame: frame, progress: local / shot.duration, index: index, alpha: alpha))
        }
        if blend.index != current {
          current = blend.index
          last = last.filter { $0.key >= current }
          if current + 1 < plan.shots.count { await source.prepare(plan.shots[current + 1]) }
        }
        while !input.isReadyForMoreMediaData {
          try Task.checkCancellation()
          try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { throw Failure.cannotWrite("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw Failure.cannotWrite("no pixel buffer") }
        ReelFrameRenderer.render(layers, into: buffer)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(Self.fps))) else {
          throw Failure.cannotWrite(writer.error?.localizedDescription ?? "append")
        }
        if n % 15 == 0 { peak = max(peak, ProcessMemory.footprint()); progress(Double(n) / Double(total)) }
      }
    } catch {
      input.markAsFinished()
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: url)
      throw error
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "finish") }
    progress(1)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    let seconds = (ContinuousClock.now - started)
    return Result(url: url, codec: codec, frames: total, skippedShots: skipped.count,
                  renderSeconds: Double(seconds.components.seconds) + Double(seconds.components.attoseconds) / 1e18,
                  fileBytes: bytes, peakFootprintBytes: max(peak, ProcessMemory.footprint()))
  }

  static func outputSettings(for writer: AVAssetWriter) -> ([String: Any], String) {
    func settings(_ codec: AVVideoCodecType) -> [String: Any] {
      [AVVideoCodecKey: codec, AVVideoWidthKey: ReelFrameRenderer.width, AVVideoHeightKey: ReelFrameRenderer.height,
       AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitsPerSecond]]
    }
    let hevc = settings(.hevc)
    if writer.canApply(outputSettings: hevc, forMediaType: .video) { return (hevc, "hevc") }
    return (settings(.h264), "h264")
  }
}
