import Testing
@testable import Library

struct LibraryChangeTests {
  @Test func contentChangesAreSeparateFromMetadataChanges() {
    let change = LibraryChange(changed: ["fav"], contentChanged: ["edited"])
    #expect(change.changed == ["fav"])
    #expect(change.contentChanged == ["edited"])
    #expect(!change.isEmpty)
    #expect(!LibraryChange(contentChanged: ["x"]).isEmpty)
    #expect(LibraryChange().isEmpty)
  }
}
