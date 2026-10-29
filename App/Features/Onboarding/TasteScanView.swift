import Overview
import SwiftUI

/// The taste scan: a live counter over the newest 500 assets, then real numbers and a peek at Screenshots.
struct TasteScanView: View {
  let model: TasteScanModel
  let onContinue: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        switch model.phase {
        case .idle, .scanning: scanning
        case .done, .failed: results
        }
      }
      .padding(.horizontal, Roll.Space.page)
      .padding(.vertical, Roll.Space.xl)
      .animation(Roll.Motion.ease, value: model.phase)
    }
    .scrollBounceBehavior(.basedOnSize)
    .safeAreaInset(edge: .bottom) { footer }
    .rollPage()
  }

  private var footer: some View {
    VStack(spacing: Roll.Space.s) {
      ModelStatusView()
      Button("Continue", action: onContinue)
        .buttonStyle(.roll(.primary, fullWidth: true))
        .disabled(model.phase == .scanning)
    }
    .padding(.horizontal, Roll.Space.page)
    .padding(.top, Roll.Space.s)
    .padding(.bottom, Roll.Space.xs)
    .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
  }

  // MARK: Scanning

  private var scanning: some View {
    VStack(alignment: .leading, spacing: 0) {
      RollMark(size: 64, busy: true)
        .padding(.top, Roll.Space.xxl)
      Text("Looking at your newest photos")
        .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, Roll.Space.xl)
      Text("Roll's on-device AI is sorting them on this iPhone. Nothing about your photos leaves your phone.")
        .font(Roll.Typeface.body)
        .foregroundStyle(.rollInk2)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, Roll.Space.xs)
      VStack(alignment: .leading, spacing: Roll.Space.xs) {
        StatusLine(text: model.total > 0
          ? "\(model.processed.formatted()) of \(model.total.formatted()) looked at"
          : "Reading your library…")
        if model.total > 0 {
          RollProgressBar(value: Double(model.processed) / Double(model.total))
        }
      }
      .padding(.top, Roll.Space.xl)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Results

  private var results: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Roll.Space.xs) {
        RollMark(size: Roll.Size.avatar)
        Text(model.phase == .failed ? "Here's what Roll found so far" : "Here's what Roll found")
          .font(Roll.Typeface.headline)
          .foregroundStyle(.rollInk2)
      }
      .padding(.top, Roll.Space.s)
      HomeHeadline(onDevice: model.foundBytes, inCloud: model.inCloudBytes)
        .padding(.top, Roll.Space.m)
      if model.phase == .failed {
        Text("The scan stopped early. Roll keeps going in the background.")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, Roll.Space.xs)
      }

      if !model.found.isEmpty {
        SectionLabel("Found in your newest photos")
          .padding(.top, Roll.Space.xl)
          .padding(.bottom, Roll.Space.s)
        RollGroup {
          ForEach(model.found, id: \.title) { item in
            RollRow(symbol: Self.symbol(for: item.title), title: item.title, trailing: ByteFormat.about(item.bytes))
          }
        }
      }

      if !model.screenshotPreview.isEmpty {
        SectionLabel("Your Screenshots pile")
          .padding(.top, Roll.Space.xl)
          .padding(.bottom, Roll.Space.s)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Roll.Space.xs), count: 3),
                  spacing: Roll.Space.xs) {
          ForEach(model.screenshotPreview, id: \.self) { id in
            Thumbnail(id: id)
              .aspectRatio(1, contentMode: .fit)
              .clipShape(RoundedRectangle(cornerRadius: Roll.Radius.cell, style: .continuous))
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.screenshotPreview.count) screenshots from your library")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The same symbols as Home's cards.
  private static func symbol(for title: String) -> String {
    switch title {
    case "Screenshots": "iphone"
    case "Duplicates and similar shots": "square.on.square"
    case "Squishing big videos": "film.stack"
    case "Blurry": "camera.metering.unknown"
    default: "photo"
    }
  }
}
