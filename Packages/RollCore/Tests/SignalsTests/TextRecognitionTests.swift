import CoreGraphics
import Testing
@testable import Signals

struct TextRecognitionTests {
  @Test func readsTheWordsOfAScreenshot() async throws {
    let text = try #require(try await TextRecognizer().recognize(try Fixtures.image("screenshot.png")))
    let lower = text.lowercased()
    for word in ["kitten", "boarding", "ramen", "whiteboard", "10:32"] {
      #expect(lower.contains(word), "missing \(word)")
    }
  }

  @Test func aBlankImageHasNoWords() async throws {
    #expect(try await TextRecognizer().recognize(Fixtures.solid(width: 200, height: 400, gray: 255)) == "")
  }

  @Test func theDefaultIsAccurateWithoutLanguageCorrection() {
    let reader = TextRecognizer()
    #expect(reader.level == .accurate && !reader.languageCorrection)
    #expect(reader.revision == "vision-text-accurate-1")
    #expect(TextRecognizer(level: .fast, languageCorrection: true).revision == "vision-text-fast-lc-1")
  }

  @Test func aCancelledTaskThrows() async throws {
    let image = try Fixtures.image("screenshot.png")
    let task = Task { try await TextRecognizer().recognize(image) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
}
