import Foundation

public enum ReleaseError: Error, CustomStringConvertible, Equatable {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}

public enum ReleaseVersion {
  public static func parse(_ tag: String) throws -> String {
    let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    guard
      version.range(
        of:
          #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\z"#,
        options: .regularExpression) != nil
    else {
      throw ReleaseError.invalid(
        "RELEASE_TAG must be a semantic version with an optional v prefix.")
    }
    return version
  }
  public static func repository(_ value: String) throws -> String {
    guard
      value.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z"#, options: .regularExpression) != nil
    else {
      throw ReleaseError.invalid(
        "Set RELEASE_REPOSITORY=owner/repository to the public GitHub release repository.")
    }
    return value
  }
  public static func encodedTag(_ tag: String) -> String {
    // JavaScript encodeURIComponent's set; release-tag validation precedes this.
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    return tag.addingPercentEncoding(withAllowedCharacters: allowed)!
  }
}

public struct ReleaseNotes: Codable, Equatable {
  public let ru: String
  public let en: String
  public init(ru: String, en: String) throws {
    let whitespace = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: "\u{FEFF}"))
    guard ru.utf16.count <= 20_000, en.utf16.count <= 20_000,
      !ru.trimmingCharacters(in: whitespace).isEmpty,
      !en.trimmingCharacters(in: whitespace).isEmpty
    else {
      throw ReleaseError.invalid(
        "Release notes must include nonempty ru and en text (at most 20,000 characters each).")
    }
    self.ru = ru.trimmingCharacters(in: whitespace)
    self.en = en.trimmingCharacters(in: whitespace)
  }
  public var bilingual: BilingualNotes { BilingualNotes(ru: ru, en: en) }
  private enum CodingKeys: String, CodingKey { case ru, en }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      ru: values.decode(String.self, forKey: .ru), en: values.decode(String.self, forKey: .en))
  }
  public static func read(version: String, root: URL, source: URL? = nil) throws -> Self {
    _ = try ReleaseVersion.parse(version)
    let path = source ?? root.appendingPathComponent("release-notes/\(version).json")
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
  }
  public func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let russian = String(decoding: try encoder.encode(ru), as: UTF8.self)
    let english = String(decoding: try encoder.encode(en), as: UTF8.self)
    return "{\"ru\":\(russian),\"en\":\(english)}"
  }
  public func markdown(tag: String, repository: String = "mishankov/polka") throws -> String {
    let version = try ReleaseVersion.parse(tag)
    _ = try ReleaseVersion.repository(repository)
    let downloadURL =
      "https://github.com/\(repository)/releases/download/\(ReleaseVersion.encodedTag(tag))/polka-\(version)-arm64.dmg"
    let installCommand =
      "curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh | /bin/bash"
    func markdown(_ text: String) -> String {
      text.replacingOccurrences(of: #"(?m)^•\s+"#, with: "- ", options: .regularExpression)
    }
    return """
      # Polka \(version)

      **macOS 27+ · Apple silicon**

      ## English

      ### What's new

      \(markdown(en))

      ### Updating

      If Polka is already installed, open **About → Updates** in its settings and install the new version. History and settings are preserved when the same profile is used; check the compatibility notes above before updating from an earlier release. Polka's interface is in Russian: look for **«О приложении → Обновления»**.

      ### Installation

      <details>
      <summary>Three ways to install</summary>

      Choose one of these three methods. Releases are self-signed and are not notarized by Apple.

      #### 1. Installation script

      Open Terminal, paste this command, and press Enter:

      ```sh
      \(installCommand)
      ```

      The script installs the **latest stable release**, verifies the download, removes quarantine only from Polka, and opens it. If Polka is running, first choose **«Выйти из Полки»** (Quit Polka) in its menu. The installer asks for your Mac login password when needed.

      #### 2. Download and use Terminal

      1. [Download this release's DMG](\(downloadURL)), open it, and drag **Polka** to **Applications**.
      2. Run these commands in Terminal:

      ```sh
      xattr -dr com.apple.quarantine "/Applications/Polka.app"
      open "/Applications/Polka.app"
      ```

      If the first command reports a permission error, repeat only that command with `sudo` at the beginning. It removes quarantine only from the installed Polka app.

      #### 3. Download and allow in System Settings

      1. [Download this release's DMG](\(downloadURL)), open it, and drag **Polka** to **Applications**.
      2. Try opening Polka. If macOS blocks it, dismiss the warning.
      3. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the message about Polka.
      4. Confirm and click **Open**. [Apple's instructions](https://support.apple.com/en-us/102445).

      After installation, use the menu bar icon or **⌘ ⇧ Space** to open the shelf. Grant **Accessibility** permission separately to enable automatic paste.

      </details>

      ## Русский

      ### Что нового

      \(markdown(ru))

      ### Обновление

      Если Полка уже установлена, откройте **«О приложении → Обновления»** и установите новую версию. История и настройки сохраняются при использовании того же профиля; перед переходом со старого выпуска прочитайте ограничения совместимости выше.

      ### Установка

      <details>
      <summary>Три способа установки</summary>

      Выберите один из трёх способов. Выпуски используют self-signed подпись и не проходят Apple notarization.

      #### 1. Скрипт

      Откройте Терминал, вставьте команду и нажмите Enter:

      ```sh
      \(installCommand)
      ```

      Скрипт устанавливает **последний стабильный выпуск**, проверяет загрузку, снимает quarantine только с Polka и открывает приложение. Если Полка работает, сначала выберите «Выйти из Полки» в её меню. При необходимости установщик запросит пароль macOS.

      #### 2. Скачать и выполнить команду

      1. [Скачайте DMG этого выпуска](\(downloadURL)), откройте его и перенесите **Polka** в **«Программы»**.
      2. Выполните в Терминале:

      ```sh
      xattr -dr com.apple.quarantine "/Applications/Polka.app"
      open "/Applications/Polka.app"
      ```

      Если первая команда сообщает о недостаточных правах, повторите только её с `sudo` в начале. Команда снимает quarantine только с установленной Полки.

      #### 3. Скачать и разрешить в настройках

      1. [Скачайте DMG этого выпуска](\(downloadURL)), откройте его и перенесите **Polka** в **«Программы»**.
      2. Попробуйте открыть Polka. Если macOS заблокирует запуск, закройте предупреждение.
      3. Откройте **«Системные настройки → Конфиденциальность и безопасность»**, прокрутите до раздела **«Безопасность»** и нажмите **«Всё равно открыть»** рядом с сообщением о Polka.
      4. Подтвердите действие и нажмите **«Открыть»**. [Инструкция Apple](https://support.apple.com/ru-ru/102445).

      После установки Полка доступна через значок в строке меню и **⌘ ⇧ Пробел**. Разрешение **«Универсальный доступ»** для автовставки выдаётся отдельно.

      </details>
      """
  }
}
