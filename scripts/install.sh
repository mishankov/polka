#!/bin/bash
# Compatible with the Bash 3.2 and command-line tools included in macOS.
# Keep execution inside main: an incomplete curl | bash download must not install anything.
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

download() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 \
    --proto '=https' --proto-redir '=https' "$@"
}

install_command() {
  if [[ "$needs_sudo" == true ]]; then sudo "$@"; else "$@"; fi
}

cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$stage" ]]; then
    if [[ "$committed" == false && -e "$stage/previous.app" ]]; then
      # A failed move or verification must leave the previous installation usable.
      if ! install_command rm -rf "$target" || \
         ! install_command mv "$stage/previous.app" "$target"; then
        printf 'Could not restore Polka. Your previous app is in %s/previous.app\n' "$stage" >&2
        stage=''
        status=1
      fi
    elif [[ "$committed" == false && "$placed" == true ]]; then
      install_command rm -rf "$target" || status=1
    fi
    if [[ -n "$stage" ]]; then install_command rm -rf "$stage" || status=1; fi
  fi
  if [[ -n "$temporary" ]]; then rm -rf "$temporary"; fi
  exit "$status"
}

ensure_stopped() {
  if pgrep -x Polka >/dev/null; then
    fail 'Quit Polka from its menu bar menu, then run the installer again.'
  fi
}

main() {
  install_dir='/Applications'
  launch=true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir)
        [[ $# -ge 2 ]] || fail '--install-dir needs an absolute directory.'
        install_dir=$2; shift 2 ;;
      --no-launch) launch=false; shift ;;
      --help|-h)
        printf 'Usage: install.sh [--install-dir /Applications] [--no-launch]\n'
        return ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
  [[ "$(uname -s)" == Darwin ]] || fail 'Polka requires macOS.'
  [[ "$(uname -m)" == arm64 ]] || fail 'Polka requires Apple silicon. Run Terminal without Rosetta.'
  os_version=$(sw_vers -productVersion)
  [[ "${os_version%%.*}" -ge 27 ]] || fail 'Polka requires macOS 27 or later.'
  [[ "$install_dir" == /* && -d "$install_dir" ]] || fail 'The installation directory must exist and be absolute.'
  target="$install_dir/Polka.app"
  [[ ! -L "$target" ]] || fail 'The existing Polka.app is a symbolic link. Move it before installing.'
  [[ ! -e "$target" || -d "$target" ]] || fail 'The installation path is not an app directory.'
  ensure_stopped

  temporary=''; stage=''; committed=false; placed=false; needs_sudo=false
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/polka-install.XXXXXX")
  repository='https://github.com/mishankov/polka'
  printf 'Finding the latest Polka release…\n'
  release_url=$(download --output /dev/null --write-out '%{url_effective}' "$repository/releases/latest")
  [[ "$release_url" == "$repository/releases/tag/"* ]] || fail 'Could not resolve the latest release.'
  tag=${release_url##*/}
  [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Unsupported release tag: $tag"
  version=${tag#v}
  archive="polka-$version-arm64.zip"
  # Pin both downloads to the resolved tag, even if a new release appears meanwhile.
  asset_url="$repository/releases/download/$tag"
  printf 'Downloading Polka %s…\n' "$version"
  download --output "$temporary/$archive" "$asset_url/$archive"
  download --output "$temporary/checksums.txt" "$asset_url/checksums.txt"
  printf 'Checking download…\n'
  expected=$(awk -v name="$archive" '$2 == name || $2 == "*" name { print $1 }' "$temporary/checksums.txt")
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || fail 'Missing or ambiguous ZIP checksum.'
  actual=$(shasum -a 256 "$temporary/$archive")
  [[ "${actual%% *}" == "$expected" ]] || fail 'Download checksum mismatch. Nothing was installed.'

  # Restrict the archive to this app, rejecting paths that escape the extraction directory.
  zipinfo -1 "$temporary/$archive" > "$temporary/entries.txt"
  while IFS= read -r entry; do
    case "$entry" in
      Polka.app|Polka.app/*) ;;
      *) fail 'Unexpected path in the release ZIP.' ;;
    esac
    case "/$entry/" in
      */../*|*/./*|*\\*) fail 'Unsafe path in the release ZIP.' ;;
    esac
  done < "$temporary/entries.txt"
  ditto -x -k "$temporary/$archive" "$temporary/unpacked"
  bundle="$temporary/unpacked/Polka.app"
  info="$bundle/Contents/Info.plist"
  [[ ! -L "$bundle" && -d "$bundle" ]] || fail 'The release does not contain Polka.app.'
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$info")" == app.polka.desktop ]] || fail 'Unexpected app identity.'
  [[ "$(plutil -extract CFBundleShortVersionString raw -o - "$info")" == "$version" ]] || fail 'App version does not match the release.'
  codesign --verify --deep --strict "$bundle"

  if [[ ! -w "$install_dir" || ( -e "$target" && ! -w "$target" ) ]]; then
    needs_sudo=true
    printf 'Installing in %s requires your Mac login password.\n' "$install_dir"
    sudo -v
  fi
  printf 'Installing in %s…\n' "$install_dir"
  stage=$(install_command mktemp -d "$install_dir/.polka-install.XXXXXX")
  # The unprivileged cleanup trap must be able to find a root-owned backup.
  install_command chmod 755 "$stage"
  install_command ditto "$bundle" "$stage/Polka.app"
  printf 'Preparing first launch…\n'
  # Dependency licenses can retain read-only modes from SwiftPM checkouts.
  # macOS requires write permission to remove their quarantine attributes.
  # Change only the staged copy, preserving executable bits and signed contents.
  install_command chmod -R u+w "$stage/Polka.app"
  install_command xattr -dr com.apple.quarantine "$stage/Polka.app"
  install_command codesign --verify --deep --strict "$stage/Polka.app"
  ensure_stopped
  if [[ -e "$target" ]]; then install_command mv "$target" "$stage/previous.app"; fi
  placed=true
  install_command mv "$stage/Polka.app" "$target"
  committed=true
  printf 'Polka %s is ready in %s.\n' "$version" "$target"
  if [[ "$launch" == true ]]; then
    if ! open "$target"; then
      fail "Polka is installed, but could not be opened. Open $target manually."
    fi
  fi
}

main "$@"
