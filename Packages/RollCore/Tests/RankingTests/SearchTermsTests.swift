import Ranking
import Testing

struct SearchTermsTests {
  @Test func termsAreLowercasedFoldedSplitDedupedInOrder() {
    #expect(SearchTerms.terms("Café, CAFÉ! naïve-Señor a 4815162342 x") == ["cafe", "naive", "senor", "4815162342"])
    #expect(SearchTerms.terms("Receipt_#INV2041 / receipt") == ["receipt", "inv2041"])
    #expect(SearchTerms.terms("ÅNGSTRÖM über") == ["angstrom", "uber"])
  }

  @Test func shortAndEmptyInputGiveNoTerms() {
    #expect(SearchTerms.terms("") == [])
    #expect(SearchTerms.terms("  a b c ! ? ") == [])
    #expect(SearchTerms.terms("ok") == ["ok"])
  }

  @Test func nonLatinLettersAreKept() {
    #expect(SearchTerms.terms("東京 タワー") == ["東京", "タワー"])
  }

  @Test func queryTermsDropStopwordsAndKindWords() {
    #expect(SearchTerms.queryTerms("a screenshot of my boarding pass") == ["boarding", "pass"])
    #expect(SearchTerms.queryTerms("the photos") == [])
    #expect(SearchTerms.queryTerms("la factura de la luz") == ["factura", "luz"])
  }

  @Test func lookupsAreCodesAndLongNumbers() {
    #expect(SearchTerms.isLookup(["k7q2lm"]))
    #expect(SearchTerms.isLookup(["inv2041"]))
    #expect(SearchTerms.isLookup(["4815162342"]))
    #expect(SearchTerms.isLookup(["2041", "trx50"]))
    #expect(!SearchTerms.isLookup(["417"]))  // too short to be an id
    #expect(!SearchTerms.isLookup(["invoice", "2041"]))  // a plain word in it
    #expect(!SearchTerms.isLookup(["dog"]))
    #expect(!SearchTerms.isLookup([]))
  }
}
