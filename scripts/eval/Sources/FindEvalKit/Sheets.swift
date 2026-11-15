import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `<sheets>/<slug>/manifest.json`: which id each numbered tile shows. Private (ids).
public struct SheetManifest: Codable, Sendable, Equatable {
  public var slug: String
  public var query: String
  public var sheets: [Sheet]

  public init(slug: String, query: String, sheets: [Sheet]) { self.slug = slug; self.query = query; self.sheets = sheets }

  public struct Sheet: Codable, Sendable, Equatable {
    /// "sheet-01.png"
    public var file: String
    public var tiles: [Tile]
    public init(file: String, tiles: [Tile]) { self.file = file; self.tiles = tiles }
  }

  public struct Tile: Codable, Sendable, Equatable {
    /// The number printed on the tile, 1...20 on every sheet (row by row).
    public var n: Int
    public var id: String
    public init(n: Int, id: String) { self.n = n; self.id = id }
  }

  /// `ids` in order, `SheetLayout.perSheet` per sheet, numbered from 1 on each sheet.
  public static func plan(slug: String, query: String, ids: [String], perSheet: Int = SheetLayout.perSheet) -> SheetManifest {
    var sheets: [Sheet] = []
    for start in stride(from: 0, to: ids.count, by: perSheet) {
      let chunk = ids[start..<min(start + perSheet, ids.count)]
      let tiles = chunk.enumerated().map { Tile(n: $0.offset + 1, id: $0.element) }
      sheets.append(Sheet(file: String(format: "sheet-%02d.png", sheets.count + 1), tiles: tiles))
    }
    return SheetManifest(slug: slug, query: query, sheets: sheets)
  }
}

public enum SheetLayout {
  public static let columns = 5
  public static let rows = 4
  public static let perSheet = columns * rows
  public static let tile = 256
  public static let gap = 6
  public static var width: Int { columns * tile + (columns + 1) * gap }
  public static var height: Int { rows * tile + (rows + 1) * gap }

  /// The tile's square in CoreGraphics coordinates (origin bottom left), index 0 at the top left, row by row.
  public static func frame(_ index: Int) -> CGRect {
    let col = index % columns, row = index / columns
    let x = gap + col * (tile + gap)
    let yFromTop = gap + row * (tile + gap)
    return CGRect(x: x, y: height - yFromTop - tile, width: tile, height: tile)
  }
}

/// `<thumbs>/index.jsonl` from the phone export: `{"id","file","ok"}` per requested id, `file` relative to the folder.
public struct ThumbIndex: Sendable {
  public let folder: URL
  private let files: [String: String]

  public init(folder: URL) throws {
    self.folder = folder
    var files: [String: String] = [:]
    let url = folder.appending(path: "index.jsonl")
    if FileManager.default.fileExists(atPath: url.path) {
      let text = try String(contentsOf: url, encoding: .utf8)
      for line in text.split(whereSeparator: \.isNewline) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = o["id"] as? String else { continue }
        if (o["ok"] as? Bool) == false { files[id] = nil; continue }
        if let file = (o["file"] ?? o["path"]) as? String { files[id] = file }
      }
    }
    self.files = files
  }

  /// The thumbnail file for `id`: the index's entry, else `<16 hex of SHA-1(id)>.jpg` if it exists; nil when missing.
  public func url(for id: String) -> URL? {
    let fm = FileManager.default
    if let file = files[id] {
      let url = folder.appending(path: file)
      return fm.fileExists(atPath: url.path) ? url : nil
    }
    let guess = folder.appending(path: Self.defaultName(id))
    return fm.fileExists(atPath: guess.path) ? guess : nil
  }

  public static func defaultName(_ id: String) -> String {
    Insecure.SHA1.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16) + ".jpg"
  }
}

/// Draws contact sheets: 5 x 4 tiles of 256 px, each with its number (1...20) large on a contrasting badge in the top
/// left corner; a missing thumbnail is a grey tile reading "missing". Thumbnails are fitted whole (never cropped) on a
/// dark tile, so the judge sees the full frame.
public enum SheetRenderer {
  public struct Failure: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
  }

  /// `images[i]` is tile `i + 1`'s thumbnail, nil when missing.
  public static func render(_ images: [CGImage?], to url: URL) throws {
    precondition(images.count <= SheetLayout.perSheet, "too many tiles for one sheet")
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: SheetLayout.width, height: SheetLayout.height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      throw Failure("can't make a bitmap context")
    }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: SheetLayout.width, height: SheetLayout.height))
    ctx.interpolationQuality = .high
    for (i, image) in images.enumerated() {
      let frame = SheetLayout.frame(i)
      if let image {
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        ctx.fill(frame)
        ctx.draw(image, in: fitted(width: image.width, height: image.height, in: frame))
      } else {
        ctx.setFillColor(CGColor(srgbRed: 0.62, green: 0.62, blue: 0.62, alpha: 1))
        ctx.fill(frame)
        drawText("missing", size: 34, color: CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1),
                 centeredIn: frame, in: ctx)
      }
      drawBadge(i + 1, in: frame, ctx: ctx)
    }
    guard let image = ctx.makeImage() else { throw Failure("can't finish the sheet") }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw Failure("can't write \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("can't write \(url.lastPathComponent)") }
  }

  /// Decodes a JPEG/PNG thumbnail, downsampled to at most one tile; nil if unreadable.
  public static func loadImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: SheetLayout.tile,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  /// The largest rect with the image's aspect ratio inside `frame`, centred.
  public static func fitted(width: Int, height: Int, in frame: CGRect) -> CGRect {
    guard width > 0, height > 0 else { return frame }
    let scale = min(frame.width / CGFloat(width), frame.height / CGFloat(height))
    let w = CGFloat(width) * scale, h = CGFloat(height) * scale
    return CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
  }

  /// A black rounded badge with a white outline and a big white number, in the tile's top left corner.
  static func drawBadge(_ n: Int, in frame: CGRect, ctx: CGContext) {
    let side: CGFloat = n >= 10 ? 74 : 58, height: CGFloat = 58
    let badge = CGRect(x: frame.minX + 6, y: frame.maxY - 6 - height, width: side, height: height)
    let path = CGPath(roundedRect: badge, cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.88))
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(3)
    ctx.strokePath()
    drawText("\(n)", size: 42, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), centeredIn: badge, in: ctx)
  }

  static func drawText(_ text: String, size: CGFloat, color: CGColor, centeredIn rect: CGRect, in ctx: CGContext) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
    let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString,
                                                                         attributes as CFDictionary)!)
    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: rect.midX - bounds.width / 2 - bounds.minX,
                               y: rect.midY - bounds.height / 2 - bounds.minY)
    CTLineDraw(line, ctx)
  }
}
