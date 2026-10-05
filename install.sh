#!/bin/bash
# Usage: curl -fsSL https://raw.githubusercontent.com/clasen/MADSET/main/install.sh | bash
#
# Downloads the source of the main branch, builds it with the Swift toolchain already on the
# Mac and installs ~/Applications/MADSET.app. Run it again to update.

set -euo pipefail

main() {
  local repo="clasen/MADSET"
  local branch="main"
  local archive="https://codeload.github.com/$repo/tar.gz/refs/heads/$branch"
  local destination="$HOME/Applications/MADSET.app"
  local stage="" backup="" arch macos swift_version source
  local connect_timeout=15 download_timeout=600

  fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
  cleanup() {
    if [ -n "$backup" ] && [ -e "$backup" ] && [ ! -e "$destination" ]; then
      mv "$backup" "$destination" || printf 'Restore the previous app from %s\n' "$backup" >&2
    fi
    # Do not delete a backup if restoring it failed.
    if [ -n "$stage" ] && { [ -z "$backup" ] || [ ! -e "$backup" ]; }; then
      rm -rf "$stage"
    fi
  }
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [ "$(uname -s)" = Darwin ] || fail 'MADSET is a macOS app.'
  arch="$(uname -m)"
  # A shell under Rosetta reports x86_64 on an Apple Silicon Mac.
  if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    arch=arm64
  fi
  [ "$arch" = arm64 ] || fail 'MADSET needs an Apple Silicon Mac.'
  macos="$(sw_vers -productVersion)"
  [ "${macos%%.*}" -ge 26 ] || fail "MADSET needs macOS 26 or newer. This Mac runs $macos."

  command -v curl >/dev/null || fail 'curl is missing.'
  # /usr/bin/swift exists on every Mac as a shim; the toolchain is there once xcode-select has a path.
  if ! xcode-select -p >/dev/null 2>&1; then
    printf 'Swift is missing. Opening the installer for the Command Line Tools (Swift included)…\n'
    xcode-select --install >/dev/null 2>&1 || true
    printf 'Click Install in the dialog. Waiting for it to finish (Ctrl-C to cancel)…\n'
    until xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; do sleep 5; done
    printf 'Command Line Tools installed.\n'
  fi
  swift_version="$(swift --version 2>&1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
  [ -n "$swift_version" ] || fail 'Could not read the Swift version. Check that xcode-select points to a working toolchain.'
  { [ "${swift_version%%.*}" -gt 6 ] || { [ "${swift_version%%.*}" -eq 6 ] && [ "${swift_version#*.}" -ge 2 ]; }; } \
    || fail "MADSET needs Swift 6.2 or newer, found $swift_version. Update Xcode or the Command Line Tools."

  printf 'MADSET installer: macOS %s, Swift %s\nClose MADSET before updating.\n' "$macos" "$swift_version"
  mkdir -p "$(dirname "$destination")"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/madset-install.XXXXXX")"

  printf 'Downloading %s@%s…\n' "$repo" "$branch"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --connect-timeout "$connect_timeout" --max-time "$download_timeout" "$archive" -o "$stage/source.tar.gz" \
    || fail "Download failed: $archive. Check your connection, then retry."
  mkdir "$stage/source"
  tar -xzf "$stage/source.tar.gz" -C "$stage/source" --strip-components 1 || fail 'Could not unpack the source.'
  source="$stage/source"
  [ -x "$source/scripts/bundle.sh" ] || fail 'The download does not contain scripts/bundle.sh.'

  printf 'Building, usually under a minute…\n'
  "$source/scripts/bundle.sh" || fail 'The build failed. Nothing was installed.'
  [ -d "$source/build/MADSET.app/Contents" ] || fail 'The build did not produce MADSET.app.'

  if [ -e "$destination" ]; then
    backup="$stage/previous.app"
    mv "$destination" "$backup" || fail 'Could not move the previous app. Check permissions and close MADSET.'
  fi
  mv "$source/build/MADSET.app" "$destination" || fail 'Could not install the app. Restoring the previous version.'
  if [ -n "$backup" ]; then rm -rf "$backup"; backup=""; fi

  printf 'Installed: %s\nOpen it from Finder, or run: open "%s"\n' "$destination" "$destination"
  cleanup
  trap - EXIT
}

main "$@"
