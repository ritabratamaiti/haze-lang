# Installs the latest release of Haze on Windows.
#
#   irm https://raw.githubusercontent.com/ritabratamaiti/haze-lang/main/install.ps1 | iex
#
# Set $env:HAZE_VERSION to install a particular release (for example v0.1.0),
# $env:HAZE_INSTALL_DIR to choose where haze.exe goes (the default is
# %LOCALAPPDATA%\Programs\haze), or $env:HAZE_ARCHIVE to install from an archive that is already
# downloaded.
$ErrorActionPreference = "Stop"
$repo = "ritabratamaiti/haze-lang"
$dir = if ($env:HAZE_INSTALL_DIR) { $env:HAZE_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\haze" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("haze-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $zip = Join-Path $tmp "haze.zip"
  if ($env:HAZE_ARCHIVE) {
    Copy-Item $env:HAZE_ARCHIVE $zip
  } else {
    $version = $env:HAZE_VERSION
    if (-not $version) {
      $version = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest").tag_name
    }
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
  New-Item -ItemType Directory -Force $dir | Out-Null
  $exe = Get-ChildItem -Path $tmp -Recurse -Filter haze.exe | Select-Object -First 1
  $installed = Join-Path $dir "haze.exe"
  Copy-Item $exe.FullName $installed -Force
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
    Write-Host "Managed devices often block new unsigned programs; if haze keeps failing with"
    Write-Host "'Access is denied', ask your IT department to allow it, or build Haze from source."
  }
} finally {
  Remove-Item -Recurse -Force $tmp
}
