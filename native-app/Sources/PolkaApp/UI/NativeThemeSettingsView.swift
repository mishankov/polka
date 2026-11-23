import AppKit
import PolkaCore
import SwiftUI

enum NativeThemeFilter: String, CaseIterable, Identifiable {
  case all, popular, neutral, vibrant, pastel, custom

  var id: Self { self }
  var label: String {
    switch self {
    case .all: localized("All")
    case .popular: localized("Popular")
    case .neutral: localized("Neutral")
    case .vibrant: localized("Vibrant")
    case .pastel: localized("Pastel")
    case .custom: localized("My Themes")
    }
  }
  var category: NativeThemeCategory? { NativeThemeCategory(rawValue: rawValue) }

  func themes(in settings: NativeThemeSettings) -> [NativeShelfTheme] {
    category?.themes ?? settings.custom
  }

  static func overviewSections(in settings: NativeThemeSettings) -> [Self] {
    allCases.filter { $0.category != nil || ($0 == .custom && !settings.custom.isEmpty) }
  }
}

struct NativeThemeDraft {
  let source: NativeShelfTheme
  let existing: Bool
  var name: String
  var colors: NativeThemeColors

  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var hasValidName: Bool {
    !trimmedName.isEmpty && trimmedName.count <= NativeThemeSettings.maxNameLength
  }

  func hasDuplicateName(in themes: NativeThemeSettings) -> Bool {
    !themes.canUseName(trimmedName, editingCustomTheme: existing ? source.id : "")
  }

  func canSave(in themes: NativeThemeSettings) -> Bool {
    hasValidName && colors.isValid && !hasDuplicateName(in: themes)
  }

  var preview: NativeThemeColors {
    var preview = source.colors
    for role in NativeThemeColorRole.allCases {
      let key = role.key
      if let hex = NativeThemeColors.normalizedHex(colors[keyPath: key]) {
        preview[keyPath: key] = hex
      } else if role == .detailAccent, colors.detailAccent == nil {
        preview.detailAccent = nil
      }
    }
    return preview
  }
}

enum NativeThemeColorRole: String, CaseIterable, Identifiable {
  case background, surface, text, accent, selection, detailAccent

  var id: Self { self }
  var label: String {
    switch self {
    case .background: localized("Shelf Background")
    case .surface: localized("Raised Surface")
    case .text: localized("Text")
    case .accent: localized("Accent")
    case .selection: localized("Selection")
    case .detailAccent: localized("Detail Accent")
    }
  }
  var key: WritableKeyPath<NativeThemeColors, String> {
    switch self {
    case .background: \.background
    case .surface: \.surface
    case .text: \.text
    case .accent: \.accent
    case .selection: \.selection
    case .detailAccent: \.detailAccentInput
    }
  }
}

extension NativeThemeColors {
  fileprivate var detailAccentInput: String {
    get { detailAccent ?? "" }
    set { detailAccent = newValue.isEmpty ? nil : newValue }
  }
}

extension NativeUIModel {
  var themeActionsAvailable: Bool {
    action != nil && !busy && !commandPending && nativeCommandInteractionAllowed
      && !NSMenuTrackingState.shared.active
  }

  func selectTheme(_ id: String) {
    guard themeActionsAvailable, themeDraft == nil, themePendingDeletion == nil,
      id != settings.themes.activeID
    else { return }
    perform(NativeUICommand("theme.select", strings: ["id": id]))
  }

  func editTheme() {
    guard themeActionsAvailable, themeDraft == nil, themePendingDeletion == nil else { return }
    let theme = settings.themes.active
    let existing = settings.themes.custom.contains { $0.id == theme.id }
    error = ""
    themeDraft = NativeThemeDraft(
      source: theme, existing: existing,
      name: existing ? theme.name : settings.themes.copyName(for: theme), colors: theme.colors)
  }

  func saveTheme() {
    guard themeActionsAvailable, let draft = themeDraft, draft.canSave(in: settings.themes)
    else { return }
    var values = ["id": draft.existing ? draft.source.id : "", "name": draft.name]
    for role in NativeThemeColorRole.allCases {
      values[role.rawValue] = draft.colors[keyPath: role.key]
    }
    perform(NativeUICommand("theme.save", strings: values)) { [weak self] in
      self?.themeDraft = nil
      self?.themeFilter = .custom
    }
  }

  func duplicateTheme() {
    guard themeActionsAvailable, themeDraft == nil, themePendingDeletion == nil else { return }
    perform(NativeUICommand("theme.duplicate", strings: ["id": settings.themes.activeID])) {
      [weak self] in self?.themeFilter = .custom
    }
  }

  func requestThemeDeletion() {
    guard themeActionsAvailable, themeDraft == nil, themePendingDeletion == nil,
      let theme = settings.themes.custom.first(where: { $0.id == settings.themes.activeID })
    else { return }
    error = ""
    themePendingDeletion = theme
  }

  func deleteTheme() {
    guard themeActionsAvailable, let theme = themePendingDeletion else { return }
    perform(NativeUICommand("theme.delete", strings: ["id": theme.id])) { [weak self] in
      self?.themePendingDeletion = nil
    }
  }

  func cancelThemeChanges() {
    guard themeActionsAvailable else { return }
    error = ""
    themeDraft = nil
    themePendingDeletion = nil
  }

  func handleThemeShortcut(_ key: NativeKeyInput, flags: NSEvent.ModifierFlags) -> Bool {
    let action: () -> Void
    switch (flags, key.code) {
    case (.command, 1) where themeDraft != nil: action = saveTheme
    case (.command, 14) where themeDraft == nil && themePendingDeletion == nil: action = editTheme
    case (.command, 2) where themeDraft == nil && themePendingDeletion == nil:
      action = duplicateTheme
    case (.command, 51) where themePendingDeletion != nil: action = deleteTheme
    case (.command, 51) where themeDraft == nil: action = requestThemeDeletion
    case ([], 53) where themeDraft != nil || themePendingDeletion != nil:
      action = cancelThemeChanges
    default: return false
    }
    if !key.repeatKey { action() }
    return true
  }
}

struct NativeThemeGalleryActions: View {
  @ObservedObject var model: NativeUIModel

  var body: some View {
    let active = model.settings.themes.active
    let isCustom = model.settings.themes.custom.contains { $0.id == active.id }
    HStack(spacing: 8) {
      NativeCommandButton(
        title: isCustom ? localized("Edit Theme…") : localized("Customize…"),
        symbol: "pencil", shortcut: "⌘E", disabled: !model.themeActionsAvailable
      ) { model.editTheme() }.accessibilityIdentifier("theme-customize")
      NativeIconButton(
        label: localized("Duplicate Theme"), symbol: "plus.square.on.square", shortcut: "⌘D",
        disabled: !model.themeActionsAvailable
      ) { model.duplicateTheme() }
      if isCustom {
        NativeIconButton(
          label: localized("Delete Theme…"), symbol: "trash", shortcut: "⌘⌫",
          disabled: !model.themeActionsAvailable
        ) { model.requestThemeDeletion() }
      }
    }.accessibilityElement(children: .contain)
  }
}

struct NativeThemeSettingsView: View {
  @ObservedObject var model: NativeUIModel
  @FocusState private var focusedCard: String?

  private let cardSpacing: CGFloat = 8
  private let minimumCardWidth: CGFloat = 140

  var body: some View {
    if let draft = model.themeDraft {
      NativeThemeEditor(model: model, draft: draft)
    } else if let theme = model.themePendingDeletion {
      VStack(alignment: .leading, spacing: 12) {
        Text(localized("Delete “{0}”?", theme.name)).font(.system(size: 15, weight: .semibold))
        Text(localized("The shelf will switch to Polka.")).foregroundStyle(.secondary)
        HStack {
          NativeCommandButton(
            title: localized("Cancel"), shortcut: "esc", disabled: !model.themeActionsAvailable
          ) { model.cancelThemeChanges() }
          NativeCommandButton(
            title: localized("Delete Theme"), shortcut: "⌘⌫",
            disabled: !model.themeActionsAvailable,
            destructive: true
          ) { model.deleteTheme() }
        }
      }
    } else {
      gallery
    }
  }

  private var gallery: some View {
    VStack(alignment: .leading, spacing: 16) {
      ViewThatFits(in: .horizontal) {
        categoryPicker.pickerStyle(.segmented).controlSize(.small).labelsHidden().fixedSize(
          horizontal: true, vertical: false
        )
        .accessibilityIdentifier("theme-category-segments")
        categoryPicker.pickerStyle(.menu)
          .accessibilityIdentifier("theme-category-menu")
      }
      if model.themeFilter == .all {
        ForEach(NativeThemeFilter.overviewSections(in: model.settings.themes)) {
          section($0, overview: true)
        }
      } else {
        section(model.themeFilter, overview: false)
      }
    }.accessibilityIdentifier("themes-gallery")
  }

  private var categoryPicker: some View {
    Picker(localized("Theme category"), selection: $model.themeFilter) {
      ForEach(NativeThemeFilter.allCases) { filter in Text(filter.label).tag(filter) }
    }
  }

  private func section(_ filter: NativeThemeFilter, overview: Bool) -> some View {
    let themes = filter.themes(in: model.settings.themes)
    return VStack(alignment: .leading, spacing: 7) {
      if overview {
        Text(filter.label).font(.system(size: 13, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        themeRow(themes, label: filter.label)
      } else if themes.isEmpty {
        Text(localized("Customize a theme to add it here.")).foregroundStyle(.secondary)
      } else {
        LazyVGrid(
          columns: [
            GridItem(.adaptive(minimum: minimumCardWidth), spacing: cardSpacing, alignment: .top)
          ], spacing: cardSpacing
        ) {
          ForEach(themes) { theme in card(theme) }
        }
      }
    }
  }

  private func themeRow(_ themes: [NativeShelfTheme], label: String) -> some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: cardSpacing) {
          ForEach(Array(themes.enumerated()), id: \.element.id) { index, theme in
            card(theme)
              .containerRelativeFrame(.horizontal) { width, _ in
                let count = max(1, Int((width + cardSpacing) / (minimumCardWidth + cardSpacing)))
                return (width - CGFloat(count - 1) * cardSpacing) / CGFloat(count)
              }
              .id(theme.id)
              .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                guard press.modifiers.isEmpty else { return .ignored }
                let target = index + (press.key == .leftArrow ? -1 : 1)
                if themes.indices.contains(target) { focusedCard = themes[target].id }
                return .handled
              }
          }
        }
        .padding(.top, 2)
        .padding(.bottom, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) + 2)
      }
      .accessibilityLabel(label)
      .onChange(of: focusedCard) { _, id in
        if let id, themes.contains(where: { $0.id == id }) {
          proxy.scrollTo(id)
        }
      }
    }
  }

  private func card(_ theme: NativeShelfTheme) -> some View {
    let active = theme.id == model.settings.themes.activeID
    let focused = theme.id == focusedCard
    return Button {
      model.selectTheme(theme.id)
    } label: {
      VStack(alignment: .leading, spacing: 5) {
        NativeThemeShelfPreview(colors: theme.colors, compact: true)
        HStack {
          Text(theme.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
          Spacer(minLength: 0)
          if active {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
          }
        }.padding(.horizontal, 3).frame(minHeight: 17)
      }.padding(4)
        .background(
          active ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 8).strokeBorder(
            active || focused ? Color.accentColor : Color(nsColor: .separatorColor),
            lineWidth: focused ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain)
      .focusable()
      .focused($focusedCard, equals: theme.id)
      .onKeyPress(keys: [.return], phases: .down) { press in
        guard press.modifiers.isEmpty else { return .ignored }
        model.selectTheme(theme.id)
        return .handled
      }
      .disabled(!model.themeActionsAvailable)
      .help(theme.name + " · ↵")
      .accessibilityLabel(theme.name)
      .accessibilityAddTraits(active ? .isSelected : [])
      .accessibilityHint(localized("Apply Theme"))
      .accessibilityCustomContent(Text(localized("Keyboard shortcut")), Text("↵"))
      .accessibilityIdentifier("theme-card-\(theme.id)")
  }
}

private struct NativeThemeEditor: View {
  @ObservedObject var model: NativeUIModel
  var draft: NativeThemeDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(
        draft.existing
          ? localized("Edit {0}", draft.source.name) : localized("Customize {0}", draft.source.name)
      ).font(.system(size: 17, weight: .semibold))
        .lineLimit(2).accessibilityAddTraits(.isHeader)
      nameField
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 18) {
          fields.frame(minWidth: 222)
          preview.frame(minWidth: 200)
        }
        VStack(alignment: .leading, spacing: 14) {
          fields
          preview
        }
      }
    }.accessibilityIdentifier("theme-editor")
  }

  private var nameField: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Text(localized("Theme Name")).font(.system(size: 12, weight: .semibold))
        NativeThemeNameField(
          text: Binding(
            get: { model.themeDraft?.name ?? "" },
            set: { model.themeDraft?.name = $0 }
          )
        ).frame(height: 24)
      }
      if !draft.hasValidName {
        Text(localized("Enter a theme name of up to 35 characters."))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      } else if draft.hasDuplicateName(in: model.settings.themes) {
        Text(localized("A theme with this name already exists."))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.disabled(!model.themeActionsAvailable)
  }

  private var fields: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(localized("Colors")).font(.system(size: 12, weight: .semibold))
      ForEach(NativeThemeColorRole.allCases) { role in
        Divider()
        colorRow(role)
      }
    }.disabled(!model.themeActionsAvailable)
  }

  private func colorRow(_ role: NativeThemeColorRole) -> some View {
    let key = role.key
    let raw = draft.colors[keyPath: key]
    let optional = role == .detailAccent
    let hexValid = (optional && raw.isEmpty) || NativeThemeColors.normalizedHex(raw) != nil
    return HStack(spacing: 6) {
      Text(role.label).font(.system(size: 12))
      Spacer(minLength: 4)
      ColorPicker(
        role.label,
        selection: Binding(
          get: {
            let preview = draft.preview
            if optional, preview.detailAccent == nil { return preview.detailForeground() }
            return Color(nsColor: NativeThemeColors.appKitColor(preview[keyPath: key]))
          },
          set: { newColor in
            guard let color = NSColor(newColor).usingColorSpace(.sRGB) else { return }
            let hex = String(
              format: "#%02X%02X%02X",
              UInt32((max(0, min(1, color.redComponent)) * 255).rounded()),
              UInt32((max(0, min(1, color.greenComponent)) * 255).rounded()),
              UInt32((max(0, min(1, color.blueComponent)) * 255).rounded()))
            model.themeDraft?.colors[keyPath: key] = hex
          }
        ), supportsOpacity: false
      ).labelsHidden().controlSize(.small)
        .accessibilityLabel(role.label)
      TextField(
        localized("{0} hex color", role.label),
        text: Binding(
          get: { model.themeDraft?.colors[keyPath: key] ?? "" },
          set: { model.themeDraft?.colors[keyPath: key] = String($0.prefix(24)) }
        ),
        prompt: optional ? Text(localized("Automatic")) : nil
      ).labelsHidden().textFieldStyle(.roundedBorder)
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 76)
        .foregroundStyle(hexValid ? Color.primary : Color(nsColor: .systemRed))
        .accessibilityIdentifier("theme-hex-\(role.rawValue)")
    }
  }

  private var preview: some View {
    let colors = draft.preview
    let readable = colors.textContrastRatio >= 4.5
    return VStack(alignment: .leading, spacing: 7) {
      Text(localized("Live Preview")).font(.system(size: 12, weight: .semibold))
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
          .fill(.black).frame(width: 46, height: 9)
        NativeThemeShelfPreview(colors: colors, compact: false)
      }.padding([.horizontal, .bottom], 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      if !draft.colors.isValid {
        Label(
          localized("Enter six-digit hex colors. Detail Accent can be blank."),
          systemImage: "exclamationmark.circle"
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
      } else {
        Label(
          readable
            ? localized("Text contrast passes")
            : localized("Low contrast. Try a different text color."),
          systemImage: readable ? "checkmark" : "exclamationmark.triangle"
        ).font(.system(size: 11))
          .foregroundStyle(readable ? Color.secondary : Color(nsColor: .systemOrange))
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct NativeThemeNameField: NSViewRepresentable {
  @Binding var text: String
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> NSTextField {
    let field = NameField(string: text)
    field.bezelStyle = .roundedBezel
    field.font = .systemFont(ofSize: 13)
    field.cell?.usesSingleLineMode = true
    field.identifier = NSUserInterfaceItemIdentifier("theme-name")
    field.setAccessibilityIdentifier("theme-name")
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    field.delegate = context.coordinator
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.text = $text
    field.setAccessibilityLabel(localized("Theme Name"))
    field.isEnabled = isEnabled
    if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
      field.stringValue = text
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    init(text: Binding<String>) { self.text = text }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField,
        (field.currentEditor() as? NSTextView)?.hasMarkedText() != true
      else { return }
      text.wrappedValue = field.stringValue
    }
  }

  private final class NameField: NSTextField {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window, window.isKeyWindow,
          window.attachedSheet == nil, self.isEnabled
        else { return }
        window.makeFirstResponder(self)
      }
    }
  }
}

struct NativeThemeEditorActions: View {
  @ObservedObject var model: NativeUIModel
  let draft: NativeThemeDraft

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      NativeErrorNotice(text: model.error)
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        NativeCommandButton(
          title: localized("Cancel"), shortcut: "esc", disabled: !model.themeActionsAvailable
        ) { model.cancelThemeChanges() }
        NativeCommandButton(
          title: localized("Save & Apply"), shortcut: "⌘S",
          disabled: !model.themeActionsAvailable || !draft.canSave(in: model.settings.themes),
          prominent: true
        ) { model.saveTheme() }.accessibilityIdentifier("theme-save")
      }
    }.accessibilityElement(children: .contain)
  }
}

struct NativeThemeShelfPreview: View {
  let colors: NativeThemeColors
  let compact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 4) {
        Image(systemName: "magnifyingglass")
        Text(localized("Find or calculate…")).lineLimit(1)
          .foregroundStyle(colors.secondaryTextColor)
        Spacer(minLength: 0)
      }.font(.system(size: compact ? 8 : 10))
        .padding(.horizontal, 6).padding(.vertical, compact ? 3 : 4)
        .background(colors.surfaceColor, in: Capsule())
        .overlay { Capsule().strokeBorder(colors.focusColor, lineWidth: 1) }
        .padding(compact ? 5 : 8)
        .background(colors.searchHeaderColor)
      VStack(alignment: .leading, spacing: compact ? 3 : 5) {
        Text(localized("Apps")).font(.system(size: compact ? 7 : 9, weight: .semibold))
          .foregroundStyle(colors.detailForeground()).padding(.horizontal, 4)
        row(
          "clipboard", localized("Clipboard History"), localized("Copied text and images"),
          shortcut: "⌘1", selected: true)
        if !compact {
          row(
            "face.smiling", localized("Emoji"), localized("Smileys, gestures, and symbols"),
            shortcut: "⌘2")
          row(
            "folder", localized("Files on the Shelf"), localized("Temporarily keep files"),
            shortcut: "⌘3")
        }
      }.padding(.horizontal, compact ? 5 : 8).padding(.bottom, compact ? 5 : 8)
        .padding(.top, compact ? 2 : 5)
    }
    .foregroundStyle(colors.textColor)
    .background(colors.backgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 10))
    .accessibilityHidden(true)
  }

  private func row(
    _ symbol: String, _ title: String, _ detail: String, shortcut: String, selected: Bool = false
  ) -> some View {
    HStack(spacing: compact ? 4 : 7) {
      Image(systemName: symbol).font(.system(size: compact ? 8 : 12))
        .foregroundStyle(colors.detailForeground(selected: selected))
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: compact ? 8 : 10, weight: .semibold)).lineLimit(1)
        Text(detail).font(.system(size: compact ? 7 : 9)).lineLimit(1)
          .foregroundStyle(colors.foreground(selected: selected, muted: true))
      }.frame(maxWidth: .infinity, alignment: .leading)
      if !compact {
        Text(shortcut).font(.system(size: 9))
          .foregroundStyle(colors.detailForeground(selected: selected))
      }
    }.padding(.horizontal, 4).padding(.vertical, compact ? 3 : 4)
      .foregroundStyle(selected ? colors.selectionTextColor : colors.textColor)
      .background(
        selected ? colors.selectionColor : .clear, in: RoundedRectangle(cornerRadius: 4)
      )
      .overlay {
        if selected, let outline = colors.selectionOutlineColor {
          RoundedRectangle(cornerRadius: 4).strokeBorder(outline)
        }
      }
  }
}
