import PolkaCore
import SwiftUI

struct NativeQuickLinksView: View {
  @ObservedObject var model: NativeUIModel
  @Environment(\.shelfColors) private var colors
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      NativeBuiltinHeader(
        model: model,
        title: model.quickLinkDraft.map {
          $0.id == nil ? localized("Add Link") : localized("Edit Link")
        } ?? localized("Quick Links")
      ) {
        if model.quickLinkDraft == nil {
          NativeCommandButton(
            title: localized("Create"), symbol: "plus", shortcut: "⌘N",
            disabled: !model.canManageQuickLinks, prominent: true
          ) { model.addQuickLink() }.accessibilityIdentifier("quick-link-add")
        }
      }
      if model.quickLinkDraft == nil, !model.quickLinksStorageError {
        NativeBuiltinSearch(model: model, placeholder: localized("Find a link…"))
      }
      Divider()
      NativeErrorNotice(text: model.error).padding(.horizontal, 10)
      if model.quickLinksStorageError {
        NativeErrorNotice(text: localized("Could not load saved links.")).padding(.horizontal, 10)
        Spacer(minLength: 0)
      } else if let draft = model.quickLinkDraft {
        NativeErrorNotice(text: draft.error).padding(.horizontal, 10)
        editor
        Divider()
        editorActions
      } else {
        if model.quickLinkResults.isEmpty {
          Text(
            model.query.isEmpty
              ? localized("No saved links.") : localized("Nothing found. Try another word.")
          )
          .font(.system(size: 13)).nativeShelfSecondary().padding(24)
          Spacer(minLength: 0)
        } else {
          linkList
        }
        Divider()
        listActions
      }
    }.accessibilityElement(children: .contain).accessibilityIdentifier("native-quick-links")
  }

  private var linkList: some View {
    ScrollViewReader { reader in
      List(
        model.quickLinkResults,
        selection: Binding(
          get: { model.selectedQuickLink?.id }, set: { model.selectedQuickLinkID = $0 })
      ) { link in
        HStack(spacing: 10) {
          Image(systemName: "link").nativeShelfSecondary().accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(link.displayName).font(.system(size: 13)).lineLimit(1)
              .truncationMode(link.name.isEmpty ? .middle : .tail)
            if !link.name.isEmpty {
              Text(link.url.absoluteString).font(.system(size: 11)).nativeShelfSecondary()
                .lineLimit(1).truncationMode(.middle)
            }
          }
        }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
          .nativeShelfRow(
            selected: colors != nil && model.selectedQuickLink?.id == link.id, defaultOpacity: 0
          ).tag(link.id).id(link.id)
      }.listStyle(.plain).scrollContentBackground(.hidden)
        .tint(colors?.selectionColor)
        .disabled(!model.canManageQuickLinks).accessibilityLabel(localized("Quick Links"))
        .onChange(of: model.selectedQuickLinkID) { _, id in if let id { reader.scrollTo(id) } }
    }
  }

  private var listActions: some View {
    NativeToolbar {
      NativeCommandButton(
        title: localized("Edit Link"), shortcut: "⌘E", disabled: !model.canChangeSelectedQuickLink
      ) { model.editQuickLink() }.accessibilityIdentifier("quick-link-edit")
      NativeCommandButton(
        title: localized("Delete"), shortcut: "⌘⌫", disabled: !model.canChangeSelectedQuickLink,
        destructive: true
      ) { model.deleteQuickLink() }.accessibilityIdentifier("quick-link-delete")
      Spacer(minLength: 0)
      NativeCommandButton(
        title: localized("Open Link"), shortcut: "↵",
        disabled: !model.canChangeSelectedQuickLink, prominent: true
      ) { model.openSelectedQuickLink() }.accessibilityIdentifier("quick-link-open")
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 5) {
        Text(localized("Name (optional)")).font(.system(size: 12))
        TextField(
          localized("Name (optional)"),
          text: Binding(
            get: { model.quickLinkDraft?.name ?? "" }, set: { model.quickLinkDraft?.name = $0 }),
          prompt: Text(verbatim: "")
        ).focused($nameFocused).accessibilityIdentifier("quick-link-name")
          .task(id: model.visible ? model.sessionRevision : nil) {
            nameFocused = false
            guard model.visible else { return }
            await Task.yield()
            if !Task.isCancelled { nameFocused = true }
          }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text(localized("URL")).font(.system(size: 12))
        TextField(
          localized("URL"),
          text: Binding(
            get: { model.quickLinkDraft?.url ?? "" }, set: { model.quickLinkDraft?.url = $0 }),
          prompt: Text(verbatim: "https://example.com")
        ).accessibilityIdentifier("quick-link-url")
      }
    }.textFieldStyle(.roundedBorder).disabled(model.busy).padding(12)
      .frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var editorActions: some View {
    NativeToolbar {
      Spacer(minLength: 0)
      NativeCommandButton(
        title: localized("Cancel"), shortcut: "Esc", disabled: !model.canManageQuickLinks
      ) { model.back() }
      NativeCommandButton(
        title: localized("Save"), shortcut: "⌘↵", disabled: !model.canManageQuickLinks,
        prominent: true
      ) { model.saveQuickLink() }.accessibilityIdentifier("quick-link-save")
    }
  }
}

extension NativeUIModel {
  var canManageQuickLinks: Bool {
    visible && destination == "quick-links" && settings.builtinApps.allows(destination: destination)
      && !busy && !commandPending && !quickLinksStorageError
  }

  var quickLinkResults: [QuickLink] {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !search.isEmpty else { return quickLinks }
    return quickLinks.filter { $0.displayName.localizedStandardContains(search) }
  }

  var selectedQuickLinkID: UUID? {
    get { selectedID.flatMap(UUID.init(uuidString:)) }
    set { selectedID = newValue?.uuidString }
  }

  var selectedQuickLink: QuickLink? {
    let links = quickLinkResults
    return links.first { $0.id == selectedQuickLinkID } ?? links.first
  }

  func moveQuickLinkSelection(by offset: Int) {
    let links = quickLinkResults
    guard !links.isEmpty else { return }
    let current = links.firstIndex { $0.id == selectedQuickLinkID } ?? 0
    selectedQuickLinkID = links[min(max(current + offset, 0), links.count - 1)].id
  }

  var canChangeSelectedQuickLink: Bool {
    canManageQuickLinks && quickLinkDraft == nil && selectedQuickLink != nil
  }

  func addQuickLink() {
    guard canManageQuickLinks, quickLinkDraft == nil, nativeCommandInteractionAllowed else {
      return
    }
    error = ""
    quickLinkDraft = NativeQuickLinkDraft()
  }

  func editQuickLink() {
    guard canChangeSelectedQuickLink, let link = selectedQuickLink, nativeCommandInteractionAllowed
    else { return }
    error = ""
    quickLinkDraft = NativeQuickLinkDraft(
      id: link.id, name: link.name, url: link.url.absoluteString)
  }

  func cancelQuickLinkEdit() {
    guard canManageQuickLinks, quickLinkDraft != nil, nativeCommandInteractionAllowed else {
      return
    }
    error = ""
    quickLinkDraft = nil
  }

  func saveQuickLink() {
    guard canManageQuickLinks, let draft = quickLinkDraft else { return }
    quickLinkDraft?.error = ""
    perform(
      NativeUICommand(
        "quickLinks.save",
        strings: [
          "id": draft.id?.uuidString ?? "", "name": draft.name, "url": draft.url,
        ])
    ) { [weak self] in
      guard let self else { return }
      quickLinkDraft = nil
      if let savedID = selectedQuickLinkID, !quickLinkResults.contains(where: { $0.id == savedID })
      {
        query = ""
        selectedQuickLinkID = savedID
      }
    }
  }

  func deleteQuickLink() {
    guard canChangeSelectedQuickLink, let link = selectedQuickLink,
      let index = quickLinkResults.firstIndex(where: { $0.id == link.id })
    else { return }
    perform(NativeUICommand("quickLinks.delete", strings: ["id": link.id.uuidString])) {
      [weak self] in
      guard let self else { return }
      let remaining = quickLinkResults
      selectedQuickLinkID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
  }

  func openSelectedQuickLink() {
    guard canChangeSelectedQuickLink, let link = selectedQuickLink else { return }
    perform(NativeUICommand("quickLinks.open", strings: ["id": link.resultID]))
  }
}
