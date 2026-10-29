import AVFoundation
import AudioToolbox
import VideoToolbox
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Fixtures {
  static let gpsLocation = "+37.7749-122.4194+000.000/"

  static func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("squish-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func fileSize(_ url: URL) throws -> Int64 {
    Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
  }

  // MARK: Video

  /// True when the host can encode HEVC in hardware (Apple Silicon and recent iPhones).
  static var hasHEVCHardwareEncoder: Bool {
    var list: CFArray?
    guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
    return encoders.contains {
      ($0[kVTVideoEncoderList_CodecType as String] as? UInt32) == kCMVideoCodecType_HEVC
        && ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true
    }
  }

  /// A small H.264 MOV at a high bitrate for its size (so HEVC is clearly smaller), with a QuickTime location item
  /// and optionally a mono AAC track. Frames are a moving gradient plus noise, so the encoder has real work to do.
  /// The defaults (2 s, 640x360) keep generation and export fast.
  static func makeVideo(at url: URL, seconds: Int = 2, fps: Int = 15, width: Int = 640, height: Int = 360,
                        bitrate: Int = 6_000_000, audio: Bool = false,
                        codec: AVVideoCodecType = .h264) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
    if codec == .h264 {
      settings[AVVideoCompressionPropertiesKey] = [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoExpectedSourceFrameRateKey: fps,
      ]
    }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    let location = AVMutableMetadataItem()
    location.identifier = .quickTimeMetadataLocationISO6709
    location.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String
    location.value = gpsLocation as NSString
    writer.metadata = [location]
    writer.add(input)
    var audioInput: AVAssetWriterInput?
    if audio {
      let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 1, AVSampleRateKey: 44_100, AVEncoderBitRateKey: 64_000,
      ])
      a.expectsMediaDataInRealTime = false
      writer.add(a)
      audioInput = a
    }
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    // A short ring of pre-rendered frames (moving gradient plus noise) keeps generation fast in debug
    // builds while still giving the encoder busy, non-repeating-looking content.
    let ringSize = 6
    let rowBytes = width * 4
    let ring = UnsafeMutablePointer<UInt8>.allocate(capacity: ringSize * rowBytes * height)
    defer { ring.deallocate() }
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    for f in 0..<ringSize {
      for y in 0..<height {
        let row = ring + (f * height + y) * rowBytes
        for x in 0..<rowBytes {
          state ^= state << 13; state ^= state >> 7; state ^= state << 17
          let g = ((x >> 2) + f * 8) / 8 + y / 8
          row[x] = UInt8(truncatingIfNeeded: g + Int(state >> 58))
        }
      }
    }
    let sampleRate = 44_100, chunk = 1024
    var audioFrames = 0
    // Appends audio without ever blocking: the writer only accepts audio that isn't far ahead of the video,
    // so waiting here (instead of pumping from the video wait loop) can deadlock.
    func pumpAudio(upTo limit: Int) throws {
      guard let audioInput else { return }
      while audioFrames < limit, audioInput.isReadyForMoreMediaData {
        audioInput.append(try sineBuffer(startFrame: audioFrames, frames: chunk, rate: sampleRate))
        audioFrames += chunk
      }
    }
    for n in 0..<(seconds * fps) {
      // The writer holds back video until audio has caught up to it, so while waiting, feed audio as far as it will go.
      while !input.isReadyForMoreMediaData {
        try pumpAudio(upTo: seconds * sampleRate)
        try await Task.sleep(for: .milliseconds(2))
      }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      guard let buffer = pb else { throw CocoaError(.fileWriteUnknown) }
      CVPixelBufferLockBaseAddress(buffer, [])
      let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      let frame = ring + (n % ringSize) * height * rowBytes
      for y in 0..<height { memcpy(base + y * stride, frame + y * rowBytes, rowBytes) }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps))) else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
      }
    }
    input.markAsFinished()
    while audioInput != nil, audioFrames < seconds * sampleRate {
      try pumpAudio(upTo: seconds * sampleRate)
      try await Task.sleep(for: .milliseconds(2))
    }
    audioInput?.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
  }

  private static func sineBuffer(startFrame: Int, frames: Int, rate: Int) throws -> CMSampleBuffer {
    var samples = (0..<frames).map { i -> Int16 in
      Int16(8000 * sin(2 * Double.pi * 440 * Double(startFrame + i) / Double(rate)))
    }
    var asbd = AudioStreamBasicDescription(
      mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    let bytes = frames * 2
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                       blockBufferOut: &block)
    CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: frames,
      presentationTimeStamp: CMTime(value: Int64(startFrame), timescale: Int32(rate)), packetDescriptions: nil,
      sampleBufferOut: &buffer)
    guard let buffer else { throw CocoaError(.fileWriteUnknown) }
    return buffer
  }

  static func locationItems(in url: URL) async throws -> [AVMetadataItem] {
    let items = try await AVURLAsset(url: url).load(.metadata)
    return AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataLocationISO6709)
  }

  // MARK: Photo

  static var gps: [String: Any] { [
    kCGImagePropertyGPSLatitude as String: 37.7749,
    kCGImagePropertyGPSLatitudeRef as String: "N",
    kCGImagePropertyGPSLongitude as String: 122.4194,
    kCGImagePropertyGPSLongitudeRef as String: "W",
    kCGImagePropertyGPSAltitude as String: 16.0,
  ] }

  /// 4000x3000 gradient plus noise JPEG with EXIF, GPS and a non-default orientation.
  static func makeJPEG(at url: URL, width: Int = 4000, height: Int = 3000, gainMap: Bool = false,
                       colorSpace cs: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!,
                       extraProperties: [String: Any] = [:]) throws {
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var state: UInt64 = 0x1234_5678_9ABC_DEF1
    for y in 0..<height {
      for x in 0..<width {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        let nz = Int(state >> 40) & 0x1F
        let o = (y * width + x) * 4
        px[o] = UInt8(truncatingIfNeeded: x * 255 / width + nz)
        px[o + 1] = UInt8(truncatingIfNeeded: y * 255 / height + nz)
        px[o + 2] = UInt8(truncatingIfNeeded: (x + y) * 255 / (width + height) + nz)
        px[o + 3] = 255
      }
    }
    let image = ctx.makeImage()!
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    let props: [String: Any] = [
      kCGImageDestinationLossyCompressionQuality as String: 0.95,
      kCGImagePropertyOrientation as String: 6,
      kCGImagePropertyGPSDictionary as String: gps,
      kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:10:23 12:00:00"],
    ]
    CGImageDestinationAddImage(dest, image, props.merging(extraProperties) { $1 } as CFDictionary)
    if gainMap { CGImageDestinationAddAuxiliaryDataInfo(dest, kCGImageAuxiliaryDataTypeHDRGainMap, gainMapInfo() as CFDictionary) }
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
  }

  /// A synthetic 8-bit gain map, tagged the way Apple's HDR JPEGs are.
  static func gainMapInfo(width gw: Int = 100, height gh: Int = 75) -> [CFString: Any] {
    let gain = Data((0..<(gw * gh)).map { UInt8($0 % gw * 255 / gw) })
    let metadata = CGImageMetadataCreateMutable()
    let ns = "http://ns.apple.com/HDRGainMap/1.0/" as CFString
    CGImageMetadataRegisterNamespaceForPrefix(metadata, ns, "HDRGainMap" as CFString, nil)
    let tag = CGImageMetadataTagCreate(ns, "HDRGainMap" as CFString, "HDRGainMapVersion" as CFString, .default, 65536 as CFNumber)!
    CGImageMetadataSetTagWithPath(metadata, nil, "HDRGainMap:HDRGainMapVersion" as CFString, tag)
    return [
      kCGImageAuxiliaryDataInfoData: gain as CFData,
      kCGImageAuxiliaryDataInfoDataDescription: ["Width": gw, "Height": gh, "BytesPerRow": gw, "PixelFormat": 1_278_226_488] as CFDictionary,
      kCGImageAuxiliaryDataInfoMetadata: metadata,
    ]
  }

  static func hasGainMap(_ url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap].contains {
      CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, $0) != nil
    }
  }

  /// A two-frame GIF.
  static func makeGIF(at url: URL) throws {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: cs,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let a = ctx.makeImage()!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let b = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(dest, a, nil); CGImageDestinationAddImage(dest, b, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
  }

  /// A small CMYK JPEG (ImageIO writes RGB when re-encoding it to HEIC).
  static func makeCMYKJPEG(at url: URL) throws {
    let w = 800, h = 600
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceCMYK(),
                        bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    var state: UInt64 = 7
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(ctx.bytesPerRow * h) { state ^= state << 13; state ^= state >> 7; state ^= state << 17; p[i] = UInt8(truncatingIfNeeded: state >> 30) }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
  }

  static func properties(of url: URL) -> [String: Any]? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
  }

  static var canEncodeHEIC: Bool {
    let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
    return ids.contains(UTType.heic.identifier)
  }
}
