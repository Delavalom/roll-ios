import Squish
import SquishBridge
import SwiftUI
import UIKit

/// Squish: replace big videos and JPEG/PNG photos with smaller copies (spec §8).
struct SquishView: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    SquishList(model: SquishModel(app: app))
  }
}

private struct SquishList: View {
  @State var model: SquishModel
  @State private var run: CommitModel?
  /// The run being shown, kept for `onDismiss` (the sheet's item is already nil by then).
  @State private var lastRun: CommitModel?
  @State private var showRefused = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if model.needsFullAccess {
          SquishAccessNotice().padding(.top, Roll.Space.s)
        }
        options.padding(.top, Roll.Space.s)
        candidates
        if !model.catalog.hdrKept.isEmpty { hdrKept }
        if !model.notSquishable.isEmpty { refused }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.bottom, Roll.Space.xl)
    }
    .rollPage()
    .navigationTitle("Squish")
    .safeAreaInset(edge: .bottom) {
      if !model.selectedItems.isEmpty {
        Button {
          Task {
            let prepared = await model.prepareRun()
            lastRun = prepared
            run = prepared
          }
        } label: {
          VStack(spacing: 1) {
            Text(model.squishTitle).font(Roll.Typeface.headline)
            Text("saves \(ByteFormat.about(model.selectedSavings))").font(Roll.Typeface.caption).opacity(0.75)
          }
          .padding(.vertical, Roll.Space.xxs)
        }
        .buttonStyle(.roll(.primary, fullWidth: true))
        .disabled(model.needsFullAccess)
        .padding(.horizontal, Roll.Space.page)
        .padding(.top, Roll.Space.l)
        .padding(.bottom, Roll.Space.xs)
        .background {
          LinearGradient(colors: [Roll.Palette.paper.opacity(0), Roll.Palette.paper], startPoint: .top,
                         endPoint: UnitPoint(x: 0.5, y: 0.45))
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
      }
    }
    .task { await model.load() }
    .sheet(item: $run, onDismiss: {
      guard let finished = lastRun else { return }
      lastRun = nil
      Task { await model.finished(finished) }
    }) { commit in
      CommitSheet(model: commit)
    }
    .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil },
                                                           set: { if !$0 { model.notice = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.notice?.message ?? "")
    }
  }

  // MARK: Sections

  private func label(_ text: String) -> some View {
    SectionLabel(text)
      .padding(.horizontal, Roll.Space.xxs)
      .padding(.top, Roll.Space.l)
      .padding(.bottom, Roll.Space.s)
  }

  /// Keep 4K and iCloud downloads, with what they mean underneath.
  private var options: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      RollGroup {
        toggle("Keep 4K", isOn: $model.keep4K)
        toggle("Allow iCloud downloads (Wi-Fi)", isOn: $model.allowICloudDownloads)
      }
      Text("Videos are capped at 1080p unless you keep 4K. Originals only in iCloud are downloaded on Wi-Fi only.")
        .font(Roll.Typeface.caption)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Roll.Space.xxs)
    }
  }

  private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
    }
    .tint(.rollInk)
    .padding(.horizontal, Roll.Space.m)
    .frame(minHeight: 56)
  }

  @ViewBuilder private var candidates: some View {
    if model.isLoading {
      RollMark(size: Roll.Size.avatar, busy: true)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Roll.Space.xxl)
        .accessibilityElement()
        .accessibilityLabel("Loading")
    } else if model.catalog.items.isEmpty {
      RollEmptyState(title: "Nothing to squish", message: "Roll offers items that would get at least 30% smaller.")
        .padding(.top, Roll.Space.l)
    } else {
      label("Largest first")
      LazyVStack(spacing: Roll.Space.s) {
        ForEach(model.catalog.items) { item in
          Button { model.toggle(item.assetID) } label: {
            SquishRow(item: item, selected: model.isSelected(item.assetID),
                      inCloud: model.catalog.cloudOnly.contains(item.assetID),
                      needsDownload: !model.canSelect(item.assetID))
          }
          .buttonStyle(PressScale())
          .disabled(!model.canSelect(item.assetID))
        }
      }
    }
  }

  /// Dolby Vision videos kept as they are. Not combined, so "HDR video kept as is (N)" reads as its own text.
  private var hdrKept: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      HStack(spacing: Roll.Space.s) {
        RollIconTile(symbol: "sparkles.tv")
        Text("\(SquishRefusal.hdrVideoKept) (\(model.catalog.hdrKept.count.formatted()))")
          .font(Roll.Typeface.headline)
          .foregroundStyle(.rollInk)
        Spacer(minLength: 0)
      }
      .rollCard(padding: Roll.Space.s)
      Text("Dolby Vision videos, which iPhone records in HDR by default, stay as they are and aren't counted in the savings.")
        .font(Roll.Typeface.caption)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Roll.Space.xxs)
    }
    .padding(.top, Roll.Space.l)
  }

  /// "Not squishable yet (N)", folded until opened.
  private var refused: some View {
    VStack(alignment: .leading, spacing: 0) {
      RollGroup {
        Button {
          withAnimation(Roll.Motion.ease) { showRefused.toggle() }
        } label: {
          HStack(spacing: Roll.Space.s) {
            Text("Not squishable yet (\(model.notSquishable.count))")
              .font(Roll.Typeface.headline)
              .foregroundStyle(.rollInk)
            Spacer(minLength: Roll.Space.xs)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.bold))
              .foregroundStyle(.rollInk3)
              .rotationEffect(.degrees(showRefused ? 90 : 0))
              .accessibilityHidden(true)
          }
          .padding(.horizontal, Roll.Space.m)
          .frame(minHeight: 56)
          .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .accessibilityValue(showRefused ? "Expanded" : "Collapsed")
        if showRefused {
          ForEach(model.notSquishable) { item in
            RefusedRow(assetID: item.assetID, reason: "\(item.reason) · \(ByteFormat.about(item.estimatedBytes))")
          }
        }
      }
    }
    .padding(.top, Roll.Space.l)
  }
}

extension CommitModel: Identifiable {
  nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// "Squish needs Full Access to Photos" with a Settings link, as a notice card.
private struct SquishAccessNotice: View {
  var body: some View {
    RollNotice(symbol: "lock.rectangle.stack", title: SquishRefusal.fullAccessMessage,
               message: "With limited access Roll can't see which albums a photo is in, so the copy could lose them.",
               action: (title: "Open Settings", perform: {
                 if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
               }))
  }
}

/// An item Roll can't squish yet: its thumbnail and why.
private struct RefusedRow: View {
  let assetID: String
  let reason: String

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      Thumbnail(id: assetID, side: 120)
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      Text(reason)
        .font(Roll.Typeface.subhead)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Roll.Space.m)
    .padding(.vertical, Roll.Space.xs)
    .accessibilityElement(children: .combine)
  }
}

/// One candidate on its card: the thumbnail, about how big it is now and after, what happens to it, and how much
/// smaller it gets.
private struct SquishRow: View {
  let item: SquishPlanItem
  let selected: Bool
  let inCloud: Bool
  /// In iCloud while downloads are off: dimmed, not selectable, and says what would allow it.
  let needsDownload: Bool

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        // Accessibility text sizes: stacked, nothing truncated.
        VStack(alignment: .leading, spacing: Roll.Space.xs) {
          HStack(spacing: Roll.Space.s) {
            thumbnail
            Spacer(minLength: 0)
            percent
            check
          }
          sizes.fixedSize(horizontal: false, vertical: true)
          details.fixedSize(horizontal: false, vertical: true)
        }
      } else {
        HStack(spacing: Roll.Space.s) {
          thumbnail
          VStack(alignment: .leading, spacing: 3) {
            // One string per line, so the parts wrap as text instead of squeezing into columns.
            sizes.lineLimit(1).minimumScaleFactor(0.75)
            details.lineLimit(2)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          percent
          check
        }
      }
    }
    .rollCard(padding: Roll.Space.s)
    .overlay {
      if selected {
        RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
          .strokeBorder(.rollInk, lineWidth: 1.5)
      }
    }
    .opacity(needsDownload ? 0.55 : 1)
    .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
    .animation(Roll.Motion.quick, value: selected)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private var check: some View {
    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
      .font(.title3)
      .foregroundStyle(selected ? .rollInk : .rollInk3)
      .accessibilityHidden(true)
  }

  private var thumbnail: some View {
    Thumbnail(id: item.assetID, side: 200)
      .frame(width: 60, height: 60)
      .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
      .overlay(alignment: .bottomTrailing) {
        if inCloud {
          Image(systemName: "icloud.fill")
            .font(.caption2)
            .foregroundStyle(.rollInk)
            .padding(3)
            .background(.rollCard, in: Circle())
            .padding(3)
        }
      }
  }

  /// "about 120 MB → about 40 MB": now, and after.
  private var sizes: some View {
    Text("\(ByteFormat.about(item.estimatedBytes)) → \(ByteFormat.about(item.estimatedOutputBytes))")
      .font(Roll.Typeface.figure)
      .foregroundStyle(.rollInk)
      .lineLimit(2)
      .minimumScaleFactor(0.85)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var details: some View {
    Text(subtitle).font(Roll.Typeface.caption).foregroundStyle(.rollInk2)
  }

  private var percent: some View {
    Text("−\(Int((item.savingsFraction * 100).rounded()))%")
      .font(Roll.Typeface.label.monospacedDigit())
      .foregroundStyle(.rollInk)
      .padding(.horizontal, Roll.Space.xs)
      .frame(height: 24)
      .background(.rollWell, in: Capsule())
      .fixedSize()
  }

  /// "Video · 1080p (from 4K) · in iCloud", plus "allow iCloud downloads to squish" while downloads are off.
  private var subtitle: String {
    var parts = [item.kind == .video ? "Video" : "Photo"]
    if let down = item.downscale { parts.append(Self.label(down)) }
    if inCloud { parts.append("in iCloud") }
    if needsDownload { parts.append("allow iCloud downloads to squish") }
    return parts.joined(separator: " · ")
  }

  /// "1080p (from 4K)".
  static func label(_ d: Downscale) -> String {
    let from = min(d.fromW, d.fromH)
    let source = from >= 2160 ? "4K" : "\(from)p"
    return "\(min(d.toW, d.toH))p (from \(source))"
  }
}

#if DEBUG
#Preview {
  PreviewHost { NavigationStack { SquishView() } }
}
#endif
