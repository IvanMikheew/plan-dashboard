# sync_all.ps1 — авто-заливка плана и статистики Авито на GitHub Pages.
# Пароль и токен берутся из .env (локально). Запуск по расписанию (каждый час).
$ErrorActionPreference = 'Stop'
$envFile = 'C:\Users\user\Desktop\opencode\.env'
$root = 'C:\Users\user\Desktop\opencode\plan-dashboard'

foreach ($line in (Get-Content -LiteralPath $envFile)) {
  if ($line -match '^\s*([^#=]+)=(.*)$') {
    $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
    if ($k -in @('PLAN_PASSWORD','GITHUB_TOKEN')) { Set-Item "env:$k" $v }
  }
}
if (-not $env:PLAN_PASSWORD) { Write-Output 'FAIL: PLAN_PASSWORD нет в .env'; exit 1 }

& powershell -ExecutionPolicy Bypass -File "$root\tools\sync_plan.ps1" | Write-Output
& powershell -ExecutionPolicy Bypass -File "$root\tools\sync_avito.ps1" | Write-Output
Write-Output "SYNC_ALL done $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
