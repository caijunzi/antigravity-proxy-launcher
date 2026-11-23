$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$launcherSrc = Join-Path $repoRoot "launcher"
$distDir = Join-Path $repoRoot "dist"
$pkgName = "Antigravity通用代理启动器-绿色版"
$stageDir = Join-Path $distDir $pkgName
$zipPath = Join-Path $distDir "$pkgName.zip"

if (-not (Test-Path -LiteralPath (Join-Path $launcherSrc "core\launch.ps1"))) {
    throw "Missing launcher/core/launch.ps1"
}

if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

Copy-Item -Path "$launcherSrc\*" -Destination $stageDir -Recurse -Force
Compress-Archive -LiteralPath $stageDir -DestinationPath $zipPath -CompressionLevel Optimal
Remove-Item -LiteralPath $stageDir -Recurse -Force

Write-Host "[OK] Release archive created: $zipPath ($((Get-Item -LiteralPath $zipPath).Length) bytes)" -ForegroundColor Green
