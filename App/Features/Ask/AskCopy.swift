import Foundation
import Ranking

// What an answer says. Every sentence is built from the search's own numbers (ADR-0005).
extension AskModel {
  // MARK: Copy

  /// "Screenshots of group chats".
  static func name(_ query: String) -> String {
    query.prefix(1).uppercased() + query.dropFirst()
  }

  /// An answer's title: the query for the first, what changed for a refinement ("22 older than a year").
  static func title(_ answer: Answer) -> String {
    guard answer.isRefinement, let result = answer.result else { return name(answer.query) }
    let seeds = answer.seeds.count
    let filters = [seeds == 0 ? nil : "like the \(seeds == 1 ? "one" : "\(seeds)") you picked",
                   answer.refinement.olderThanAYear ? "older than a year" : nil,
                   answer.refinement.onlyOnThisIPhone ? "on this iPhone" : nil].compactMap { $0 }
    // "22 older than a year, biggest first"; without a filter the count takes a noun: "8 matches, biggest first".
    var title = "\(result.matches.count.formatted())"
    title += filters.isEmpty ? " \(result.matches.count == 1 ? "match" : "matches")" : " " + filters.joined(separator: " and ")
    if answer.refinement.biggestFirst { title += ", biggest first" }
    return title
  }

  /// "38 photos · about 214 MB", or for a refinement "about 131 MB · none of them favorites".
  static func subtitle(_ answer: Answer) -> String {
    guard let result = answer.result else { return "" }
    let size = ByteFormat.about(result.totalBytes)
    if answer.isRefinement {
      return "\(size) · \(SearchSummary.favorites(result.favorites, of: result.matches.count))"
    }
    return "\(photos(result.matches.count)) · \(size)"
  }

  /// "+ 29 more · 6 weaker matches folded".
  static func more(_ result: PhotoSearch.Result, showing: Int) -> String? {
    let hidden = max(0, result.matches.count - showing)
    let weaker = result.weaker.count
    var parts: [String] = []
    if hidden > 0 { parts.append("+ \(hidden.formatted()) more") }
    if weaker > 0 { parts.append("\(weaker.formatted()) weaker \(weaker == 1 ? "match" : "matches") folded") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// "Most are from 2023 and early 2024. Want to swipe through them, or narrow it down first?"
  static func reply(_ answer: Answer) -> String {
    guard let result = answer.result, !result.matches.isEmpty else { return "" }
    let when = SearchSummary.when(result.matches.map(\.created)).map { $0 + " " } ?? ""
    let ask = result.matches.count == 1 ? "Want to look at it?" : answer.isRefinement
      ? "Swipe through these?" : "Want to swipe through them, or narrow it down first?"
    return when + ask
  }

  /// "Compared 29,589 items on this iPhone in 0.09 s" (counted and measured by the engine).
  static func elapsed(_ result: PhotoSearch.Result) -> String {
    let seconds = Double(result.elapsed.components.seconds) + Double(result.elapsed.components.attoseconds) / 1e18
    let time = seconds < 0.01 ? "under 0.01 s" : "\(seconds.formatted(.number.precision(.fractionLength(2)))) s"
    let items = "\(result.compared.formatted()) \(result.compared == 1 ? "item" : "items")"
    return "Compared \(items) on this iPhone in \(time)"
  }

  static func photos(_ count: Int) -> String { "\(count.formatted()) \(count == 1 ? "photo" : "photos")" }

  /// Under the swipe step's title: "older than a year · 22 photos" (what's left to swipe).
  static func swipeSubtitle(_ answer: Answer) -> String {
    let count = answer.remaining == 0 ? "all swiped" : photos(answer.toSwipe)
    let filters = [answer.refinement.olderThanAYear ? "older than a year" : nil,
                   answer.refinement.onlyOnThisIPhone ? "on this iPhone" : nil,
                   answer.refinement.biggestFirst ? "biggest first" : nil].compactMap { $0 }
    return (filters + [count]).joined(separator: " · ")
  }
}
