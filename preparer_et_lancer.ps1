param([string]$TargetName = "ma_reserve_app")
$ErrorActionPreference = 'Stop'
$SourceRoot = $PSScriptRoot
$TargetPath = Join-Path $SourceRoot $TargetName
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
  Write-Host "Flutter n'est pas trouve dans le PATH." -ForegroundColor Red
  exit 1
}
if (Test-Path $TargetPath) {
  Write-Host "Le dossier existe deja : $TargetPath. Utilise un autre -TargetName ou la mise a jour avec -TargetPath." -ForegroundColor Yellow
  exit 1
}
flutter create --project-name ma_reserve --platforms android,ios,web $TargetPath
if ($LASTEXITCODE -ne 0) { throw "flutter create a echoue." }
$TargetLib = Join-Path $TargetPath 'lib'
Copy-Item -Path (Join-Path $SourceRoot 'lib\*') -Destination $TargetLib -Recurse -Force
Copy-Item -Path (Join-Path $SourceRoot 'pubspec.yaml') -Destination (Join-Path $TargetPath 'pubspec.yaml') -Force
Copy-Item -Path (Join-Path $SourceRoot 'analysis_options.yaml') -Destination (Join-Path $TargetPath 'analysis_options.yaml') -Force
Push-Location $TargetPath
try {
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get a echoue." }
  flutter run -d chrome
  if ($LASTEXITCODE -ne 0) { throw "flutter run a echoue." }
}
finally { Pop-Location }
