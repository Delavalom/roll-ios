import PhotosUI
import Ranking
import Store
import SwiftUI

/// "New swipefile": a name, a plain-words description (one prompt per line), optional examples and the action.
struct NewSwipefileView: View {
  enum Action: String, CaseIterable, Identifiable {
    case delete = "Delete", album = "Move to album", squish = "Squish"
    var id: String { rawValue }
    var stored: SwipefileAction {
      switch self {
      case .delete: .delete
      case .album: .album
      case .squish: .squish
      }
    }
  }

  let onCreate: (SwipefileRecord) -> Void

  @Environment(AppModel.self) private var app
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""
  @State private var picked: [PhotosPickerItem] = []
  @State private var action: Action = .delete
  @State private var albumName = ""
  @State private var saving = false
  @State private var error: String?

  private var prompts: [String] {
    description.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  /// `itemIdentifier` is the asset's local identifier (the picker is bound to the shared library).
  private var examples: [String] { picked.compactMap(\.itemIdentifier) }

  private var canSave: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty && (!prompts.isEmpty || !examples.isEmpty) && !saving
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          SectionLabel("Name").padding(.bottom, Roll.Space.xs)
          TextField("Name", text: $name, prompt: Text("Tweets").foregroundStyle(.rollInk3))
            .textInputAutocapitalization(.words)
            .modifier(InputCard())

          SectionLabel("Describe what goes in this pile")
            .padding(.top, Roll.Space.l)
            .padding(.bottom, Roll.Space.xs)
          TextField("Describe what goes in this pile", text: $description,
                    prompt: Text("screenshots of tweets").foregroundStyle(.rollInk3), axis: .vertical)
            .lineLimit(3...6)
            .modifier(InputCard())
          footnote("Plain words work best. Put each idea on its own line.")

          SectionLabel("Examples")
            .padding(.top, Roll.Space.l)
            .padding(.bottom, Roll.Space.xs)
          examplesPicker
          footnote("Optional. A few photos that belong here help Roll find the rest.")

          SectionLabel("When you swipe left")
            .padding(.top, Roll.Space.l)
            .padding(.bottom, Roll.Space.xs)
          RollWrap {
            ForEach(Action.allCases) { option in
              RollChip(title: option.rawValue, isOn: action == option) {
                withAnimation(Roll.Motion.quick) { action = option }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("Action")
          if action == .album {
            TextField("Album name", text: $albumName, prompt: Text("Album name").foregroundStyle(.rollInk3))
              .modifier(InputCard())
              .padding(.top, Roll.Space.s)
              .transition(.opacity.combined(with: .offset(y: -6)))
          }

          if app.modelState != .ready {
            HStack(alignment: .top, spacing: Roll.Space.s) {
              RollIconTile(symbol: "sparkles")
              Text("This pile fills in once the on-device AI is ready.")
                .font(Roll.Typeface.subhead)
                .foregroundStyle(.rollInk2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            }
            .rollCard(padding: Roll.Space.s)
            .padding(.top, Roll.Space.xl)
          }
        }
        .padding(.horizontal, Roll.Space.page)
        .padding(.top, Roll.Space.s)
        .padding(.bottom, Roll.Space.xl)
        .animation(Roll.Motion.ease, value: action)
      }
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .bottom) {
        Button("Create") { Task { await save() } }
          .buttonStyle(.roll(.primary, fullWidth: true))
          .disabled(!canSave)
          .padding(.horizontal, Roll.Space.page)
          .padding(.top, Roll.Space.s)
          .padding(.bottom, Roll.Space.xs)
          .background(Roll.Palette.paper.ignoresSafeArea(edges: .bottom))
      }
      .rollPage()
      .navigationTitle("New swipefile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
      }
      .alert("Couldn't create it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(error ?? "")
      }
    }
  }

  /// "Pick examples" as a card row; once picked, the first few fanned out with the count.
  private var examplesPicker: some View {
    let pickerTitle = examples.isEmpty ? "Pick examples" : "\(examples.count) examples picked"
    return PhotosPicker(selection: $picked, maxSelectionCount: 20, matching: .any(of: [.images, .videos]),
                        photoLibrary: .shared()) {
      ExamplesLabel(ids: Array(examples.prefix(3)), title: pickerTitle)
    }
    .buttonStyle(PressScale())
    .accessibilityLabel(pickerTitle)
  }

  private func footnote(_ text: String) -> some View {
    Text(text)
      .font(Roll.Typeface.caption)
      .foregroundStyle(.rollInk3)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, Roll.Space.xxs)
      .padding(.top, Roll.Space.xs)
  }

  private func save() async {
    saving = true
    defer { saving = false }
    let album = albumName.trimmingCharacters(in: .whitespaces)
    do {
      let created = try await app.createSwipefile(
        name: name.trimmingCharacters(in: .whitespaces), prompts: prompts, examples: examples, action: action.stored,
        albumName: action == .album && !album.isEmpty ? album : nil)
      app.bumpLibrary()
      dismiss()
      onCreate(created)
    } catch {
      self.error = "Describe the pile or pick at least one example."
    }
  }
}

/// The examples picker's card: a symbol until something is picked, then the first few fanned out.
private struct ExamplesLabel: View {
  let ids: [String]
  let title: String

  var body: some View {
    HStack(spacing: Roll.Space.s) {
      if ids.isEmpty {
        RollIconTile(symbol: "photo.on.rectangle")
      } else {
        ThumbFan(ids: ids, side: 36)
      }
      Text(title).font(Roll.Typeface.headline).foregroundStyle(.rollInk)
      Spacer(minLength: Roll.Space.xs)
      Image(systemName: "chevron.right")
        .font(.footnote.weight(.bold))
        .foregroundStyle(.rollInk3)
        .accessibilityHidden(true)
    }
    .rollCard(padding: Roll.Space.s)
    .contentShape(RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
  }
}

/// A text input on a white card with a hairline, ember caret (the composer's look, as a rounded card).
private struct InputCard: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(Roll.Typeface.body)
      .foregroundStyle(.rollInk)
      .tint(.rollEmber)
      .padding(.horizontal, Roll.Space.m)
      .padding(.vertical, 14)
      .frame(minHeight: Roll.Size.control)
      .background(.rollCard, in: RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Roll.Radius.card, style: .continuous)
          .strokeBorder(.rollHairline, lineWidth: Roll.hairlineWidth)
      }
  }
}

#if DEBUG
#Preview {
  PreviewHost { NewSwipefileView { _ in } }
}
#endif
