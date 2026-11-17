# Installs Haze on Windows.
#
#   irm https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.ps1 | iex
#
# By default this downloads a prebuilt release and checks it against the release's checksums.
# Set $env:HAZE_FROM_SOURCE = "1" to build Haze on your machine instead, the way Lean projects
# are built: the script installs elan (Lean's toolchain manager) if needed, fetches the source
# and runs `lake build`. A program you build yourself isn't treated as an untrusted download,
# which helps on managed machines that block new unsigned programs.
#
# Other settings: $env:HAZE_VERSION picks a release (for example v0.1.0),
# $env:HAZE_INSTALL_DIR picks where haze.exe goes (the default is
# %LOCALAPPDATA%\Programs\haze), $env:HAZE_ARCHIVE installs from an archive that is already
# downloaded, and $env:HAZE_SOURCE_DIR builds from a local checkout.
$ErrorActionPreference = "Stop"
$repo = "ritabratamaiti/haze-lang"
$dir = if ($env:HAZE_INSTALL_DIR) { $env:HAZE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\haze" }
$fromSource = [bool]$env:HAZE_FROM_SOURCE -or [bool]$env:HAZE_SOURCE_DIR
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("haze-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null

# The newest release's tag, read from where github.com/OWNER/REPO/releases/latest redirects. Unlike
# the API, that page isn't rate limited for machines that share an IP address.
function Get-LatestVersion {
  try {
    $req = [System.Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest")
    $req.AllowAutoRedirect = $false
    $req.Method = "HEAD"
    $req.UserAgent = "haze-install"
    try { $resp = $req.GetResponse() } catch [System.Net.WebException] { $resp = $_.Exception.Response }
    $location = $resp.Headers["Location"]
    $resp.Close()
    if ($location -match '/releases/tag/([^/?#]+)$') { return $Matches[1] }
  } catch {}
  try { (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name } catch { "" }
}

try {
  if ($fromSource) {
    if ($env:HAZE_SOURCE_DIR) {
      $src = $env:HAZE_SOURCE_DIR
    } else {
      if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "Building from source needs git." }
      $version = if ($env:HAZE_VERSION) { $env:HAZE_VERSION } else { Get-LatestVersion }
      if (-not $version) { $version = "main" }
      Write-Host "Fetching the Haze source ($version)"
      $src = Join-Path $tmp "src"
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch $version "https://github.com/$repo.git" $src
      if ($LASTEXITCODE -ne 0) { throw "git clone failed." }
    }
    $elanBin = Join-Path $env:USERPROFILE ".elan\bin"
    if (-not (Get-Command lake -ErrorAction SilentlyContinue)) {
      if (-not (Test-Path (Join-Path $elanBin "lake.exe"))) {
        Write-Host "Installing elan, the Lean toolchain manager"
        $init = Join-Path $tmp "elan-init.ps1"
        Invoke-WebRequest https://raw.githubusercontent.com/leanprover/elan/master/elan-init.ps1 -OutFile $init
        & $init -NoPrompt 1 -DefaultToolchain none
      }
      $env:Path = "$elanBin;$env:Path"
    }
    Write-Host "Building Haze (the first build downloads the Lean toolchain and takes a few minutes)"
    Push-Location $src
    try { lake build haze; if ($LASTEXITCODE -ne 0) { throw "lake build failed." } } finally { Pop-Location }
    $built = Join-Path $src ".lake\build\bin\haze.exe"
  } else {
    $zip = Join-Path $tmp "haze.zip"
    if ($env:HAZE_ARCHIVE) {
      Copy-Item $env:HAZE_ARCHIVE $zip
    } else {
      $version = if ($env:HAZE_VERSION) { $env:HAZE_VERSION } else { Get-LatestVersion }
      if (-not $version) { throw "Could not find the latest Haze release." }
      $asset = "haze-$version-x86_64-windows.zip"
      $base = "https://github.com/$repo/releases/download/$version"
      Write-Host "Downloading Haze $version"
      Invoke-WebRequest "$base/$asset" -OutFile $zip
      # check the archive against the checksums published with the release
      $sums = (Invoke-WebRequest "$base/SHA256SUMS" -UseBasicParsing).Content
      if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
      $line = $sums -split "`n" | Where-Object { $_ -match " $([regex]::Escape($asset))\s*$" } | Select-Object -First 1
      $expected = if ($line) { ($line -split "\s+")[0] } else { "" }
      $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
      if (-not $expected -or $expected -ne $actual) {
        throw "The download doesn't match the release checksum; not installing."
      }
    }
    Expand-Archive $zip -DestinationPath $tmp
    $built = (Get-ChildItem -Path $tmp -Recurse -Filter haze.exe | Select-Object -First 1).FullName
  }

  New-Item -ItemType Directory -Force $dir | Out-Null
  $installed = Join-Path $dir "haze.exe"
  Copy-Item $built $installed -Force
  Unblock-File $installed
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not ($userPath -split ";" | Where-Object { $_ -eq $dir })) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
    Write-Host "Added $dir to your PATH. Open a new terminal to use it."
  }
  # antivirus software may hold a new executable for a moment while it scans it
  $version = $null
  for ($i = 0; $i -lt 3 -and -not $version; $i++) {
    try { $version = & $installed --version } catch { Start-Sleep -Seconds 1 }
  }
  if ($version) {
    Write-Host "Installed $version to $dir"
  } else {
    Write-Host "Installed haze to $dir, but Windows didn't let it run yet."
    Write-Host "Managed devices often block new unsigned programs. Building from source usually"
    Write-Host "avoids this: set `$env:HAZE_FROM_SOURCE = '1' and run the installer again."
  }
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
