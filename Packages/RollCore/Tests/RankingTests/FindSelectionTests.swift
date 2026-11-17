import Foundation
@testable import Ranking
import Store
import Testing

struct AlbumSelectionTests {
  @Test func strongMatchesStartSelectedAndTapsToggle() {
    var s = AlbumSelection(ids: ["a", "b", "w", "a"], preselected: ["a", "b", "zzz"], name: "Soccer")
    #expect(s.ids == ["a", "b", "w"])
    #expect(s.count == 2)
    #expect(!s.allSelected)
    s.toggle("w")
    s.toggle("a")
    s.toggle("nope")
    #expect(s.orderedSelection == ["b", "w"])
    #expect(s.createTitle == "Add 2 photos")
  }

  @Test func selectAndDeselectAll() {
    var s = AlbumSelection(ids: ["a", "b"], preselected: [], name: "x")
    #expect(!s.canCreate)
    s.selectAll()
    #expect(s.allSelected && s.count == 2)
    #expect(s.canCreate)
    s.deselectAll()
    #expect(s.count == 0 && !s.canCreate)
    s.toggle("a")
    #expect(s.createTitle == "Add 1 photo")
    #expect(!AlbumSelection(ids: [], preselected: [], name: "x").allSelected)
  }

  /// Photos-style drag: the first photo's new state is applied to everything between it and the finger, in grid order.
  @Test func dragSelectsTheRangeFromTheFirstPhoto() {
    var s = AlbumSelection(ids: ["a", "b", "c", "d", "e", "f"], preselected: ["e"], name: "x")
    s.beginDrag(at: 1)
    #expect(s.orderedSelection == ["b", "e"])
    s.continueDrag(to: 4)
    #expect(s.orderedSelection == ["b", "c", "d", "e"])
    s.continueDrag(to: 5)
    #expect(s.orderedSelection == ["b", "c", "d", "e", "f"])
    // Back over photos the drag passed: they return to how they were before it.
    s.continueDrag(to: 2)
    #expect(s.orderedSelection == ["b", "c", "e"])
    // Past the first photo, the other way.
    s.continueDrag(to: 0)
    #expect(s.orderedSelection == ["a", "b", "e"])
    s.endDrag()
    s.continueDrag(to: 5)
    #expect(s.orderedSelection == ["a", "b", "e"], "no drag in progress: nothing changes")
  }

  @Test func dragFromASelectedPhotoDeselects() {
    var s = AlbumSelection(ids: ["a", "b", "c", "d"], preselected: ["a", "b", "d"], name: "x")
    s.beginDrag(at: 0)
    s.continueDrag(to: 2)
    #expect(s.orderedSelection == ["d"])
    s.continueDrag(to: 1)
    #expect(s.orderedSelection == ["d"], "c stays as it was before the drag: not selected")
    s.continueDrag(to: 0)
    #expect(s.orderedSelection == ["b", "d"])
    s.endDrag()
    s.continueDrag(to: 3)
    #expect(s.orderedSelection == ["b", "d"])
  }

  @Test func dragClampsToTheGrid() {
    var s = AlbumSelection(ids: ["a", "b", "c"], preselected: [], name: "x")
    s.beginDrag(at: 7)
    #expect(s.orderedSelection == ["c"])
    s.continueDrag(to: -3)
    #expect(s.allSelected)
    var empty = AlbumSelection(ids: [], preselected: [], name: "x")
    empty.beginDrag(at: 0)
    empty.continueDrag(to: 2)
    #expect(empty.count == 0)
  }

  @Test func needsANameAndDefaultsToTheQuery() {
    var s = AlbumSelection(ids: ["a"], preselected: ["a"], name: AlbumSelection.defaultName(query: "  soccer games "))
    #expect(s.name == "Soccer games")
    s.name = "   "
    #expect(!s.canCreate)
    s.name = " Trip "
    #expect(s.trimmedName == "Trip" && s.canCreate)
  }
}

struct SeedPickTests {
  @Test func picksUpToThree() {
    var p = SeedPick()
    #expect(!p.canSearch)
    #expect(p.actionTitle == "Pick up to 3 photos")
    p.toggle("a")
    #expect(p.actionTitle == "More like this one")
    p.toggle("b"); p.toggle("c"); p.toggle("d")
    #expect(p.ids == ["a", "b", "c"] && p.isFull)
    #expect(p.actionTitle == "More like these 3")
    p.toggle("b")
    #expect(p.ids == ["a", "c"] && p.canSearch)
    #expect(SeedPick(ids: ["1", "2", "3", "4"]).ids.count == 3)
    #expect(SeedPick.chipTitle(1) == "Like 1 photo" && SeedPick.chipTitle(2) == "Like 2 photos")
  }
}

struct LivingAlbumInboxTests {
  let soccer = SavedSearchRecord(id: "s", query: "soccer", albumName: "Soccer", createdAt: 0)
  let dog = SavedSearchRecord(id: "d", query: "dog", albumName: "Dog", createdAt: 1)

  @Test func offersBecomeCardsAndEmptyOffersClearThem() {
    var inbox = LivingAlbumInbox()
    inbox.receive(LivingAlbum.Offer(ids: [], watermark: 5), for: dog)
    #expect(inbox.items.isEmpty)
    inbox.receive(LivingAlbum.Offer(ids: Array(repeating: "x", count: 12).enumerated().map { "p\($0.offset)" },
                                    watermark: 30), for: soccer)
    inbox.receive(LivingAlbum.Offer(ids: ["q"], watermark: 31), for: dog)
    #expect(inbox.items.map(\.title) == ["12 new photos for Soccer", "1 new photo for Dog"])
    inbox.receive(LivingAlbum.Offer(ids: ["p0", "p1"], watermark: 32), for: soccer)
    #expect(inbox.items.map(\.title) == ["2 new photos for Soccer", "1 new photo for Dog"], "replaced in place")
    inbox.receive(LivingAlbum.Offer(ids: [], watermark: 33), for: soccer)
    #expect(inbox.items.map(\.savedSearchId) == ["d"])
  }

  @Test func resolvingRemovesTheOfferAndHandsBackItsWatermark() {
    var inbox = LivingAlbumInbox()
    inbox.receive(LivingAlbum.Offer(ids: ["a"], watermark: 9), for: soccer)
    inbox.receive(LivingAlbum.Offer(ids: ["b"], watermark: 4), for: dog)
    #expect(inbox.resolve("s")?.watermark == 9)
    #expect(inbox.resolve("s") == nil)
    inbox.keep(only: [])
    #expect(inbox.items.isEmpty)
  }

  @Test func keepUpdatedIsOfferedOnlyForATypedQueryWithoutSeeds() {
    #expect(KeepUpdatedOffer.state(query: "soccer", seeds: [], albumName: "Games", saved: [soccer]) == .available)
    #expect(KeepUpdatedOffer.state(query: "Soccer", seeds: [], albumName: "Soccer", saved: [soccer]) == .alreadyKept)
    #expect(KeepUpdatedOffer.state(query: "soccer", seeds: ["a"], albumName: "Soccer", saved: []) == .unavailable)
    #expect(KeepUpdatedOffer.state(query: nil, seeds: [], albumName: "Soccer", saved: []) == .unavailable)
    #expect(KeepUpdatedOffer.state(query: "  ", seeds: [], albumName: "Soccer", saved: []) == .unavailable)
    #expect(KeepUpdatedOffer.state(query: "soccer", seeds: [], albumName: " ", saved: []) == .unavailable)
  }
}
