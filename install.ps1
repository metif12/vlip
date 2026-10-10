$ErrorActionPreference = 'Stop'

$BlipDir = if ($env:BLIP_INSTALL_DIR) { $env:BLIP_INSTALL_DIR } else { "$HOME\.blip" }
$Repo = 'https://github.com/metif12/blip.git'

Write-Host "==> Installing blip to $BlipDir"

if (-not (Test-Path $BlipDir)) {
    git clone $Repo $BlipDir
}

Set-Location $BlipDir
git pull --ff-only

if (-not (Get-Command v -ErrorAction SilentlyContinue)) {
    Write-Host "==> V not found. Installing V..."
    $VDir = "$HOME\.v"
    if (-not (Test-Path $VDir)) {
        git clone https://github.com/vlang/v $VDir
    }
    Set-Location $VDir
    & "$VDir\make.bat"
    $env:PATH = "$VDir;$env:PATH"
    Set-Location $BlipDir
}

v -cc gcc -o "$BlipDir\blip.exe" blip.v

Write-Host "==> blip installed to $BlipDir\blip.exe"
Write-Host "==> Add to your PATH: `$env:PATH = `"$BlipDir;`$env:PATH`""
