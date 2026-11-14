# Installation

Most people install a prebuilt binary with a one-line script. Haze can also be built from source
with Lean's toolchain, or run from Docker. To try the language first, the
[playground](https://haze-lang.pages.dev/play/) runs it in your browser.

## Prebuilt binaries

Releases include binaries for Linux on x86-64, macOS on Apple silicon, and Windows on x86-64. The
install scripts download the latest release, check it against the release's `SHA256SUMS` file, and
refuse to install it if the checksum doesn't match.

On Linux and macOS:

```sh
curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh | sh
```

This puts `haze` in `~/.local/bin`, and tells you if that directory isn't on your `PATH`.

On Windows, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.ps1 | iex
```

This puts `haze.exe` in `%LOCALAPPDATA%\Programs\haze` and adds that directory to your user
`PATH`. Open a new terminal afterwards so that the change takes effect.

Check that it worked:

```sh
haze --version
```

The scripts read a few environment variables:

| Variable | Effect |
|---|---|
| `HAZE_VERSION` | The release to install, such as `v0.1.0`. The default is the latest release. |
| `HAZE_INSTALL_DIR` | Where to put the `haze` command. |
| `HAZE_FROM_SOURCE` | Set to `1` to build Haze from source instead of downloading a binary. |
| `HAZE_ARCHIVE` | Install from a release archive you have already downloaded. |
| `HAZE_SOURCE_DIR` | Build from a local checkout of the repository. |

You can also download an archive yourself from the
[releases page](https://github.com/ritabratamaiti/haze-lang/releases). Each archive contains the
`haze` binary and the examples, so `haze examples/payments_retry.hz` works straight away.

The binaries aren't code-signed. On macOS, the install script avoids Gatekeeper's quarantine, but a
binary downloaded with a browser needs `xattr -d com.apple.quarantine haze` before it will run. On
Windows, managed machines sometimes block new unsigned programs; building from source, described
next, usually avoids that.

## Building from source

Haze is a Lean 4 project, so building it needs [elan](https://github.com/leanprover/elan), Lean's
toolchain manager. elan reads the Lean version from the repository's `lean-toolchain` file and
installs it the first time you build.

The install scripts can do all of this for you:

```sh
HAZE_FROM_SOURCE=1 sh -c "$(curl -sSfL https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.sh)"
```

In PowerShell, set `$env:HAZE_FROM_SOURCE = "1"` and run the Windows command above. The script
installs elan if you don't have it, fetches the source, and runs `lake build`. The first build
downloads the Lean toolchain and takes a few minutes. Platforms without a prebuilt binary, such as
Linux on ARM, are built from source automatically.

To build a checkout by hand:

```sh
git clone https://github.com/ritabratamaiti/haze-lang
cd haze-lang
lake build                              # the library, its theorems and the haze command
lake exe haze examples/payments_retry.hz
lake test                               # the test suite
```

The binary ends up in `.lake/build/bin/haze`.

## Docker

The image `ghcr.io/ritabratamaiti/haze-lang` contains the `haze` command and the examples. Mount
the directory with your models at `/work`:

```sh
docker run --rm -v "$PWD:/work" ghcr.io/ritabratamaiti/haze-lang model.hz
```

The image's entry point is `haze`, so any options go after the image name, as in
`... haze-lang --json model.hz`.

## GitHub Actions

The repository is also a GitHub Action. This step installs Haze and checks every model in
`models/`, and it fails the job if any declaration is rejected:

```yaml
- uses: ritabratamaiti/haze-lang@v0.1.0
  with:
    files: models/*.hz
```

[Haze in CI and scripts](CI.md) describes its inputs and other ways to use Haze in a pipeline.

## Without installing

- The [playground](https://haze-lang.pages.dev/play/) runs a WebAssembly build of Haze in your
  browser. It gives the same output as the native `haze`, but large models are slower there.
- The [notebook](https://colab.research.google.com/github/ritabratamaiti/haze-lang/blob/main/notebooks/try_haze.ipynb)
  runs on Google Colab or [Binder](https://mybinder.org/v2/gh/ritabratamaiti/haze-lang/main?labpath=notebooks%2Ftry_haze.ipynb).
  Its first cell installs Haze.
- [GitHub Codespaces](https://codespaces.new/ritabratamaiti/haze-lang) opens the repository in an
  editor with Haze installed.

## Editor support

There's no editor extension yet. Haze's comments and keywords are close enough to Lean's that
setting `.hz` files to Lean highlighting in your editor works reasonably well.
