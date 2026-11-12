# Releasing Haze

## Making a release

1. Add a section for the new version to [`RELEASES.md`](../RELEASES.md), headed
   `## vX.Y.Z (date)`, and update `version` in [`Main.lean`](../Main.lean) and in
   [`CITATION.cff`](../CITATION.cff).
2. Commit, then tag and push: `git tag -a vX.Y.Z -m "Haze vX.Y.Z" && git push origin vX.Y.Z`.
3. The [release workflow](../.github/workflows/release.yml) builds Linux x86-64, macOS Apple
   silicon and Windows x86-64 archives, smoke-tests each binary, and attaches the archives and a
   `SHA256SUMS` file to a draft release. For a public repository, it also records build
   provenance for each archive. It also builds the Docker image and pushes it to
   `ghcr.io/ritabratamaiti/haze-lang` as `X.Y.Z` and `latest`.
4. Check the draft on the releases page, then publish it:
   `gh release edit vX.Y.Z --draft=false`.

To rebuild the archives for an existing tag, run the workflow by hand:
`gh workflow run release.yml -f tag=vX.Y.Z`.

The GitHub Action in [`action.yml`](../action.yml) is used as
`ritabratamaiti/haze-lang@vX.Y.Z`, so each tag is also an action version. It downloads the
release with the same tag, so publish the release before announcing the tag. The
[Distribution workflow](../.github/workflows/distribution.yml) tests the source install, the
action and the Docker image whenever they change.

The workflow pushes the Docker image with its built-in token. If GitHub refuses the push with
`denied`, which can happen when a package is first created in a personal account, add a
repository secret named `GHCR_TOKEN` and the workflow will use it instead. Create a classic token
with only the `write:packages` scope at
<https://github.com/settings/tokens/new?scopes=write:packages&description=haze-ghcr>, then:

```sh
gh secret set GHCR_TOKEN -R ritabratamaiti/haze-lang   # paste the token when asked
gh workflow run release.yml -R ritabratamaiti/haze-lang -f tag=vX.Y.Z
```

A Docker image pushed from a private repository stays private when the repository is made public.
Change its visibility once in the package settings on GitHub.

## Notebooks

[`notebooks/try_haze.ipynb`](../notebooks/try_haze.ipynb) runs on Google Colab and on Binder.
Its first cell installs the latest release with `install.sh`, and Binder installs it ahead of
time with [`binder/postBuild`](../binder/postBuild). The Distribution workflow runs the
notebook on Linux the way Binder sets it up. After changing it, save it with its outputs, so
that GitHub's preview shows the results:
`jupyter nbconvert --to notebook --execute --inplace notebooks/try_haze.ipynb`.

Binder builds an image the first time someone opens a new commit, which takes a few minutes, so
open the Binder link yourself after each push to `main` before sharing it.

## The website

The website in [`site/`](../site) is a static site: a landing page, a playground, a tour, the
gallery and these docs. The Website workflow builds it on every push and pull request and
deploys it to GitHub Pages from `main` once the repository is public. Under
Settings > Pages, set the source to *GitHub Actions* the first time.

The playground runs a WebAssembly build of Haze, made by [`wasm/build.py`](../wasm/README.md).
The workflow checks that build against the native one with `node wasm/test_node.mjs`, which
compares the output of every test and example.

To work on the site locally, install [emsdk](https://emscripten.org/docs/getting_started/downloads.html)
and activate it, then:

```sh
lake build
python wasm/build.py             # writes site/public/engine/haze.{mjs,wasm}
cd site && npm ci
node build.mjs --serve           # builds site/dist and serves it on http://localhost:8080
```

The build runs every preset, tour chapter and gallery example ahead of time, so pages show results
before the engine has loaded. Presets are in `site/content/presets`, the tour is
`site/content/tour.md`, and the gallery list is in `site/build.mjs`.

## How users can check a download

The install scripts compare each download with `SHA256SUMS` and refuse to install on a
mismatch. Anyone can also check that an archive was built by this repository's workflow:

```sh
gh attestation verify haze-vX.Y.Z-x86_64-linux.tar.gz -R ritabratamaiti/haze-lang
```

## Code signing

The binaries aren't signed yet. Signing matters mainly for files downloaded through a browser,
which Windows SmartScreen and macOS Gatekeeper check. The install scripts don't trigger those
checks. Managed Windows machines may still block a new unsigned program.

**macOS.** With an Apple Developer Program membership, create a *Developer ID Application*
certificate. Then, on the macOS runner, sign the binary with the hardened runtime and notarize
it:

```sh
codesign --force --options runtime --timestamp --sign "Developer ID Application: NAME (TEAMID)" haze
ditto -c -k --keepParent haze haze.zip
xcrun notarytool submit haze.zip --key AuthKey.p8 --key-id KEY_ID --issuer ISSUER_ID --wait
```

In CI, import the certificate (exported as a `.p12`) into a temporary keychain, and keep the
certificate, its password and an App Store Connect API key in repository secrets. A bare
executable can't have the notarization ticket stapled to it, so Gatekeeper looks it up online
the first time it runs.

**Windows.** Get a code signing certificate from a certificate authority. Since 2023 the private
key must live in a hardware module, so choose one with cloud signing that works from CI, or
use Azure Artifact Signing where it is available to you. Then sign `haze.exe` on the Windows
runner before packaging:

```sh
signtool sign /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 /f cert.pfx /p PASSWORD haze.exe
```

The exact command depends on the provider; cloud signing services provide their own tool or
`signtool` plugin. SmartScreen builds a reputation for a signed publisher over time, so warnings
fade as more people download releases.
