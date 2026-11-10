import Commit
import SquishBridge
import SwiftUI
import UIKit

/// Review & apply: what the queue will do, a notice for anything past the free quota (it opens the paywall), the
/// squish disclosures, then Apply. iOS asks before anything is deleted. Also the squish confirm and results sheet.
struct CommitSheet: View {
  @State private var model: CommitModel
  @State private var showingPaywall = false
  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  /// Called as the sheet goes away, with what was applied (nil if nothing ran).
  private var onClose: ((CommitReport?) -> Void)?

  init(app: AppModel, swipefileIds: [String], onClose: ((CommitReport?) -> Void)? = nil) {
    _model = State(initialValue: CommitModel(app: app, swipefileIds: swipefileIds))
    self.onClose = onClose
  }

  init(model: CommitModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: Roll.Space.l) { content }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Roll.Space.page)
          .padding(.top, Roll.Space.xs)
          .padding(.bottom, Roll.Space.xl)
      }
      .rollPage()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isFinished ? "Done" : "Cancel") { dismiss() }.disabled(model.phase == .applying)
        }
      }
      .safeAreaInset(edge: .bottom) { footer }
      .task { await model.load() }
      .onDisappear {
        onClose?(model.report)
        model.closed()
      }
      .sheet(isPresented: $showingPaywall, onDismiss: { Task { await model.load() } }) {
        PaywallView(provider: app.entitlements, pitch: app.home.paywallPitch) { showingPaywall = false }
      }
    }
    .presentationCornerRadius(Roll.Radius.panel)
    .interactiveDismissDisabled(model.phase == .applying)
  }

  private var title: String { model.plan.squishes.isEmpty || !model.plan.deletes.isEmpty ? "Review & apply" : "Squish" }

  private var isFinished: Bool {
    switch model.phase {
    case .done, .cancelled, .stopped: true
    default: false
    }
  }

  @ViewBuilder private var content: some View {
    switch model.phase {
    case .loading:
      ProgressView().frame(maxWidth: .infinity).padding(.top, Roll.Space.xxl)
    case .failed(let text):
      Text(text).font(Roll.Typeface.callout).foregroundStyle(.rollInk2).padding(.top, Roll.Space.s)
    case .ready, .applying:
      planRows
    case .done(let report):
      reportRows(report)
    case .cancelled(let report):
      cancelledRows(report)
    case .stopped(let report, let reason):
      stoppedRows(report, reason)
    }
  }

  // MARK: Before

  @ViewBuilder private var planRows: some View {
    let plan = model.plan
    if plan.isEmpty && plan.stale.isEmpty && plan.blockedByQuota == 0 {
      RollEmptyState(title: "Nothing is queued yet", message: "Swipe left on what you want gone.")
        .padding(.top, Roll.Space.xxl)
    }
    if !plan.deletes.isEmpty || !plan.keptLastCopies.isEmpty {
      Block(footer: plan.deletes.isEmpty ? nil : "Deleted items stay in Recently Deleted for 30 days.") {
        RollGroup {
          if !plan.deletes.isEmpty {
            RollRow(symbol: "trash", title: "Delete",
                    trailing: "\(plan.deletes.count.formatted()) · \(ByteFormat.about(plan.estBytes))")
          }
          if !plan.keptLastCopies.isEmpty {
            LineRow(symbol: "star.circle",
                    text: "\(plan.keptLastCopies.count) \(plan.keptLastCopies.count == 1 ? "shot is" : "shots are") kept so a set of duplicates isn't deleted entirely.")
          }
        }
      }
    }
    if !plan.albumMoves.isEmpty {
      Block(label: "Add to albums") {
        RollGroup {
          ForEach(plan.albumMoves.keys.sorted(), id: \.self) { name in
            RollRow(symbol: "rectangle.stack.badge.plus", title: name, trailing: "\(plan.albumMoves[name]?.count ?? 0)")
          }
        }
      }
    }
    if !plan.squishes.isEmpty { squishRows }
    if plan.blockedByQuota > 0 {
      Button {
        showingPaywall = true
      } label: {
        RollNotice(symbol: "lock.fill",
                   title: "\(plan.blockedByQuota.formatted()) more \(plan.blockedByQuota == 1 ? "item needs" : "items need") Roll Pro",
                   message: "The first 50 cleanups are free. Unlock Pro to apply the rest; they stay queued until then.")
          .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
      }
      .buttonStyle(PressScale())
      .accessibilityElement(children: .combine)
    }
  }

  @ViewBuilder private var squishRows: some View {
    let count = model.plan.squishes.count
    Block(footer: "Each item is replaced by a smaller copy with the same date, location, favorite and albums, once the copy checks out. The originals go to Recently Deleted.") {
      RollGroup {
        RollRow(symbol: "film.stack", title: "Squish",
                trailing: "\(count.formatted()) · saves \(ByteFormat.about(model.estimatedSquishSavings))")
        if model.keep4K { LineRow(symbol: "4k.tv", text: "4K videos stay 4K.") }
        if model.allowNetwork { LineRow(symbol: "icloud.and.arrow.down", text: "Originals only in iCloud are downloaded over Wi-Fi.") }
      }
    }
    if model.squishNeedsFullAccess { FullAccessNotice() }
    Block(label: "Not carried over") {
      RollGroup {
        ForEach(model.transferLimitations, id: \.self) { line in LineRow(symbol: "info.circle", text: line) }
      }
    }
  }

  // MARK: After

  @ViewBuilder private func reportRows(_ report: CommitReport) -> some View {
    let lines = appliedLines(report, savings: true)
    let freed = !report.deleted.isEmpty || !report.squished.isEmpty
    if let first = lines.first {
      // The done moment: the ring closes around what was applied.
      Outcome(ring: true, title: first.text,
              message: freed ? "The space is freed once Recently Deleted is emptied in Photos (or after 30 days)." : nil)
      if lines.count > 1 {
        RollGroup {
          ForEach(lines.dropFirst()) { line in LineRow(symbol: line.symbol, text: line.text, emphasized: true) }
        }
      }
    } else {
      let tidied = CommitModel.refusals(in: report).isEmpty
      Outcome(ring: tidied, title: tidied ? "Queue tidied up" : "Nothing was squished", message: nil)
    }
    if !report.squished.isEmpty {
      Block(label: "Saved per item") {
        RollGroup {
          ForEach(report.squished, id: \.newAssetID) { copy in
            HStack(spacing: Roll.Space.s) {
              Thumbnail(id: copy.newAssetID, side: 120)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
              Text("\(ByteFormat.short(copy.originalBytes)) → \(ByteFormat.short(copy.newBytes))")
                .font(Roll.Typeface.subhead.monospacedDigit())
                .foregroundStyle(.rollInk2)
              Spacer(minLength: Roll.Space.xs)
              Text("−\(ByteFormat.short(copy.estimatedSavings))")
                .font(Roll.Typeface.figure)
                .foregroundStyle(.rollInk)
            }
            .padding(.horizontal, Roll.Space.m)
            .padding(.vertical, Roll.Space.xs)
          }
        }
      }
    }
    refusalRows(CommitModel.refusals(in: report))
    skippedRows(report)
    leftoverRows(report)
  }

  /// What a run applied, one line each ("Deleted 5", "Added 3 to Trips", "Squished 2 · saved about 1.2 GB").
  private func appliedLines(_ report: CommitReport, savings: Bool) -> [AppliedLine] {
    var lines: [AppliedLine] = []
    if !report.deleted.isEmpty {
      lines.append(AppliedLine(symbol: "trash", text: "Deleted \(report.deleted.count.formatted())"))
    }
    for name in report.addedToAlbums.keys.sorted() {
      lines.append(AppliedLine(symbol: "rectangle.stack.badge.plus",
                               text: "Added \(report.addedToAlbums[name]?.count ?? 0) to \(name)"))
    }
    if !report.squished.isEmpty {
      let saved = savings ? " · saved \(ByteFormat.about(report.estimatedSquishSavings))" : ""
      lines.append(AppliedLine(symbol: "film.stack", text: "Squished \(report.squished.count.formatted())\(saved)"))
    }
    return lines
  }

  @ViewBuilder private func skippedRows(_ report: CommitReport) -> some View {
    if !report.squishSkipped.isEmpty {
      NoteCard(symbol: "square.on.square",
               text: "\(report.squishSkipped.count) \(report.squishSkipped.count == 1 ? "original was" : "originals were") kept because \(report.squishSkipped.count == 1 ? "it" : "they") changed after the copy was made. The \(report.squishSkipped.count == 1 ? "copy is" : "copies are") still in your library.") {
        Button("Remove \(report.squishSkipped.count == 1 ? "the copy" : "the copies")", role: .destructive) {
          Task { await model.discardCopies(report.squishSkipped.map(\.newAssetID)) }
        }
        .buttonStyle(.rollSecondary)
      }
    }
    if !report.squishUnregistered.isEmpty {
      NoteCard(symbol: "questionmark.square.dashed",
               text: "\(report.squishUnregistered.count) \(report.squishUnregistered.count == 1 ? "original was" : "originals were") kept because Roll couldn't check \(report.squishUnregistered.count == 1 ? "its copy" : "their copies") any more. Home lists \(report.squishUnregistered.count == 1 ? "it" : "them") to replace or remove.") {
        EmptyView()
      }
    }
  }

  @ViewBuilder private func cancelledRows(_ report: CommitReport) -> some View {
    Outcome(symbol: "arrow.uturn.backward", title: "Nothing more was changed",
            message: model.keepsQueue ? "Your queue is still here. Declined changes don't count toward the free limit."
                                      : "Declined changes don't count toward the free limit.")
    pendingRows(report)
    leftoverRows(report)
  }

  /// A change failed partway: what was applied, what wasn't, and the copies waiting next to their originals.
  @ViewBuilder private func stoppedRows(_ report: CommitReport, _ reason: SquishRefusal) -> some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      Outcome(symbol: "exclamationmark.triangle", title: "Not everything was applied", message: nil)
      if model.deletesNotApplied > 0 {
        Text("\(model.deletesNotApplied.formatted()) \(model.deletesNotApplied == 1 ? "delete" : "deletes") didn't go through; \(model.deletesNotApplied == 1 ? "it stays" : "they stay") queued.")
          .font(Roll.Typeface.callout)
          .foregroundStyle(.rollInk)
          .fixedSize(horizontal: false, vertical: true)
      }
      Group {
        switch reason {
        case .needsFullAccess: EmptyView()
        case .notSquishable(let why), .failed(let why): Text(why)
        case .needsDownload: Text("An original is only in iCloud. Turn on iCloud downloads and use Wi-Fi.")
        case .notEnoughSpace: Text("There isn't enough free space on your iPhone.")
        }
      }
      .font(Roll.Typeface.callout)
      .foregroundStyle(.rollInk2)
      .fixedSize(horizontal: false, vertical: true)
    }
    if reason == .needsFullAccess { FullAccessNotice() }
    let applied = appliedLines(report, savings: false)
    if !applied.isEmpty {
      Block(label: "Applied before it stopped") {
        RollGroup {
          ForEach(applied) { line in LineRow(symbol: line.symbol, text: line.text, emphasized: true) }
        }
      }
    }
    pendingRows(report)
    refusalRows(CommitModel.refusals(in: report))
    skippedRows(report)
    leftoverRows(report)
  }

  @ViewBuilder private func pendingRows(_ report: CommitReport) -> some View {
    if !report.pendingSquishCopies.isEmpty {
      Block(footer: "If you close this, they wait on Home, where you can still replace the originals or remove the copies.") {
        NoteCard(symbol: "square.on.square",
                 text: "\(report.pendingSquishCopies.count) smaller \(report.pendingSquishCopies.count == 1 ? "copy is" : "copies are") in your library next to the originals.") {
          Button("Replace the originals") { Task { await model.retrySquishDeletes() } }
            .buttonStyle(.rollPrimary)
          Button("Remove the copies", role: .destructive) {
            Task { await model.discardCopies(report.pendingSquishCopies.map(\.newAssetID)) }
          }
          .buttonStyle(.rollSecondary)
        }
      }
    }
  }

  @ViewBuilder private func leftoverRows(_ report: CommitReport) -> some View {
    if !report.leftoverCopyIDs.isEmpty {
      Block(footer: "Copies that didn't pass their checks. The originals were kept.") {
        Button("Remove \(report.leftoverCopyIDs.count) leftover \(report.leftoverCopyIDs.count == 1 ? "copy" : "copies")",
               role: .destructive) { Task { await model.discardCopies(report.leftoverCopyIDs) } }
          .buttonStyle(.roll(.secondary, fullWidth: true))
      }
    }
  }

  @ViewBuilder private func refusalRows(_ refusals: [CommitModel.Refusal]) -> some View {
    if refusals.contains(where: { $0.reason == .needsFullAccess }) { FullAccessNotice() }
    let notSquishable = refusals.compactMap { r -> (String, String)? in
      if case .notSquishable(let why) = r.reason { (r.assetID, why) } else { nil }
    }
    if !notSquishable.isEmpty {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: Roll.Space.xs) {
          ForEach(notSquishable, id: \.0) { id, why in RefusalRow(assetID: id, reason: why) }
        }
        .padding(.top, Roll.Space.xs)
      } label: {
        Text("Not squishable yet (\(notSquishable.count))")
          .font(Roll.Typeface.headline)
          .foregroundStyle(.rollInk)
      }
      .tint(.rollInk3)
      .rollCard()
    }
    let other = refusals.compactMap { r -> (String, String)? in
      switch r.reason {
      case .needsFullAccess, .notSquishable: nil
      case .needsDownload: (r.assetID, "Only in iCloud. Turn on iCloud downloads and use Wi-Fi.")
      case .notEnoughSpace: (r.assetID, "Not enough free space on your iPhone to squish it safely.")
      case .failed(let why): (r.assetID, why)
      }
    }
    if !other.isEmpty {
      Block(label: "Not squished") {
        RollGroup {
          ForEach(other, id: \.0) { id, why in
            RefusalRow(assetID: id, reason: why)
              .padding(.horizontal, Roll.Space.m)
              .padding(.vertical, Roll.Space.xs)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }

  /// The confirm, in the thumb's reach: ember for the pile's action (delete, squish), ink for album-only moves.
  @ViewBuilder private var footer: some View {
    if model.phase == .ready || model.phase == .applying {
      let destructive = !model.plan.deletes.isEmpty || !model.plan.squishes.isEmpty
      VStack(spacing: Roll.Space.xs) {
        Button {
          Task { await model.apply() }
        } label: {
          ZStack {
            Text(model.applyTitle).opacity(model.phase == .applying ? 0 : 1)
            if model.phase == .applying {
              ProgressView().tint(destructive ? .white : .rollOnInk)
            }
          }
        }
        .buttonStyle(.roll(destructive ? .destructive : .primary, fullWidth: true))
        .disabled(!model.canApply)
        if let text = model.progressText {
          Text(text)
            .font(Roll.Typeface.caption.monospacedDigit())
            .foregroundStyle(.rollInk2)
            .contentTransition(.numericText())
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.top, Roll.Space.s)
      .padding(.bottom, Roll.Space.xs)
      .background {
        LinearGradient(colors: [Roll.Palette.paper.opacity(0), Roll.Palette.paper], startPoint: .top,
                       endPoint: UnitPoint(x: 0.5, y: 0.3))
          .ignoresSafeArea(edges: .bottom)
          .allowsHitTesting(false)
      }
    }
  }
}
