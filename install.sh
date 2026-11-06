#!/bin/sh
# Installs Haze.
#
#   curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh
#
# By default this downloads a prebuilt release and checks it against the release's checksums.
# Set HAZE_FROM_SOURCE=1 to build Haze on your machine instead, the way Lean projects are built:
# the script installs elan (Lean's toolchain manager) if needed, fetches the source and runs
# `lake build`. Platforms without a prebuilt release are built from source automatically.
#
# Other settings: HAZE_VERSION picks a release (for example v0.1.0), HAZE_INSTALL_DIR picks
# where the haze command goes (the default is ~/.local/bin), HAZE_ARCHIVE installs from an
# archive that is already downloaded, and HAZE_SOURCE_DIR builds from a local checkout.
set -eu

repo="ritabratamaiti/haze-lang"
dir="${HAZE_INSTALL_DIR:-$HOME/.local/bin}"
from_source="${HAZE_FROM_SOURCE:-}"
[ -n "${HAZE_SOURCE_DIR:-}" ] && from_source=1

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) target="x86_64-linux" ;;
  Darwin-arm64) target="aarch64-macos" ;;
  *)
    target=""
    if [ -z "$from_source" ]; then
      echo "There is no prebuilt Haze for $(uname -s) $(uname -m), so it will be built from source."
      from_source=1
    fi ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

latest() {
  curl -sSfL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1
}

if [ -n "$from_source" ]; then
  if [ -n "${HAZE_SOURCE_DIR:-}" ]; then
    src="$HAZE_SOURCE_DIR"
  else
    command -v git >/dev/null 2>&1 || { echo "Building from source needs git." >&2; exit 1; }
    version="${HAZE_VERSION:-$(latest)}"
    version="${version:-main}"
    echo "Fetching the Haze source ($version)"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" "https://github.com/$repo.git" "$tmp/src"
    src="$tmp/src"
  fi
  if ! command -v lake >/dev/null 2>&1; then
    if [ ! -x "$HOME/.elan/bin/lake" ]; then
      echo "Installing elan, the Lean toolchain manager"
      curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh |
        sh -s -- -y --default-toolchain none
    fi
    PATH="$HOME/.elan/bin:$PATH"
  fi
  echo "Building Haze (the first build downloads the Lean toolchain and takes a few minutes)"
  (cd "$src" && lake build haze)
  bin="$src/.lake/build/bin/haze"
else
  if [ -n "${HAZE_ARCHIVE:-}" ]; then
    cp "$HAZE_ARCHIVE" "$tmp/haze.tar.gz"
  else
    version="${HAZE_VERSION:-$(latest)}"
    [ -n "$version" ] || { echo "Could not find the latest Haze release." >&2; exit 1; }
    asset="haze-$version-$target.tar.gz"
    base="https://github.com/$repo/releases/download/$version"
    echo "Downloading Haze $version for $target"
    curl -sSfL "$base/$asset" -o "$tmp/haze.tar.gz"
    # check the archive against the checksums published with the release
    curl -sSfL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
    expected="$(grep " $asset\$" "$tmp/SHA256SUMS" | cut -d ' ' -f 1)"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/haze.tar.gz" | cut -d ' ' -f 1)"
    else
      actual="$(shasum -a 256 "$tmp/haze.tar.gz" | cut -d ' ' -f 1)"
    fi
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
      echo "The download doesn't match the release checksum; not installing." >&2
      exit 1
    fi
  fi
  tar xzf "$tmp/haze.tar.gz" -C "$tmp"
  bin="$(ls "$tmp"/haze-*/haze)"
fi

mkdir -p "$dir"
cp "$bin" "$dir/haze"
chmod +x "$dir/haze"
echo "Installed $("$dir/haze" --version) to $dir/haze"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH to run haze from anywhere." ;;
esac
