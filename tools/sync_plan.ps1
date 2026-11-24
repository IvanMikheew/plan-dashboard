<#
.SYNOPSIS
  sync_plan.ps1 — автозаливка плана: шифрует ПЛАН.md и коммитит data/plan.enc в GitHub-репо.

.DESCRIPTION
  1. Берёт markdown-план (по умолчанию C:\Users\user\Desktop\ПЛАН.md).
  2. Шифрует через tools/crypt.js (AES-256-GCM, PBKDF2-SHA256 200k, формат base64(salt‖iv‖ct)).
  3. Коммитит data/plan.enc в репозиторий через GitHub REST API (PUT /contents).

  ПАРОЛЬ — только из переменной окружения PLAN_PASSWORD (не аргумент, не файл, не лог).
  Пример запуска (PowerShell):
      $env:PLAN_PASSWORD = '...'
      .\tools\sync_plan.ps1

  Токен GitHub — из переменной окружения GITHUB_TOKEN либо из .env (GITHUB_TOKEN=...).
  Токен никогда не пишется в лог/ответ/репо.

.PARAMETER PlanPath
  Путь к markdown-плану. По умолчанию C:\Users\user\Desktop\ПЛАН.md

.PARAMETER Repo
  Репозиторий owner/name. По умолчанию IvanMikheew/plan-dashboard

.PARAMETER Message
  Сообщение коммита. По умолчанию — "plan: обновление <дата>".
#>
param(
  [string]$PlanPath = 'C:\Users\user\Desktop\ПЛАН.md',
  [string]$Repo     = 'IvanMikheew/plan-dashboard',
  [string]$Message  = '',
  [string]$EnvFile  = 'C:\Users\user\Desktop\opencode\.env'
)
$ErrorActionPreference = 'Stop'

function Fail([string]$msg, [int]$code) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit $code
}

# --- 1. Пароль: из окружения, либо ввод скрытым текстом -----------------------
if (-not $env:PLAN_PASSWORD) {
  Write-Host 'Введите пароль шифрования плана (ввод скрыт):'
  $sec = Read-Host -AsSecureString 'Пароль'
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $env:PLAN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $env:PLAN_PASSWORD) {
  Fail 'Пароль пуст. Запустите скрипт заново и введите пароль.' 2
}
if (-not (Test-Path -LiteralPath $PlanPath)) {
  Fail "Файл плана не найден: $PlanPath" 3
}

# --- 2. Токен GitHub из окружения или .env ----------------------------------
$token = $env:GITHUB_TOKEN
if (-not $token) {
  if (-not (Test-Path -LiteralPath $EnvFile)) { Fail "Файл .env не найден: $EnvFile" 4 }
  $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^GITHUB_TOKEN=' } | Select-Object -First 1
  if (-not $line) { Fail "Ключ GITHUB_TOKEN не найден в $EnvFile" 4 }
  $token = ($line -replace '^GITHUB_TOKEN=', '').Trim()
}
if (-not $token) { Fail 'GITHUB_TOKEN пуст' 4 }

# --- 3. Шифрование через node (tools/crypt.js) ------------------------------
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { Fail 'node не найден в PATH (нужен Node.js 18+)' 5 }
$cryptJs = Join-Path $PSScriptRoot 'crypt.js'
if (-not (Test-Path -LiteralPath $cryptJs)) { Fail "crypt.js не найден: $cryptJs" 5 }

Write-Host "Шифрую: $PlanPath"
$b64 = (& node $cryptJs encrypt --in $PlanPath | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail "crypt.js encrypt завершился с кодом $LASTEXITCODE" 5 }
if (-not $b64) { Fail 'crypt.js вернул пустой результат' 5 }
Write-Host "Шифротекст: $($b64.Length) символов base64 (AES-256-GCM)"

# --- 4. Коммит data/plan.enc через GitHub API --------------------------------
$headers = @{
  Authorization           = "Bearer $token"
  'User-Agent'            = 'plan-dashboard-sync'
  Accept                  = 'application/vnd.github+json'
  'X-GitHub-Api-Version'  = '2022-11-28'
}
$apiUrl = "https://api.github.com/repos/$Repo/contents/data/plan.enc"
if (-not $Message) { $Message = 'plan: обновление ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

# существующий файл → нужен sha для update
$sha = $null
try {
  $existing = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $headers
  $sha = $existing.sha
  Write-Host 'data/plan.enc уже существует — будет обновлён'
} catch {
  $status = 0
  try { $status = [int]$_.Exception.Response.StatusCode } catch {}
  if ($status -ne 404) { Fail "GET contents: HTTP $status" 6 }
  Write-Host 'data/plan.enc не найден — будет создан'
}

$fileB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($b64))
$bodyObj = @{ message = $Message; content = $fileB64 }
if ($sha) { $bodyObj['sha'] = $sha }
$json = $bodyObj | ConvertTo-Json

try {
  $resp = Invoke-RestMethod -Method Put -Uri $apiUrl -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json))
} catch {
  $status = 0
  try { $status = [int]$_.Exception.Response.StatusCode } catch {}
  Fail "PUT contents: HTTP $status — $($_.Exception.Message)" 6
}

Write-Host "OK: data/plan.enc закоммичен" -ForegroundColor Green
Write-Host "  commit: $($resp.commit.sha)"
Write-Host "  content: https://github.com/$Repo/blob/main/data/plan.enc"
Write-Host 'Страница обновится после сборки GitHub Pages (1–2 мин).'
exit 0
