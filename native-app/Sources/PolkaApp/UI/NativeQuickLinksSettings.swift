import PolkaCore
import SwiftUI

struct NativeQuickLinksSettings: View {
  @ObservedObject var model: NativeUIModel
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      NativeErrorNotice(text: model.error)
      if model.quickLinksStorageError {
        NativeErrorNotice(text: localized("Could not load saved links."))
      } else if let draft = model.quickLinkDraft {
        NativeErrorNotice(text: draft.error)
        editor(isNew: draft.id == nil)
      } else {
        actions
        if model.quickLinks.isEmpty {
          Text(localized("No saved links.")).font(.system(size: 13)).foregroundStyle(.secondary)
          Spacer(minLength: 0)
        } else {
          List(model.quickLinks, selection: $model.selectedQuickLinkID) { link in
            VStack(alignment: .leading, spacing: 4) {
              Text(link.name).font(.system(size: 13)).lineLimit(1)
              Text(link.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            }.padding(.vertical, 4).tag(link.id)
          }.listStyle(.bordered).disabled(!model.canManageQuickLinks)
            .accessibilityLabel(localized("Quick Links"))
        }
      }
    }.frame(maxHeight: .infinity, alignment: .topLeading)
  }

  private var actions: some View {
    HStack(spacing: 8) {
      NativeCommandButton(
        title: localized("Add Link"), symbol: "plus", shortcut: "⌘N",
        disabled: !model.canManageQuickLinks, prominent: true
      ) { model.addQuickLink() }.accessibilityIdentifier("quick-link-add")
      Spacer(minLength: 0)
      NativeCommandButton(
        title: localized("Edit Link"), shortcut: "⌘E", disabled: !model.canChangeSelectedQuickLink
      ) { model.editQuickLink() }.accessibilityIdentifier("quick-link-edit")
      NativeCommandButton(
        title: localized("Delete"), shortcut: "⌘⌫", disabled: !model.canChangeSelectedQuickLink,
        destructive: true
      ) { model.deleteQuickLink() }.accessibilityIdentifier("quick-link-delete")
    }
  }

  private func editor(isNew: Bool) -> some View {
    ScrollView {
      NativeSettingsGroup(isNew ? localized("Add Link") : localized("Edit Link")) {
        VStack(alignment: .leading, spacing: 5) {
          Text(localized("Name")).font(.system(size: 12))
          TextField(
            localized("Name"),
            text: Binding(
              get: { model.quickLinkDraft?.name ?? "" }, set: { model.quickLinkDraft?.name = $0 }),
            prompt: Text(verbatim: "")
          ).focused($nameFocused).accessibilityIdentifier("quick-link-name")
            .task {
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
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          NativeCommandButton(
            title: localized("Cancel"), shortcut: "Esc", disabled: !model.canManageQuickLinks
          ) { model.cancelQuickLinkEdit() }
          NativeCommandButton(
            title: localized("Save"), shortcut: "⌘↵", disabled: !model.canManageQuickLinks,
            prominent: true
          ) { model.saveQuickLink() }.accessibilityIdentifier("quick-link-save")
        }
      }.textFieldStyle(.roundedBorder).disabled(model.busy)
    }
  }
}

extension NativeUIModel {
  var canManageQuickLinks: Bool {
    settingsPane == "quick-links" && !busy && !commandPending && !quickLinksStorageError
  }

  private var selectedQuickLink: QuickLink? {
    quickLinks.first { $0.id == selectedQuickLinkID }
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
    ) { [weak self] in self?.quickLinkDraft = nil }
  }

  func deleteQuickLink() {
    guard canChangeSelectedQuickLink, let link = selectedQuickLink else { return }
    perform(NativeUICommand("quickLinks.delete", strings: ["id": link.id.uuidString]))
  }
}
