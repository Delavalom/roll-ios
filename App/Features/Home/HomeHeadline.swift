import SwiftUI

/// "You can free about X on this iPhone", and what's in iCloud on its own line (freeing it frees iCloud space).
struct HomeHeadline: View {
  let onDevice: Int64
  let inCloud: Int64

  var body: some View {
    VStack(alignment: .leading, spacing: Roll.Space.xs) {
      if onDevice > 0 {
        // A non-breaking space keeps "49.6 MB" together when the headline wraps.
        Text("You can free about \(ByteFormat.short(onDevice).replacingOccurrences(of: " ", with: "\u{00A0}")) on this iPhone")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      } else {
        Text(inCloud > 0 ? "Nothing confirmed on this iPhone yet" : "Nothing big to free yet")
          .rollTitle(Roll.Typeface.display, tracking: Roll.Typeface.displayTracking)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityAddTraits(.isHeader)
      }
      if inCloud > 0 {
        Text("Plus \(ByteFormat.about(inCloud)) in iCloud or not checked yet")
          .font(Roll.Typeface.subhead)
          .foregroundStyle(.rollInk2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Assets analysed from small previews (their originals are in iCloud), and the opt-in to use full images instead.
struct ICloudOption: View {
  @Environment(AppModel.self) private var app

  var body: some View {
    @Bindable var app = app
    if app.previewCount > 0 || app.improveWithICloud {
      VStack(alignment: .leading, spacing: Roll.Space.xs) {
        RollGroup {
          Toggle(isOn: $app.improveWithICloud) {
            Text("Improve with iCloud originals").font(Roll.Typeface.headline).foregroundStyle(.rollInk)
          }
          .tint(.rollInk)
          .padding(.horizontal, Roll.Space.m)
          .frame(minHeight: 56)
        }
        Text("\(app.previewCount.formatted()) \(app.previewCount == 1 ? "item was" : "items were") checked from a small preview because \(app.previewCount == 1 ? "its original is" : "their originals are") in iCloud. When this is on, Roll downloads them to check again, only on Wi-Fi while your iPhone is charging.")
          .font(Roll.Typeface.caption)
          .foregroundStyle(.rollInk3)
          .padding(.horizontal, Roll.Space.xxs)
      }
    }
  }
}
