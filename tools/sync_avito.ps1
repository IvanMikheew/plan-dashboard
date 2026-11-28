<#
.SYNOPSIS
  sync_avito.ps1 — шифрует CSV статистики Авито в data/avito.enc и коммитит его в GitHub-репо.

.DESCRIPTION
  1. Шаг calendar_api.ps1: свежие колонки записей из Google Calendar — через
     веб-API (CALENDAR_API_URL в .env, см. apps_script_setup.md), при пустом
     URL или ошибке запроса — фолбэк на ICS (CALENDAR_ICS_URL, calendar_stats.ps1)
     → колонки запись_старые/записи_новые в CSV.
     Неблокирующий: ошибка календаря не прерывает заливку (WARN).
  2. Читает CSV статистики (дата,объявление_id,показы,просмотры,контакты,записи,
     запись_старые,записи_новые,источник).
  3. Превращает в JSON {updated, rows[], edits[]} (edits — даты правок из журнала
     изменений; rows — bookings, bookingsOld, bookingsNew).
  4. Шифрует через tools/crypt.js (AES-256-GCM, PBKDF2-SHA256 200k,
     формат base64(salt‖iv‖ct)) — ТОТ ЖЕ пароль и формат, что у плана.
  5. Коммитит data/avito.enc в репозиторий через GitHub REST API (PUT /contents).

  ПАРОЛЬ — только из переменной окружения PLAN_PASSWORD (не аргумент, не файл, не лог).
  Пример запуска (PowerShell):
      $env:PLAN_PASSWORD = '...'
      .\tools\sync_avito.ps1
  Токен GitHub — из GITHUB_TOKEN либо из .env; никогда не пишется в лог/репо.

.PARAMETER CsvPath
  Путь к CSV статистики. По умолчанию:
  C:\Users\user\Desktop\opencode\отчёты\статистика-авито.csv

.PARAMETER EditJournal
  Журнал правок (даты строками "- ГГГГ-ММ-ДД — ..."). По умолчанию:
  C:\Users\user\Desktop\opencode\объявление по массажу на авито\журнал-изменений.md

.PARAMETER Repo
  Репозиторий owner/name. По умолчанию IvanMikheew/plan-dashboard

.PARAMETER Message
  Сообщение коммита. По умолчанию — "avito: обновление <дата>".
#>
param(
  [string]$CsvPath       = 'C:\Users\user\Desktop\opencode\отчёты\статистика-авито.csv',
  [string]$EditJournal   = 'C:\Users\user\Desktop\opencode\объявление по массажу на авито\журнал-изменений.md',
  [string]$Repo          = 'IvanMikheew/plan-dashboard',
  [string]$Message       = '',
  [string]$EnvFile       = 'C:\Users\user\Desktop\opencode\.env',
  [switch]$LocalOnly     # только записать data/avito.enc локально, без коммита в GitHub
)
$ErrorActionPreference = 'Stop'

function Fail([string]$msg, [int]$code) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit $code
}

# --- 1. Пароль: из окружения либо ввод скрытым текстом -----------------------
if (-not $env:PLAN_PASSWORD) {
  Write-Host 'Введите пароль шифрования (тот же, что у плана; ввод скрыт):'
  $sec = Read-Host -AsSecureString 'Пароль'
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $env:PLAN_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $env:PLAN_PASSWORD) { Fail 'Пароль пуст. Запустите скрипт заново.' 2 }

if (-not (Test-Path -LiteralPath $CsvPath)) { Fail "CSV не найден: $CsvPath" 3 }

# --- 2. Токен GitHub из окружения или .env ----------------------------------
$token = $env:GITHUB_TOKEN
if (-not $token) {
  if (-not (Test-Path -LiteralPath $EnvFile)) { Fail "Файл .env не найден: $EnvFile" 4 }
  $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^GITHUB_TOKEN=' } | Select-Object -First 1
  if (-not $line) { Fail "Ключ GITHUB_TOKEN не найден в $EnvFile" 4 }
  $token = ($line -replace '^GITHUB_TOKEN=', '').Trim()
}
if (-not $token) { Fail 'GITHUB_TOKEN пуст' 4 }

# --- 2.5 Шаг calendar: обновить колонки записей из Google Calendar ----------
# Неблокирующий: календарь недоступен → WARN и заливка идёт по текущему CSV.
# calendar_api.ps1 сам фолбэчится на ICS (calendar_stats.ps1), если API не задан.
$calScript = Join-Path $PSScriptRoot 'calendar_api.ps1'
if (Test-Path -LiteralPath $calScript) {
  Write-Host 'calendar: обновляю колонки записей из Google Calendar…'
  & powershell -NoProfile -ExecutionPolicy Bypass -File $calScript -CsvPath $CsvPath
  if ($LASTEXITCODE -ne 0) {
    Write-Host "WARN: calendar_api завершился с кодом $LASTEXITCODE — колонки записей не обновлены" -ForegroundColor Yellow
  }
} else {
  Write-Host "WARN: calendar_api.ps1 не найден ($calScript) — пропускаю" -ForegroundColor Yellow
}

# --- 3. CSV -> JSON ---------------------------------------------------------
function Int-OrNull {
  # пустая ячейка CSV = данных нет -> null (в дашборде «—»), а НЕ 0:
  # Avito отдаёт свежие даты с задержкой T+1, 0 = «ещё не посчитано».
  param($v)
  if ($v -eq $null) { return $null }
  $s = "$v".Trim()
  if ($s -eq '') { return $null }
  return [int]$s
}

$rows = @(Import-Csv -LiteralPath $CsvPath -Encoding UTF8)
if ($rows.Count -eq 0) { Fail 'CSV пуст' 3 }

$outRows = @()
foreach ($r in $rows) {
  $bk = $null
  if ($r.записи -ne $null -and "$($r.записи)".Trim() -ne '') { $bk = [int]$r.записи }
  $bkOld = $null
  if ($r.PSObject.Properties['записи_старые'] -and "$($r.записи_старые)".Trim() -ne '') { $bkOld = [int]$r.записи_старые }
  $bkNew = $null
  if ($r.PSObject.Properties['записи_новые'] -and "$($r.записи_новые)".Trim() -ne '') { $bkNew = [int]$r.записи_новые }
  $outRows += [ordered]@{
    date        = "$($r.дата)".Trim()
    item        = "$($r.объявление_id)".Trim()
    impressions = (Int-OrNull $r.показы)
    views       = (Int-OrNull $r.просмотры)
    contacts    = (Int-OrNull $r.контакты)
    bookings    = $bk
    bookingsOld = $bkOld
    bookingsNew = $bkNew
    source      = "$($r.источник)".Trim()
  }
}
$outRows = @($outRows | Sort-Object { $_.date })
$updated = $outRows[-1].date

# даты правок из журнала (строки "- ГГГГ-ММ-ДД — ..."); файла может не быть
$edits = @()
if (Test-Path -LiteralPath $EditJournal) {
  $edits = @(Get-Content -LiteralPath $EditJournal -Encoding UTF8 |
    ForEach-Object { if ($_ -match '^-\s+(\d{4}-\d{2}-\d{2})\s+') { $Matches[1] } } |
    Sort-Object -Unique)
}

$data = [ordered]@{ updated = $updated; rows = $outRows; edits = $edits }
$json = $data | ConvertTo-Json -Compress -Depth 4
Write-Host "JSON: $($outRows.Count) строк, $($edits.Count) правок, updated=$updated"

# --- 4. Шифрование через node (tools/crypt.js) ------------------------------
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) { Fail 'node не найден в PATH (нужен Node.js 18+)' 5 }
$cryptJs = Join-Path $PSScriptRoot 'crypt.js'
if (-not (Test-Path -LiteralPath $cryptJs)) { Fail "crypt.js не найден: $cryptJs" 5 }

$tmpJson = Join-Path $env:TEMP ('avito-' + [Guid]::NewGuid().ToString('N') + '.json')
$tmpEnc  = $tmpJson + '.enc'
try {
  [IO.File]::WriteAllText($tmpJson, $json, [Text.UTF8Encoding]::new($false))
  & node $cryptJs encrypt --in $tmpJson --out $tmpEnc
  if ($LASTEXITCODE -ne 0) { Fail "crypt.js encrypt завершился с кодом $LASTEXITCODE" 5 }
  $b64 = [IO.File]::ReadAllText($tmpEnc, [Text.Encoding]::ASCII).Trim()
} finally {
  Remove-Item -LiteralPath $tmpJson, $tmpEnc -ErrorAction SilentlyContinue
}
if (-not $b64) { Fail 'crypt.js вернул пустой результат' 5 }
Write-Host "Шифротекст: $($b64.Length) символов base64 (AES-256-GCM)"

# --- 5. Локальная запись либо коммит data/avito.enc через GitHub API --------
if ($LocalOnly) {
  $localOut = Join-Path (Split-Path $PSScriptRoot -Parent) 'data\avito.enc'
  $dir = Split-Path $localOut -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  [IO.File]::WriteAllText($localOut, $b64, [Text.Encoding]::ASCII)
  Write-Host "OK (LocalOnly): $localOut ($($b64.Length) символов base64)" -ForegroundColor Green
  exit 0
}
$headers = @{
  Authorization           = "Bearer $token"
  'User-Agent'            = 'plan-dashboard-sync'
  Accept                  = 'application/vnd.github+json'
  'X-GitHub-Api-Version'  = '2022-11-28'
}
$apiUrl = "https://api.github.com/repos/$Repo/contents/data/avito.enc"
if (-not $Message) { $Message = 'avito: обновление ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

$sha = $null
try {
  $existing = Invoke-RestMethod -Method Get -Uri $apiUrl -Headers $headers
  $sha = $existing.sha
  Write-Host 'data/avito.enc уже существует — будет обновлён'
} catch {
  $status = 0
  try { $status = [int]$_.Exception.Response.StatusCode } catch {}
  if ($status -ne 404) { Fail "GET contents: HTTP $status" 6 }
  Write-Host 'data/avito.enc не найден — будет создан'
}

$fileB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($b64))
$bodyObj = @{ message = $Message; content = $fileB64 }
if ($sha) { $bodyObj['sha'] = $sha }
$jsonBody = $bodyObj | ConvertTo-Json

try {
  $resp = Invoke-RestMethod -Method Put -Uri $apiUrl -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($jsonBody))
} catch {
  $status = 0
  try { $status = [int]$_.Exception.Response.StatusCode } catch {}
  Fail "PUT contents: HTTP $status — $($_.Exception.Message)" 6
}

Write-Host "OK: data/avito.enc закоммичен" -ForegroundColor Green
Write-Host "  commit: $($resp.commit.sha)"
Write-Host 'Страница обновится после сборки GitHub Pages (1-2 мин).'
exit 0
