// Mac OCR bench for lane L3 (words in images). Times Vision text recognition per image and counts the search terms it
// finds, one variable at a time: image long side (300 = Roll's analysis thumbnail, 960, 1600) and recognition level
// (.fast / .accurate), plus language correction at one size. Reference words: .accurate + language correction on the
// full image.
//
//   swiftc -O docs/investigations/evidence/2026-10-29-ocr/mac-ocr-bench.swift -o /tmp/mac-ocr-bench
//   /tmp/mac-ocr-bench <seed dir> docs/investigations/evidence/2026-10-29-ocr
//
// Writes mac-ocr.json (method and summary) and mac-ocr-images.jsonl (one line per image) into the folder given.
//
// Inputs: the synthetic seed set (`scripts/make_seed_media.py` → artifacts/seed: screenshots, receipts, documents,
// memes, photos). No private photos.
import CoreGraphics
import Foundation
import ImageIO
import Vision

func terms(_ text: String) -> Set<String> {
  Set(text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
    .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
}

func load(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Long side `side` (never upscaled), drawn like a PhotoKit thumbnail.
func resized(_ image: CGImage, side: Int) -> CGImage {
  let scale = min(1, Double(side) / Double(max(image.width, image.height)))
  let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return ctx.makeImage()!
}

struct Config: Hashable { var side: Int; var accurate: Bool; var correction: Bool
  var name: String { "\(accurate ? "accurate" : "fast")-\(side)px\(correction ? "-lc" : "")" }
}

func recognize(_ image: CGImage, _ c: Config) async throws -> String {
  var request = RecognizeTextRequest()
  request.recognitionLevel = c.accurate ? .accurate : .fast
  request.usesLanguageCorrection = c.correction
  let observations = try await request.perform(on: image)
  return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "artifacts/seed")
let wanted = ["screenshots", "receipts", "documents", "memes", "people", "food"]
let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
  .filter { u in ["png", "jpg"].contains(u.pathExtension) && wanted.contains { u.lastPathComponent.contains("_\($0)") } }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }

let configs = [
  Config(side: 300, accurate: false, correction: false), Config(side: 300, accurate: true, correction: false),
  Config(side: 960, accurate: false, correction: false), Config(side: 960, accurate: true, correction: false),
  Config(side: 960, accurate: true, correction: true),
  Config(side: 1600, accurate: false, correction: false), Config(side: 1600, accurate: true, correction: false),
]
let runs = 5

var rows: [[String: Any]] = []
for url in files {
  guard let full = load(url) else { continue }
  let kind = wanted.first { url.lastPathComponent.contains("_\($0)") }!
  let reference = terms(try await recognize(full, Config(side: 99_999, accurate: true, correction: true)))
  var row: [String: Any] = ["file": url.lastPathComponent, "kind": kind, "size": [full.width, full.height],
                            "referenceTerms": reference.count]
  var results: [String: Any] = [:]
  for c in configs {
    let image = resized(full, side: c.side)
    _ = try await recognize(image, c)  // warm-up
    var ms: [Double] = []
    var text = ""
    for _ in 0..<runs {
      let t0 = DispatchTime.now().uptimeNanoseconds
      text = try await recognize(image, c)
      ms.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    let found = terms(text)
    results[c.name] = ["ms": (median(ms) * 10).rounded() / 10, "terms": found.count,
                       "recall": reference.isEmpty ? 1.0 : Double(found.intersection(reference).count) / Double(reference.count)]
  }
  row["results"] = results
  rows.append(row)
  FileHandle.standardError.write("\(url.lastPathComponent)\n".data(using: .utf8)!)
}

// Summary per config and kind group: text kinds (screenshots, receipts, documents, memes) vs photos.
var summary: [String: Any] = [:]
for c in configs {
  for group in ["text", "photo"] {
    let picked = rows.filter { r in
      let k = r["kind"] as! String
      return group == "photo" ? ["people", "food"].contains(k) : !["people", "food"].contains(k)
    }
    let res = picked.map { ($0["results"] as! [String: Any])[c.name] as! [String: Any] }
    let ms = res.map { $0["ms"] as! Double }
    let recall = res.map { $0["recall"] as! Double }
    summary["\(c.name) \(group)"] = [
      "images": picked.count, "medianMs": median(ms), "meanMs": ms.reduce(0, +) / Double(max(1, ms.count)),
      "meanRecall": recall.reduce(0, +) / Double(max(1, recall.count)),
    ]
  }
}

let host = ProcessInfo.processInfo
let out: [String: Any] = [
  "date": ISO8601DateFormatter().string(from: Date()),
  "host": ["os": host.operatingSystemVersionString, "cpu": "Apple M1 Pro (sysctl machdep.cpu.brand_string)"],
  "method": "median of \(runs) runs after 1 warm-up, one image at a time, image already decoded and resized; "
    + "recall = share of the reference terms (accurate + language correction, full image) found; terms = lowercase, "
    + "diacritics folded, split on non-alphanumerics, >= 2 chars",
  "summary": summary, "images": "mac-ocr-images.jsonl (one JSON object per image)",
]
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
  .write(to: outDir.appendingPathComponent("mac-ocr.json"))
let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
try (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("mac-ocr-images.jsonl"), atomically: true, encoding: .utf8)
