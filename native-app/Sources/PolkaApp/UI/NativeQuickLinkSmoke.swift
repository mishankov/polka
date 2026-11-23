import AppKit

@MainActor func nativeQuickLinksSmoke(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel, platform: NativePlatform,
  post: (UInt16, NSEvent.ModifierFlags, String, Bool, NSWindow?) -> Void,
  wait: (() -> Bool) async -> Bool,
  screenshot: (String, NSWindow?, Bool) async -> Void,
  clickResult: (String) async -> Bool
) async -> String? {
  let previousPane = model.settingsPane
  let originalOpener = platform.openQuickLink
  let originalLinks = model.quickLinks
  var opened: [URL] = []
  var canOpen = false
  platform.openQuickLink = { url in
    opened.append(url)
    return canOpen
  }
  application.openSettings("quick-links")
  guard await wait({ NSApp.keyWindow?.identifier?.rawValue == "polka-settings" }),
    let settings = NSApp.keyWindow
  else {
    platform.openQuickLink = originalOpener
    model.settingsPane = previousPane
    return "Quick Links Settings did not become the active window"
  }
  defer {
    settings.close()
    model.settingsPane = previousPane
    model.error = ""
    platform.openQuickLink = originalOpener
  }
  guard await nativeSmokeWaitForView(in: settings, ofType: NSTableView.self) != nil else {
    return "Quick Links Settings did not finish layout"
  }
  func fieldEditor() -> NSTextView? {
    guard let editor = settings.firstResponder as? NSTextView, editor.isEditable else {
      return nil
    }
    return editor
  }
  let name = "Staging Dashboard"
  let invalidURL = "https://example.invalid:65536"
  let destination = "https://example.invalid/staging"
  post(45, .command, "т", false, settings)
  guard await wait({ model.quickLinkDraft != nil }) else {
    return "Command N did not open the Quick Link editor"
  }
  guard await wait({ fieldEditor() != nil }), let nameEditor = fieldEditor() else {
    return
      "Quick Link editor did not focus the name field: \(String(describing: settings.firstResponder))"
  }
  nameEditor.insertText(name, replacementRange: nameEditor.selectedRange())
  guard await wait({ model.quickLinkDraft?.name == name }) else {
    return "Quick Link name field did not update its draft"
  }
  post(48, [], "\t", false, settings)
  guard await wait({ fieldEditor()?.string == "" }), let urlEditor = fieldEditor() else {
    return "Tab did not move from the Quick Link name to the URL field"
  }
  urlEditor.insertText(invalidURL, replacementRange: urlEditor.selectedRange())
  guard await wait({ model.quickLinkDraft?.url == invalidURL }) else {
    return "Quick Link URL field did not update its draft"
  }
  post(36, .command, "\r", false, settings)
  guard await wait({ model.quickLinkDraft?.error.isEmpty == false && !model.busy }),
    model.error.isEmpty,
    model.quickLinks == originalLinks, model.quickLinkDraft?.name == name,
    model.quickLinkDraft?.url == invalidURL, let correctionEditor = fieldEditor()
  else {
    return
      "Command Return did not preserve the Quick Link draft on URL validation failure"
  }
  correctionEditor.insertText(
    destination, replacementRange: NSRange(location: 0, length: (invalidURL as NSString).length))
  guard await wait({ model.quickLinkDraft?.url == destination }) else {
    return "Quick Link URL could not be corrected in the active editor"
  }
  post(36, .command, "\r", false, settings)
  guard await wait({ model.quickLinkDraft == nil && !model.busy }),
    let link = model.quickLinks.first(where: { $0.name == name }),
    link.url.absoluteString == destination, model.selectedQuickLinkID == link.id
  else {
    return "Command Return did not save and select the new Quick Link"
  }
  post(51, .command, "", true, settings)
  post(14, .command, "у", false, settings)
  guard await wait({ model.quickLinkDraft?.id == link.id && fieldEditor()?.string == name }),
    let editName = fieldEditor()
  else {
    return
      "Command E did not edit the selected Quick Link after repeated Command Delete"
  }
  let editedName = "Team Dashboard"
  editName.insertText(
    editedName, replacementRange: NSRange(location: 0, length: (name as NSString).length))
  guard await wait({ model.quickLinkDraft?.name == editedName }) else {
    return "Quick Link edit did not update the display name"
  }
  await screenshot("settings-quick-link-editor", settings, true)
  post(36, .command, "\r", false, settings)
  guard await wait({ model.quickLinkDraft == nil && !model.busy }),
    model.quickLinks.contains(where: { $0.id == link.id && $0.name == editedName })
  else {
    return "Command Return did not save changes to the selected Quick Link"
  }
  settings.close()
  await application.show("apps")
  guard
    let search = await nativeSmokeWaitForView(
      in: shelf, ofType: NSSearchField.self, ready: { $0.currentEditor() != nil }),
    let searchEditor = search.currentEditor() as? NSTextView
  else {
    return "Shelf search did not receive keyboard focus for Quick Links"
  }
  searchEditor.insertText(editedName, replacementRange: searchEditor.selectedRange())
  let resultID = "quick-link:" + link.id.uuidString
  guard
    await wait({
      model.query == editedName && model.selectedSearch?.id == resultID
        && model.selectedSearch?.kind == "quick-link"
    })
  else {
    return "Searching by the edited display name did not select a Quick Link result"
  }
  await screenshot("launcher-quick-link", nil, false)
  post(36, [], "\r", false, nil)
  guard await wait({ opened == [link.url] && !model.error.isEmpty && !model.busy }),
    model.visible
  else {
    return "Return did not show the Quick Link open failure on the shelf"
  }
  canOpen = true
  post(36, [], "\r", false, nil)
  guard await wait({ opened == [link.url, link.url] && !model.visible && !model.busy }) else {
    return "Return did not open the saved Quick Link and close the shelf"
  }
  await application.show("apps", query: editedName)
  guard await clickResult("result-\(resultID)") else {
    return "Quick Link result was missing from the reopened shelf"
  }
  guard await wait({ opened == [link.url, link.url, link.url] && !model.visible && !model.busy })
  else {
    return "Clicking the Quick Link did not open the same destination as Return"
  }
  application.openSettings("quick-links")
  guard await wait({ settings.isKeyWindow && model.selectedQuickLinkID == link.id }) else {
    return "Reopening Quick Links Settings did not restore the selected link"
  }
  post(51, .command, "", false, settings)
  if !(await wait({ model.quickLinks == originalLinks && !model.busy })) {
    return "Command Delete did not remove the selected Quick Link"
  }
  return nil
}
