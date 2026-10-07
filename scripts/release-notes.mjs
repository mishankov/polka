import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { releaseVersion } from './release-version.mjs';

/** Versioned release notes travel in the same feed item as the authenticated archive. */
export async function readReleaseNotes(version, path = `release-notes/${version}.json`) {
  const notes = JSON.parse(await readFile(path, 'utf8'));
  for (const language of ['ru', 'en']) {
    if (
      typeof notes?.[language] !== 'string' ||
      !notes[language].trim() ||
      notes[language].length > 20_000
    )
      throw Error(
        `Release notes must include nonempty ru and en text (at most 20,000 characters each): ${path}`,
      );
  }
  return { ru: notes.ru.trim(), en: notes.en.trim() };
}

/** Keep setup guidance in GitHub descriptions; appcast notes stay focused on changes. */
export function releaseNotesMarkdown(notes, { tag, repository = 'mishankov/polka' }) {
  const version = releaseVersion(tag);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository))
    throw Error('Release notes repository must be owner/repository.');
  const downloadUrl = `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/polka-${version}-arm64.dmg`;
  const installCommand =
    'curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh | /bin/bash';
  const markdown = (text) => text.replace(/^•\s+/gm, '- ');
  return `# Polka ${version}

**macOS 27+ · Apple silicon**

## English

### What's new

${markdown(notes.en)}

### Updating

If Polka is already installed, open **About → Updates** in its settings and install the new version. Your history and settings are preserved. Polka's interface is in Russian: look for **«О приложении → Обновления»**.

### Installation

<details>
<summary>Three ways to install</summary>

Choose one of these three methods. Releases are self-signed and are not notarized by Apple.

#### 1. Installation script

Open Terminal, paste this command, and press Enter:

\`\`\`sh
${installCommand}
\`\`\`

The script installs the **latest stable release**, verifies the download, removes quarantine only from Polka, and opens it. If Polka is running, first choose **«Выйти из Полки»** (Quit Polka) in its menu. The installer asks for your Mac login password when needed.

#### 2. Download and use Terminal

1. [Download this release's DMG](${downloadUrl}), open it, and drag **Polka** to **Applications**.
2. Run these commands in Terminal:

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/Polka.app"
open "/Applications/Polka.app"
\`\`\`

If the first command reports a permission error, repeat only that command with \`sudo\` at the beginning. It removes quarantine only from the installed Polka app.

#### 3. Download and allow in System Settings

1. [Download this release's DMG](${downloadUrl}), open it, and drag **Polka** to **Applications**.
2. Try opening Polka. If macOS blocks it, dismiss the warning.
3. Open **System Settings → Privacy & Security**, scroll to **Security**, and click **Open Anyway** next to the message about Polka.
4. Confirm and click **Open**. [Apple's instructions](https://support.apple.com/en-us/102445).

After installation, use the menu bar icon or **⌘ ⇧ Space** to open the shelf. Grant **Accessibility** permission separately to enable automatic paste.

</details>

## Русский

### Что нового

${markdown(notes.ru)}

### Обновление

Если Полка уже установлена, откройте **«О приложении → Обновления»** и установите новую версию. История и настройки сохранятся.

### Установка

<details>
<summary>Три способа установки</summary>

Выберите один из трёх способов. Выпуски используют self-signed подпись и не проходят Apple notarization.

#### 1. Скрипт

Откройте Терминал, вставьте команду и нажмите Enter:

\`\`\`sh
${installCommand}
\`\`\`

Скрипт устанавливает **последний стабильный выпуск**, проверяет загрузку, снимает quarantine только с Polka и открывает приложение. Если Полка работает, сначала выберите «Выйти из Полки» в её меню. При необходимости установщик запросит пароль macOS.

#### 2. Скачать и выполнить команду

1. [Скачайте DMG этого выпуска](${downloadUrl}), откройте его и перенесите **Polka** в **«Программы»**.
2. Выполните в Терминале:

\`\`\`sh
xattr -dr com.apple.quarantine "/Applications/Polka.app"
open "/Applications/Polka.app"
\`\`\`

Если первая команда сообщает о недостаточных правах, повторите только её с \`sudo\` в начале. Команда снимает quarantine только с установленной Полки.

#### 3. Скачать и разрешить в настройках

1. [Скачайте DMG этого выпуска](${downloadUrl}), откройте его и перенесите **Polka** в **«Программы»**.
2. Попробуйте открыть Polka. Если macOS заблокирует запуск, закройте предупреждение.
3. Откройте **«Системные настройки → Конфиденциальность и безопасность»**, прокрутите до раздела **«Безопасность»** и нажмите **«Всё равно открыть»** рядом с сообщением о Polka.
4. Подтвердите действие и нажмите **«Открыть»**. [Инструкция Apple](https://support.apple.com/ru-ru/102445).

После установки Полка доступна через значок в строке меню и **⌘ ⇧ Пробел**. Разрешение **«Универсальный доступ»** для автовставки выдаётся отдельно.

</details>

`;
}

async function main() {
  try {
    if (process.argv[2] === '--version' && process.argv.length === 4) {
      console.log(releaseVersion(process.argv[3]));
    } else {
      const [tag, output, source] = process.argv.slice(2);
      if (!tag || !output || process.argv.length > 5)
        throw Error('Usage: node scripts/release-notes.mjs TAG OUTPUT.md [SOURCE.json]');
      const notes = await readReleaseNotes(releaseVersion(tag), source);
      await writeFile(
        output,
        releaseNotesMarkdown(notes, {
          tag,
          repository:
            process.env.RELEASE_REPOSITORY || process.env.GITHUB_REPOSITORY || 'mishankov/polka',
        }),
      );
    }
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}

// No npm dependencies or signing secrets: this also runs on the Ubuntu preparation job.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) void main();
