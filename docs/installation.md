# Install Polka

You need **macOS 27 or later** and an **Apple silicon Mac (M1 or newer)**. Polka runs in the background: after installation, open the shelf from its menu bar icon or with **⌘⇧Space**.

Choose one of the three methods below. Releases are self-signed and are not notarized by Apple, so macOS may ask you to approve the first launch. If Polka is already running, choose **Quit Polka** from its menu bar menu before replacing the app.

## 1. Install with the script

Open **Terminal**, paste this command, and press Enter:

```sh
curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh | /bin/bash
```

The script downloads the latest stable release, checks the download's SHA-256 checksum and signature integrity, installs **`/Applications/Polka.app`**, removes the quarantine flag only from that app, and opens Polka. If it needs permission to write to Applications, it asks for your macOS password. Terminal does not display characters while you enter a password.

Homebrew and Xcode are not required. The script runs from the `master` branch; you can [read it before running it](../scripts/install.sh).

To inspect the script locally or choose another installation folder, download it first:

```sh
curl -fsSL https://raw.githubusercontent.com/mishankov/polka/master/scripts/install.sh -o install-polka.sh
less install-polka.sh
/bin/bash install-polka.sh --install-dir "$HOME/Applications" --no-launch
```

The destination folder must already exist. `--install-dir` selects the folder, and `--no-launch` leaves Polka closed after installation. Omit these options to install into `/Applications` and open the app.

## 2. Download and open from Terminal

1. Open the [latest release](https://github.com/mishankov/polka/releases/latest) and download **`polka-VERSION-arm64.dmg`** from **Assets**.
2. Open the DMG and drag **Polka** into **Applications**. Eject the disk image.
3. Open **Terminal** and run:

```sh
xattr -dr com.apple.quarantine "/Applications/Polka.app"
open "/Applications/Polka.app"
```

The first command removes the quarantine flag only from the installed Polka app; the second opens it. If removing the flag fails with `Permission denied` or `Operation not permitted`, repeat the first command with administrator privileges:

```sh
sudo xattr -dr com.apple.quarantine "/Applications/Polka.app"
```

If you installed Polka somewhere else, replace `/Applications/Polka.app` in the commands with its full path.

## 3. Download and approve in System Settings

1. Open the [latest release](https://github.com/mishankov/polka/releases/latest), download **`polka-VERSION-arm64.dmg`**, open it, and drag **Polka** into **Applications**. Eject the disk image.
2. Try opening **Polka** from Applications. If macOS blocks it, dismiss the alert.
3. Open **System Settings → Privacy & Security** and scroll down to **Security**.
4. Click **Open Anyway** next to the message about Polka. Confirm with your password or Touch ID if prompted, then click **Open**.

**Open Anyway** appears after you have tried to launch the app. See [Apple's instructions](https://support.apple.com/en-us/102445) for details. On a managed Mac, your administrator may need to approve the app.

## After installation

### Open the shelf

Polka does not show a Dock icon. Open it from its menu bar icon or with **⌘⇧Space**. Use **⌘⇧V** for clipboard history and **⌘,** for settings.

### Enable automatic pasting

Automatic pasting from clipboard history, snippets, and emoji requires **System Settings → Privacy & Security → Accessibility** permission. Polka shows **Allow…** when access is missing. Copying an entry and pasting it yourself with **⌘V** does not require this permission.

### Unlock clipboard storage

Before you first access history, Polka explains why it needs the **polka Safe Storage** key. If macOS asks for access, enter your **login** keychain password (usually your Mac login password) in the system dialog and choose **Always Allow**. The prompt may appear again after an update.

If you deny access, history and sync are unavailable, but saved files remain intact. Restart Polka to try again.

### Install updates

Later updates are available inside Polka in **Settings → About → Updates**. History and settings are preserved when you keep using the same profile.

Upgrading from 0.7.0 or earlier to 0.8.0 or later requires [manually transferring your old profile](data.md#переход-с-070-и-более-ранних-версий); there is no automatic migration. Quit Polka and back up the old profile before transferring it. You may also need to grant macOS permissions again.
