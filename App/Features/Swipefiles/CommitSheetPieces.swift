import Commit
import SquishBridge
import SwiftUI
import UIKit

// The pieces CommitSheet is built from.

/// One applied change, as a line.
struct AppliedLine: Identifiable {
  let symbol: String
  let text: String
  var id: String { text }
}

/// An optional eyebrow, the content, and an optional footnote under it.
struct Block<Content: View>: View {
  var label: String?
  var footer: String?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      if let label { SectionLabel(label).padding(.horizontal, Roll.Space.xxs) }
      content
      if let footer {
        Text(footer)
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk3)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, Roll.Space.xxs)
      }
    }
  }
}

/// A row in a group: a symbol and one line of text. The text stays its own element (no combining), so each line
/// reads and can be found on its own.
struct LineRow: View {
  let symbol: String
  let text: String
  var emphasized = false

  var body: some View {
    HStack(alignment: emphasized ? .center : .top, spacing: Roll.Space.s) {
      if emphasized {
        RollIconTile(symbol: symbol)
      } else {
        Image(systemName: symbol)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.rollInk3)
          .frame(width: 20)
          .accessibilityHidden(true)
      }
      Text(text)
        .font(emphasized ? Roll.Typeface.headline : Roll.Typeface.subhead)
        .foregroundStyle(emphasized ? .rollInk : .rollInk2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.vertical, Roll.Space.s)
    .frame(minHeight: emphasized ? 56 : nil)
  }
}

/// The head of a finished sheet: the done ring (or a symbol), a title and a line.
struct Outcome: View {
  var ring = false
  var symbol: String?
  let title: String
  let message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.s) {
      if ring {
        DoneRing()
      } else if let symbol {
        RollIconTile(symbol: symbol)
      }
      Text(title)
        .rollTitle()
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let message {
        Text(message)
          .font(Roll.Typeface.callout)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, Roll.Space.s)
  }
}

/// A card with a symbol, a paragraph and the buttons that act on it.
struct NoteCard<Actions: View>: View {
  let symbol: String
  let text: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(alignment: .top, spacing: Roll.Space.s) {
      RollIconTile(symbol: symbol)
      VStack(alignment: .leading, spacing: Roll.Space.s) {
        Text(text)
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk)
          .fixedSize(horizontal: false, vertical: true)
        if Actions.self != EmptyView.self {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: Roll.Space.xs) { actions }
            VStack(alignment: .leading, spacing: Roll.Space.xs) { actions }
          }
          .controlSize(.small)
        }
      }
      Spacer(minLength: 0)
    }
    .rollCard()
  }
}

/// "Squish needs Full Access to Photos" with a Settings link.
struct FullAccessNotice: View {
  var body: some View {
    RollNotice(symbol: "lock.rectangle.stack", title: SquishRefusal.fullAccessMessage,
               message: "With limited access Roll can't see which albums a photo is in, so the copy could lose them.",
               action: (title: "Open Settings", perform: {
                 if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
               }))
  }
}

struct RefusalRow: View {
  let assetID: String
  let reason: String

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      Thumbnail(id: assetID, side: 120)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
      Text(reason)
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}
