// Re-encodes PNGs with the EXIF UserComment "Screenshot", written by ImageIO the way iOS writes its own
// screenshots; Photos then gives the imported asset the photoScreenshot subtype. (Pillow's eXIf chunk isn't read by
// ImageIO, so Photos ignored it.) Usage: swift scripts/tag_screenshots.swift <in.png> <out.png> [<in> <out> ...]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty, args.count % 2 == 0 else {
  FileHandle.standardError.write(Data("usage: tag_screenshots.swift <in> <out> [...]\n".utf8))
  exit(2)
}
for i in stride(from: 0, to: args.count, by: 2) {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[i]) as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[i + 1]) as CFURL,
                                                          UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("can't read or write \(args[i])\n".utf8))
    exit(1)
  }
  let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]]
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { exit(1) }
}
