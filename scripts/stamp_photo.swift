// Writes a capture date and a GPS position into JPEGs through ImageIO, the way a camera would, so Photos gives the
// imported asset that creation date and location (used by scripts/make_demo_trip.py for the demo library).
// Usage: swift scripts/stamp_photo.swift <plan.tsv>
// Each plan line: in.jpg <TAB> out.jpg <TAB> "yyyy:MM:dd HH:mm:ss" <TAB> +hh:mm offset <TAB> latitude <TAB> longitude
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2,
      let plan = try? String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8) else {
  FileHandle.standardError.write(Data("usage: stamp_photo.swift <plan.tsv>\n".utf8))
  exit(2)
}
for line in plan.split(separator: "\n") where !line.isEmpty {
  let f = line.split(separator: "\t").map(String.init)
  guard f.count == 6, let lat = Double(f[4]), let lon = Double(f[5]) else {
    FileHandle.standardError.write(Data("bad plan line: \(line)\n".utf8))
    exit(2)
  }
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: f[0]) as CFURL, nil),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: f[1]) as CFURL,
                                                          UTType.jpeg.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("can't read or write \(f[0])\n".utf8))
    exit(1)
  }
  let properties: [CFString: Any] = [
    kCGImagePropertyExifDictionary: [
      kCGImagePropertyExifDateTimeOriginal: f[2],
      kCGImagePropertyExifDateTimeDigitized: f[2],
      kCGImagePropertyExifOffsetTimeOriginal: f[3],
      kCGImagePropertyExifOffsetTimeDigitized: f[3],
    ],
    kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: f[2]],
    kCGImagePropertyGPSDictionary: [
      kCGImagePropertyGPSLatitude: abs(lat), kCGImagePropertyGPSLatitudeRef: lat >= 0 ? "N" : "S",
      kCGImagePropertyGPSLongitude: abs(lon), kCGImagePropertyGPSLongitudeRef: lon >= 0 ? "E" : "W",
    ],
    kCGImageDestinationLossyCompressionQuality: 0.9,
  ]
  CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { exit(1) }
}
