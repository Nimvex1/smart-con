# setup-foundry.ps1 — one-shot Foundry installer for Windows
# ------------------------------------------------------------------
# Installs Foundry v1.8.1 (forge, cast, anvil, chisel, solar) into
# %USERPROFILE%\foundry and adds that folder to the *user* PATH.
# Safe to re-run: it skips work that is already done.
#
# Usage (from this project's folder, in PowerShell):
#   powershell -ExecutionPolicy Bypass -File .\setup-foundry.ps1
# ------------------------------------------------------------------

$ErrorActionPreference = "Stop"
# Invoke-WebRequest's progress UI drastically throttles downloads on PS 5.1
$ProgressPreference = "SilentlyContinue"

$version  = "v1.8.1"
$sha256   = "02D98FC2C573793960EE06B7F642487D483FE30572F7E248804C207334A418D8"
$fileName = "foundry_v1.8.1_win32_amd64.zip"
$url      = "https://github.com/foundry-rs/foundry/releases/download/$version/$fileName"
$dest     = Join-Path $env:USERPROFILE "foundry"
$zipPath  = Join-Path $env:TEMP $fileName

if (Get-Command forge -ErrorAction SilentlyContinue) {
    Write-Host "forge is already installed and on PATH:" (Get-Command forge).Source
    Write-Host "Nothing to do. You can run 'forge build' and 'forge test' right now."
    exit 0
}

if (Test-Path (Join-Path $dest "forge.exe")) {
    Write-Host "Foundry already extracted in $dest - just making sure PATH is set."
} else {
    Write-Host "Downloading Foundry $version (~98 MB) from GitHub releases..."
    # Ensure TLS 1.2 for older Windows / PowerShell 5.1 defaults
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $zipPath

    Write-Host "Verifying SHA-256 checksum..."
    $hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
    if ($hash -ne $sha256) {
        Remove-Item $zipPath -ErrorAction SilentlyContinue
        throw "Checksum mismatch! Expected $sha256, got $hash. Download discarded, nothing installed."
    }
    Write-Host "Checksum OK."

    Write-Host "Extracting forge / cast / anvil / chisel / solar to $dest ..."
    Expand-Archive -Path $zipPath -DestinationPath $dest -Force
    Remove-Item $zipPath
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $userPath) { $userPath = "" }
if ($userPath -notlike "*$dest*") {
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$dest", "User")
    Write-Host "Added $dest to your user PATH."
} else {
    Write-Host "$dest is already on your user PATH."
}

Write-Host ""
Write-Host "Done! IMPORTANT: close this window and open a NEW PowerShell window, then run:"
Write-Host "    forge --version     # should print forge 1.8.1 ..."
Write-Host "    cd <this project folder>"
Write-Host "    forge build"
Write-Host "    forge test"
