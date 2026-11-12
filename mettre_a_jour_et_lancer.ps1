param(
  [string]$TargetName = "ma_reserve_app",
  [string]$TargetPath = ""
)

$ErrorActionPreference = 'Stop'
$SourceRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TargetPath)) {
  $TargetPath = Join-Path $SourceRoot $TargetName
}
$TargetPath = [System.IO.Path]::GetFullPath($TargetPath)

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Host "Flutter n'est pas trouve dans le PATH. Verifie l'installation de Flutter." -ForegroundColor Red
  exit 1
}
if (-not (Test-Path (Join-Path $TargetPath 'pubspec.yaml'))) {
  Write-Host "Le projet cible n'existe pas ou ne contient pas pubspec.yaml : $TargetPath" -ForegroundColor Red
  Write-Host "Indique le dossier racine du projet Flutter utilise avec -TargetPath."
  exit 1
}

Write-Host "1/3 - Copie du code Ma Reserve V2.0..." -ForegroundColor Cyan
$TargetLib = Join-Path $TargetPath 'lib'
if (-not (Test-Path $TargetLib)) { New-Item -ItemType Directory -Path $TargetLib | Out-Null }
Copy-Item -Path (Join-Path $SourceRoot 'lib\*') -Destination $TargetLib -Recurse -Force
Copy-Item -Path (Join-Path $SourceRoot 'pubspec.yaml') -Destination (Join-Path $TargetPath 'pubspec.yaml') -Force
if (Test-Path (Join-Path $SourceRoot 'analysis_options.yaml')) {
  Copy-Item -Path (Join-Path $SourceRoot 'analysis_options.yaml') -Destination (Join-Path $TargetPath 'analysis_options.yaml') -Force
}

Write-Host "2/3 - Mise a jour des dependances..." -ForegroundColor Cyan
Push-Location $TargetPath
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get a echoue." }
  Write-Host "3/3 - Lancement de Ma Reserve V2.0 dans Chrome..." -ForegroundColor Green
  flutter run -d chrome
  if ($LASTEXITCODE -ne 0) { throw "Le lancement a echoue. Consulte les messages Flutter ci-dessus." }
}
finally {
  Pop-Location
}
