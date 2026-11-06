# Releasing Haze

## Making a release

1. Add a section for the new version to [`RELEASES.md`](../RELEASES.md), headed
   `## vX.Y.Z (date)`, and update `version` in [`Main.lean`](../Main.lean) and in
   [`CITATION.cff`](../CITATION.cff).
2. Commit, then tag and push: `git tag -a vX.Y.Z -m "Haze vX.Y.Z" && git push origin vX.Y.Z`.
3. The [release workflow](../.github/workflows/release.yml) builds Linux x86-64, macOS Apple
   silicon and Windows x86-64 archives, smoke-tests each binary, and attaches the archives and a
   `SHA256SUMS` file to a draft release. For a public repository, it also records build
   provenance for each archive.
4. Check the draft on the releases page, then publish it:
   `gh release edit vX.Y.Z --draft=false`.

To rebuild the archives for an existing tag, run the workflow by hand:
`gh workflow run release.yml -f tag=vX.Y.Z`.

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
