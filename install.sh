#!/bin/bash
# Usage: curl -fsSL https://raw.githubusercontent.com/clasen/MADSET/main/install.sh | bash
#
# Downloads the source of the main branch, builds it with the Swift toolchain already on the
# Mac and installs ~/Applications/Blendline.app. Run it again to update.

set -euo pipefail

main() {
  local repo="clasen/MADSET"
  local branch="main"
  local archive="https://codeload.github.com/$repo/tar.gz/refs/heads/$branch"
  local destination="$HOME/Applications/Blendline.app"
  local stage="" backup="" arch macos swift_output swift_version source answer=""
  local connect_timeout=15 download_timeout=600

  fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
  # The ${var:-} defaults matter: when set -e ends the script, bash 5 drops main's locals before
  # running the EXIT trap, and set -u would turn that into an unbound-variable error.
  cleanup() {
    local stage="${stage:-}" backup="${backup:-}" destination="${destination:-$HOME/Applications/Blendline.app}"
    if [ -n "$backup" ] && [ -e "$backup" ] && [ ! -e "$destination" ]; then
      mv "$backup" "$destination" || printf 'Restore the previous app from %s\n' "$backup" >&2
    fi
    # Do not delete a backup if restoring it failed.
    if [ -n "$stage" ] && { [ -z "$backup" ] || [ ! -e "$backup" ]; }; then
      rm -rf "$stage"
    fi
  }
  trap cleanup EXIT
  # Safety net: with set -e a failing command would otherwise end the script without a word.
  trap 'printf "Error: the installer stopped at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
  trap 'exit 130' INT
  trap 'exit 143' TERM

  [ "$(uname -s)" = Darwin ] || fail 'Blendline is a macOS app.'
  arch="$(uname -m)"
  # A shell under Rosetta reports x86_64 on an Apple Silicon Mac.
  if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    arch=arm64
  fi
  [ "$arch" = arm64 ] || fail 'Blendline needs an Apple Silicon Mac.'
  macos="$(sw_vers -productVersion)"
  [ "${macos%%.*}" -ge 15 ] || fail "Blendline needs macOS 15 or newer. This Mac runs $macos."

  command -v curl >/dev/null || fail 'curl is missing.'
  # /usr/bin/swift exists on every Mac as a shim; the toolchain is there once xcode-select has a path.
  if ! xcode-select -p >/dev/null 2>&1; then
    printf 'Swift is missing. Opening the installer for the Command Line Tools (Swift included)…\n'
    xcode-select --install >/dev/null 2>&1 || true
    printf 'Click Install in the dialog. Waiting for it to finish (Ctrl-C to cancel)…\n'
    until xcode-select -p >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1; do sleep 5; done
    printf 'Command Line Tools installed.\n'
  fi
  # Xcode's tools, swift included, exit 69 until its license is accepted.
  if ! swift_output="$(swift --version 2>&1)"; then
    case "$swift_output" in
      *[Ll]icense*)
        printf 'Xcode is installed but its license has not been accepted yet.\n'
        printf 'Accepting the Xcode and Apple SDKs license (sudo xcodebuild -license accept). Enter your Mac password if asked.\n'
        # sudo reads the password from the terminal, so this works under curl | bash too.
        sudo xcodebuild -license accept \
          || fail 'Could not accept the Xcode license. Run: sudo xcodebuild -license accept, then run the installer again.'
        swift_output="$(swift --version 2>&1)" || fail "swift --version failed: $swift_output"
        printf 'Xcode license accepted.\n'
        ;;
      *) fail "swift --version failed: $swift_output" ;;
    esac
  fi
  swift_version="$(printf '%s\n' "$swift_output" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
  [ -n "$swift_version" ] || fail 'Could not read the Swift version. Check that xcode-select points to a working toolchain.'
  { [ "${swift_version%%.*}" -gt 6 ] || { [ "${swift_version%%.*}" -eq 6 ] && [ "${swift_version#*.}" -ge 2 ]; }; } \
    || fail "Blendline needs Swift 6.2 or newer, found $swift_version. Update Xcode or the Command Line Tools."

  printf 'Blendline installer: macOS %s, Swift %s\nClose Blendline before updating.\n' "$macos" "$swift_version"
  mkdir -p "$(dirname "$destination")"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/blendline-install.XXXXXX")"

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
  [ -d "$source/build/Blendline.app/Contents" ] || fail 'The build did not produce Blendline.app.'

  if [ -e "$destination" ]; then
    backup="$stage/previous.app"
    mv "$destination" "$backup" || fail 'Could not move the previous app. Check permissions and close Blendline.'
  fi
  mv "$source/build/Blendline.app" "$destination" || fail 'Could not install the app. Restoring the previous version.'
  if [ -n "$backup" ]; then rm -rf "$backup"; backup=""; fi

  printf 'Installed: %s\n' "$destination"
  cleanup
  trap - EXIT

  # stdin is the piped script under `curl | bash`, so ask on the terminal; skip when there is none.
  if { : </dev/tty; } 2>/dev/null; then
    read -r -p 'Open Blendline now? [Y/n] ' answer </dev/tty || answer=n
  else
    answer=n
  fi
  case "$answer" in
    [nN]*) printf 'Open it from Finder, or run: open "%s"\n' "$destination" ;;
    *) open "$destination" ;;
  esac
}

main "$@"
