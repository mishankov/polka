import AppKit

@MainActor func nativeQuickLinksSmoke(
  application: NativeApplication, shelf: NSWindow, model: NativeUIModel, platform: NativePlatform,
  post: (UInt16, NSEvent.ModifierFlags, String, Bool) -> Void,
  wait: (() -> Bool) async -> Bool,
  screenshot: (String) async -> Void,
  clickResult: (String) async -> Bool
) async -> String? {
  let originalOpener = platform.openQuickLink
  let originalLinks = model.quickLinks
  var opened: [URL] = []
  var canOpen = false
  platform.openQuickLink = { url in
    opened.append(url)
    return canOpen
  }
  defer {
    application.hide(force: true)
    model.error = ""
    platform.openQuickLink = originalOpener
  }
  func fieldEditor() -> NSTextView? {
    guard shelf.isKeyWindow, let editor = shelf.firstResponder as? NSTextView, editor.isEditable,
      !(editor.delegate is NSSearchField)
    else {
      return nil
    }
    return editor
  }
  func focusedSearchEditor() async -> NSTextView? {
    let search = await nativeSmokeWaitForView(
      in: shelf, ofType: NSSearchField.self,
      ready: { field in
        guard let editor = field.currentEditor() else { return false }
        return shelf.isKeyWindow && shelf.firstResponder === editor
      })
    return search?.currentEditor() as? NSTextView
  }

  await application.show("apps")
  guard let launcherSearch = await focusedSearchEditor() else {
    return "Main shelf search did not receive keyboard focus for the Quick Links entry"
  }
  let managerQuery = "Quick Links"
  launcherSearch.insertText(managerQuery, replacementRange: launcherSearch.selectedRange())
  guard
    await wait({ model.query == managerQuery && model.selectedSearch?.id == "builtin:quick-links" })
  else {
    return "Shelf search did not find the Quick Links manager"
  }
  post(36, [], "\r", false)
  guard await wait({ model.destination == "quick-links" && model.visible && !model.busy }),
    await focusedSearchEditor() != nil
  else {
    return "Return did not enter the Quick Links list and focus its search"
  }

  let invalidURL = "https://example.invalid:65536"
  let destination = "https://example.invalid/staging"
  post(45, .command, "т", false)
  guard await wait({ model.quickLinkDraft != nil }) else {
    return "Command N did not open the Quick Link editor"
  }
  guard await wait({ fieldEditor() != nil }), let nameEditor = fieldEditor() else {
    return
      "Quick Link editor did not focus the name field: \(String(describing: shelf.firstResponder))"
  }
  let nameDelegate = nameEditor.delegate
  func urlFieldEditor() -> NSTextView? {
    guard let editor = fieldEditor(), editor !== nameEditor || editor.delegate !== nameDelegate
    else { return nil }
    return editor
  }
  post(48, [], "\t", false)
  guard await wait({ urlFieldEditor()?.string == "" }), let urlEditor = urlFieldEditor() else {
    return "Tab did not move from the Quick Link name to the URL field"
  }
  urlEditor.insertText(invalidURL, replacementRange: urlEditor.selectedRange())
  guard await wait({ model.quickLinkDraft?.url == invalidURL }) else {
    return "Quick Link URL field did not update its draft"
  }
  post(36, .command, "\r", false)
  guard await wait({ model.quickLinkDraft?.error.isEmpty == false && !model.busy }),
    model.error.isEmpty,
    model.quickLinks == originalLinks, model.quickLinkDraft?.name == "",
    model.quickLinkDraft?.url == invalidURL, let correctionEditor = urlFieldEditor()
  else {
    return
      "Command Return did not preserve the Quick Link draft on URL validation failure"
  }
  correctionEditor.insertText(
    destination, replacementRange: NSRange(location: 0, length: (invalidURL as NSString).length))
  guard await wait({ model.quickLinkDraft?.url == destination }) else {
    return "Quick Link URL could not be corrected in the active editor"
  }
  await screenshot("quick-links-shelf-unnamed-editor")
  post(36, .command, "\r", false)
  guard await wait({ model.quickLinkDraft == nil && !model.busy && !model.commandPending }),
    model.destination == "quick-links", model.visible,
    model.quickLinks.count == originalLinks.count + 1,
    let link = model.quickLinks.first(where: { $0.id == model.selectedQuickLinkID }),
    link.name.isEmpty, link.url.absoluteString == destination,
    let linkSearchEditor = await focusedSearchEditor()
  else {
    return "Command Return did not save and select the unnamed Quick Link"
  }
  await screenshot("quick-links-shelf-unnamed")
  let urlQuery = "staging"
  linkSearchEditor.insertText(urlQuery, replacementRange: linkSearchEditor.selectedRange())
  guard await wait({ model.query == urlQuery && model.quickLinkResults.contains(link) }) else {
    return "Searching by URL did not find the unnamed Quick Link"
  }
  post(51, .command, "", true)
  post(14, .command, "у", false)
  guard await wait({ model.quickLinkDraft?.id == link.id && fieldEditor()?.string == "" }),
    let editName = fieldEditor()
  else {
    return
      "Command E did not edit the selected Quick Link after repeated Command Delete"
  }
  let editedName = "Team Dashboard"
  editName.insertText(editedName, replacementRange: editName.selectedRange())
  guard await wait({ model.quickLinkDraft?.name == editedName }) else {
    return "Quick Link edit did not update the display name"
  }
  await screenshot("quick-links-shelf-editor")
  post(13, .command, "w", false)
  guard await wait({ !model.visible && !shelf.isVisible && !model.commandPending }) else {
    return "Command W did not close the Quick Links editor"
  }
  await application.show(nil)
  guard await wait({ shelf.isKeyWindow && model.visible && model.destination == "quick-links" }),
    model.quickLinkDraft?.id == link.id, model.quickLinkDraft?.name == editedName,
    model.quickLinkDraft?.url == destination
  else {
    return "Reopening the shelf did not restore the unsaved Quick Link draft"
  }
  guard await wait({ fieldEditor()?.string == editedName }) else {
    return
      "Reopening the Quick Link editor did not restore name field focus: \(String(describing: shelf.firstResponder))"
  }
  post(36, .command, "\r", false)
  guard await wait({ model.quickLinkDraft == nil && !model.busy && !model.commandPending }),
    model.quickLinks.contains(where: { $0.id == link.id && $0.name == editedName }),
    await focusedSearchEditor() != nil
  else {
    return "Command Return did not save changes to the selected Quick Link"
  }
  await screenshot("quick-links-shelf-list")
  await application.show("apps")
  guard let searchEditor = await focusedSearchEditor() else {
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
  await screenshot("launcher-quick-link")
  post(36, [], "\r", false)
  guard await wait({ opened == [link.url] && !model.error.isEmpty && !model.busy }),
    model.visible
  else {
    return "Return did not show the Quick Link open failure on the shelf"
  }
  canOpen = true
  post(36, [], "\r", false)
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
  await application.show("quick-links")
  guard model.destination == "quick-links", model.query.isEmpty, await focusedSearchEditor() != nil
  else {
    return "Reopening the Quick Links list did not focus its search"
  }
  post(51, .command, "", false)
  if !(await wait({ model.quickLinks == originalLinks && !model.busy })) {
    return "Command Delete did not remove the selected Quick Link"
  }
  return nil
}
