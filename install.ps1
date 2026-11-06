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
    $url = "https://github.com/$repo/releases/download/$version/haze-$version-x86_64-windows.zip"
    Write-Host "Downloading Haze $version"
    Invoke-WebRequest $url -OutFile $zip
  }
  Expand-Archive $zip -DestinationPath $tmp
  New-Item -ItemType Directory -Force $dir | Out-Null
  $exe = Get-ChildItem -Path $tmp -Recurse -Filter haze.exe | Select-Object -First 1
  Copy-Item $exe.FullName (Join-Path $dir "haze.exe") -Force
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not ($userPath -split ";" | Where-Object { $_ -eq $dir })) {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$dir", "User")
    Write-Host "Added $dir to your PATH. Open a new terminal to use it."
  }
  Write-Host ("Installed " + (& (Join-Path $dir "haze.exe") --version) + " to $dir")
} finally {
  Remove-Item -Recurse -Force $tmp
}
