import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes a JPEG/PNG to HEIC at quality 0.8 with ImageIO, carrying over the original properties
/// (EXIF, GPS, TIFF, orientation) and auxiliary data (HDR gain map, depth, mattes).
public enum PhotoSquisher {
  public static let quality = 0.8

  /// Auxiliary image kinds a photo can carry. `.gainMap` covers both the Apple (`HDRGainMap`) and ISO
  /// (`ISOGainMap`) flavours.
  public enum Auxiliary: Sendable, Hashable, CaseIterable {
    case gainMap, depth, disparity, portraitMatte, hairMatte, skinMatte, teethMatte, glassesMatte, skyMatte

    /// ImageIO type names to look for in a source.
    var types: [CFString] {
      switch self {
      case .gainMap: [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap]
      case .depth: [kCGImageAuxiliaryDataTypeDepth]
      case .disparity: [kCGImageAuxiliaryDataTypeDisparity]
      case .portraitMatte: [kCGImageAuxiliaryDataTypePortraitEffectsMatte]
      case .hairMatte: [kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte]
      case .skinMatte: [kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte]
      case .teethMatte: [kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte]
      case .glassesMatte: [kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte]
      case .skyMatte: [kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
      }
    }
  }

  static func auxiliary(of source: CGImageSource) -> Set<Auxiliary> {
    Set(Auxiliary.allCases.filter { kind in
      kind.types.contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }
    })
  }

  /// Kinds the source had that the output lost.
  static func missingAuxiliary(source: Set<Auxiliary>, output: Set<Auxiliary>) -> Set<Auxiliary> {
    source.subtracting(output)
  }

  public static func squish(input: URL, output: URL) throws -> SquishResult {
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
      throw SquishError.exportFailed(CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: input]))
    }
    guard CGImageSourceGetCount(source) == 1 else { throw SquishError.ineligible(.multiFrame) }
    let inBytes: Int64
    do { inBytes = try SquishVerify.fileSize(input) } catch { throw SquishError.exportFailed(error) }
    let heic = UTType.heic.identifier
    guard (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(heic) == true else {
      throw SquishError.unsupported
    }
    try? FileManager.default.removeItem(at: output)
    guard let dest = CGImageDestinationCreateWithURL(output as CFURL, heic as CFString, 1, nil) else {
      throw SquishError.unsupported
    }
    // The gain map is carried by PreserveGainMap; depth and mattes are copied by hand below.
    var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality,
                                    kCGImageDestinationPreserveGainMap: true]
    let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    if let props = sourceProps { options.merge(props) { mine, _ in mine } }
    CGImageDestinationAddImageFromSource(dest, source, 0, options as CFDictionary)
    let sourceAux = auxiliary(of: source)
    for kind in sourceAux where kind != .gainMap {
      for type in kind.types {
        if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) {
          CGImageDestinationAddAuxiliaryDataInfo(dest, type, info)
          break
        }
      }
    }
    guard CGImageDestinationFinalize(dest) else {
      try? FileManager.default.removeItem(at: output)
      throw SquishError.exportFailed(CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: output]))
    }
    do {
      try verify(output: output, source: source, sourceProps: sourceProps, sourceAux: sourceAux)
      let outBytes = try SquishVerify.fileSize(output)
      guard SquishVerify.isSmallEnough(input: inBytes, output: outBytes) else { throw SquishError.notSmaller }
      return SquishResult(inputBytes: inBytes, outputBytes: outBytes)
    } catch {
      try? FileManager.default.removeItem(at: output)
      throw error as? SquishError ?? SquishError.exportFailed(error)
    }
  }

  /// Fully decodes the output and compares it with the source: size, colour profile and auxiliary data.
  private static func verify(output: URL, source: CGImageSource, sourceProps: [CFString: Any]?,
                             sourceAux: Set<Auxiliary>) throws {
    guard let out = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(out) == 1,
          let image = CGImageSourceCreateImageAtIndex(out, 0, nil),
          let pixels = image.dataProvider?.data, CFDataGetLength(pixels) > 0 else {  // reading the data forces a full decode
      throw SquishError.verificationFailed("output does not decode")
    }
    let outProps = CGImageSourceCopyPropertiesAtIndex(out, 0, nil) as? [CFString: Any]
    if let w = sourceProps?[kCGImagePropertyPixelWidth] as? Int, let h = sourceProps?[kCGImagePropertyPixelHeight] as? Int,
       image.width != w || image.height != h {
      throw SquishError.verificationFailed("output size differs")
    }
    if let profile = sourceProps?[kCGImagePropertyProfileName] as? String,
       outProps?[kCGImagePropertyProfileName] as? String != profile {
      throw SquishError.ineligible(.colorSpaceChanged)
    }
    if let model = sourceProps?[kCGImagePropertyColorModel] as? String, outProps?[kCGImagePropertyColorModel] as? String != model {
      throw SquishError.ineligible(.colorSpaceChanged)  // e.g. a CMYK JPEG would come out as RGB
    }
    if let problem = metadataProblem(source: sourceProps.map(stringKeyed) ?? [:], output: outProps.map(stringKeyed) ?? [:]) {
      throw SquishError.verificationFailed(problem)
    }
    if !missingAuxiliary(source: sourceAux, output: auxiliary(of: out)).isEmpty {
      throw SquishError.ineligible(.auxiliaryDataNotPreserved)
    }
  }

  // MARK: Metadata check

  private static func stringKeyed(_ d: [CFString: Any]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: d.map { ($0.key as String, $0.value) })
  }

  private static let checkedDictionaries: [(name: String, key: String)] = [
    ("Exif", kCGImagePropertyExifDictionary as String), ("GPS", kCGImagePropertyGPSDictionary as String),
    ("TIFF", kCGImagePropertyTIFFDictionary as String), ("IPTC", kCGImagePropertyIPTCDictionary as String),
  ]
  private static let iptcDateKeys: Set<String> = [kCGImagePropertyIPTCDateCreated as String, kCGImagePropertyIPTCTimeCreated as String]

  /// `nil` when every key in the source's EXIF, GPS, TIFF and IPTC dictionaries (and the orientation) is still in the
  /// output. The output may gain keys.
  ///
  /// One drop is accepted: IPTC `DateCreated`/`TimeCreated`, which ImageIO folds into EXIF when writing HEIC. That is
  /// only fine while the EXIF `DateTimeOriginal` is unchanged, so the date is still there.
  static func metadataProblem(source: [String: Any], output: [String: Any]) -> String? {
    for (name, key) in checkedDictionaries {
      guard let src = source[key] as? [String: Any], !src.isEmpty else { continue }
      let out = output[key] as? [String: Any] ?? [:]
      var missing = Set(src.keys).subtracting(out.keys)
      if name == "IPTC", exifDatesMatch(source: source, output: output) { missing.subtract(iptcDateKeys) }
      if !missing.isEmpty { return "\(name) metadata dropped: " + missing.sorted().joined(separator: ", ") }
    }
    if let o = source[kCGImagePropertyOrientation as String] as? Int, output[kCGImagePropertyOrientation as String] as? Int != o {
      return "orientation changed"
    }
    return nil
  }

  private static func exifDatesMatch(source: [String: Any], output: [String: Any]) -> Bool {
    let key = kCGImagePropertyExifDateTimeOriginal as String, dict = kCGImagePropertyExifDictionary as String
    guard let a = (source[dict] as? [String: Any])?[key] as? String else { return false }
    return (output[dict] as? [String: Any])?[key] as? String == a
  }
}
