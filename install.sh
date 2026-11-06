#!/bin/sh
# Installs the latest release of Haze.
#
#   curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh
#
# Set HAZE_VERSION to install a particular release (for example v0.1.0), HAZE_INSTALL_DIR to
# choose where the haze command goes (the default is ~/.local/bin), or HAZE_ARCHIVE to install
# from an archive that is already downloaded.
set -eu

repo="ritabratamaiti/haze-lang"
dir="${HAZE_INSTALL_DIR:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) target="x86_64-linux" ;;
  Darwin-arm64) target="aarch64-macos" ;;
  *)
    echo "There is no prebuilt Haze for $(uname -s) $(uname -m) yet." >&2
    echo "You can build it from source: https://github.com/$repo#build" >&2
    exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ -n "${HAZE_ARCHIVE:-}" ]; then
  cp "$HAZE_ARCHIVE" "$tmp/haze.tar.gz"
else
  version="${HAZE_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -sSfL "https://api.github.com/repos/$repo/releases/latest" |
      sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  fi
  [ -n "$version" ] || { echo "Could not find the latest Haze release." >&2; exit 1; }
  url="https://github.com/$repo/releases/download/$version/haze-$version-$target.tar.gz"
  echo "Downloading Haze $version for $target"
  curl -sSfL "$url" -o "$tmp/haze.tar.gz"
fi

tar xzf "$tmp/haze.tar.gz" -C "$tmp"
mkdir -p "$dir"
cp "$tmp"/haze-*/haze "$dir/haze"
chmod +x "$dir/haze"
echo "Installed $("$dir/haze" --version) to $dir/haze"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH to run haze from anywhere." ;;
esac
