<#
.SYNOPSIS
  calendar_api.ps1 — записи клиентов из Google Calendar через веб-API
  (Google Apps Script, см. apps_script_setup.md) с фолбэком на ICS.

.DESCRIPTION
  1. URL API — из переменной окружения или .env (CALENDAR_API_URL; значение
     не печатается). Пусто → сообщение «CALENDAR_API_URL не задан — используем
     ICS» и запуск calendar_stats.ps1 (текущий ICS-парсинг) — ничего не ломается.
  2. Диапазон дат — как в calendar_stats: все даты CSV (или -From/-To).
  3. GET <URL>?from=yyyy-MM-dd&to=yyyy-MM-dd → JSON-массив
     [{summary, start, end, allDay, marked}] (marked: new|old|null).
     Для тестов URL может быть локальным файлом (.json / file://).
  4. Считает по дням события с marked new/old (день — по start: UTC → +7,
     Asia/Krasnoyarsk), обновляет CSV: колонки запись_старые/записи_новые
     перед «источник», «записи» = сумма, но только если > 0. Логика CSV
     повторяет calendar_stats.ps1 (файлы ведутся независимо).
  5. Запрос упал / ответ не массив → WARN и фолбэк на calendar_stats.ps1.
  В лог НЕ пишутся названия событий (в них имена клиентов).

.PARAMETER From, -To
  Диапазон дат YYYY-MM-DD. По умолчанию — все даты из CSV.

.PARAMETER NoUpdate
  Только посчитать и напечатать, CSV не изменять.

.PARAMETER CsvPath / EnvFile
  Пути по умолчанию: отчёты\статистика-авито.csv и opencode\.env.

.EXAMPLE
  .\tools\calendar_api.ps1 -From 2026-11-15 -To 2026-11-24 -NoUpdate
#>
param(
  [string]$CsvPath = 'C:\Users\user\Desktop\opencode\отчёты\статистика-авито.csv',
  [string]$EnvFile = 'C:\Users\user\Desktop\opencode\.env',
  [string]$From    = '',
  [string]$To      = '',
  [switch]$NoUpdate
)
$ErrorActionPreference = 'Stop'

function Fail([string]$msg, [int]$code) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  exit $code
}

# значение ключа: окружение → .env (значение не печатаем)
function Get-EnvValue([string]$name, [string]$envFile) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($v) { return $v.Trim() }
  if (Test-Path -LiteralPath $envFile) {
    $rx = '^\s*' + [regex]::Escape($name) + '\s*=\s*'
    $line = Get-Content -LiteralPath $envFile -Encoding UTF8 |
      Where-Object { $_ -match $rx } | Select-Object -First 1
    if ($line) { return (($line -replace $rx, '').Trim().Trim('"').Trim("'")) }
  }
  return ''
}

# фолбэк: текущий ICS-парсинг calendar_stats.ps1 (дочерний процесс, его exit-код)
function Invoke-IcsFallback([string]$msg = '') {
  if ($msg) { Write-Host "WARN: $msg — используем ICS (calendar_stats.ps1)" -ForegroundColor Yellow }
  $calScript = Join-Path $PSScriptRoot 'calendar_stats.ps1'
  if (-not (Test-Path -LiteralPath $calScript)) { Fail "calendar_stats.ps1 не найден: $calScript" 2 }
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $calScript,
         '-CsvPath', $CsvPath, '-EnvFile', $EnvFile)
  if ($From)   { $a += @('-From', $From) }
  if ($To)     { $a += @('-To', $To) }
  if ($NoUpdate) { $a += '-NoUpdate' }
  & powershell @a
  exit $LASTEXITCODE
}

# --- 1. URL API ---------------------------------------------------------------
$apiUrl = Get-EnvValue 'CALENDAR_API_URL' $EnvFile
if (-not $apiUrl) {
  Write-Host 'CALENDAR_API_URL не задан — используем ICS'
  Invoke-IcsFallback
}

# --- 2. Диапазон дат (все даты CSV, как в calendar_stats) --------------------
if (-not (Test-Path -LiteralPath $CsvPath)) { Fail "CSV не найден: $CsvPath" 3 }
$csvLines = @(Get-Content -LiteralPath $CsvPath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
if ($csvLines.Count -lt 2) { Fail 'CSV пуст' 3 }
$csvCols = @($csvLines[0] -split ',')
$di = [array]::IndexOf($csvCols, 'дата')
if ($di -lt 0) { Fail 'в CSV нет колонки «дата»' 3 }
$csvDates = @()
foreach ($l in ($csvLines | Select-Object -Skip 1)) {
  $f = @($l -split ',')
  if ($di -lt $f.Count -and $f[$di] -match '^\d{4}-\d{2}-\d{2}$') { $csvDates += $f[$di] }
}
$csvDates = @($csvDates | Sort-Object -Unique)
if ($csvDates.Count -eq 0) { Fail 'в CSV нет дат' 3 }
if (-not $From) { $From = $csvDates[0] }
if (-not $To)   { $To   = $csvDates[$csvDates.Count - 1] }
try {
  $rangeStart = [datetime]::ParseExact($From, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  $rangeEnd   = [datetime]::ParseExact($To,   'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
} catch { Fail "некорректные даты -From/-To (ожидается YYYY-MM-DD): $From .. $To" 3 }
if ($rangeEnd -lt $rangeStart) { Fail '-To раньше -From' 3 }

# --- 3. Запрос к API (2 попытки; для тестов — локальный JSON-файл) -----------
function Get-ApiJson([string]$url, [string]$from, [string]$to) {
  if ($url -match '^(file://|[A-Za-z]:\\|\\\\)') {
    return [IO.File]::ReadAllText(($url -replace '^file://', ''), [Text.Encoding]::UTF8)
  }
  $sep = '?'; if ($url -match '\?') { $sep = '&' }
  $req = $url + $sep + 'from=' + $from + '&to=' + $to
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $lastErr = $null
  for ($i = 1; $i -le 2; $i++) {
    try {
      $wc = New-Object Net.WebClient
      $wc.Headers.Add('User-Agent', 'plan-dashboard-calendar/1.0')
      $wc.Encoding = [Text.Encoding]::UTF8
      return $wc.DownloadString($req)
    } catch {
      $lastErr = $_.Exception.Message
      if ($i -lt 2) { Start-Sleep -Seconds 3 }
    }
  }
  throw $lastErr
}

try { $text = Get-ApiJson $apiUrl $From $To }
catch { Invoke-IcsFallback "запрос к CALENDAR_API_URL упал: $($_.Exception.Message)" }

try { $raw = $text | ConvertFrom-Json }
catch { Invoke-IcsFallback "ответ CALENDAR_API_URL не JSON: $($_.Exception.Message)" }

$events = @()
if ($null -ne $raw) { $events = @($raw) }
elseif ("$text".Trim() -ne '[]') { Invoke-IcsFallback 'ответ CALENDAR_API_URL пуст' }
if ($events.Count -gt 0) {
  if ($events[0].PSObject.Properties['error']) {
    Invoke-IcsFallback "CALENDAR_API_URL вернул ошибку: $($events[0].error)"
  }
  if (-not $events[0].PSObject.Properties['start']) {
    Invoke-IcsFallback 'ответ CALENDAR_API_URL не массив событий'
  }
}

# --- 4. Подсчёт по дням (start: ISO UTC → +7 Asia/Krasnoyarsk) ---------------
$perDay = @{}; $inRange = 0; $markedNew = 0; $markedOld = 0
foreach ($ev in $events) {
  if (-not $ev.PSObject.Properties['start']) { continue }
  $iso = "$($ev.start)"
  if (-not $iso) { continue }
  try {
    $dto = [datetimeoffset]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture)
  } catch { continue }
  $d = $dto.ToOffset([TimeSpan]::FromHours(7)).DateTime.Date
  if ($d -lt $rangeStart -or $d -gt $rangeEnd) { continue }
  $inRange++
  $marked = $null
  if ($ev.PSObject.Properties['marked'] -and "$($ev.marked)") {
    $marked = "$($ev.marked)".ToLower()
  } elseif ($ev.PSObject.Properties['summary']) {
    # фолбэк: marked не пришёл — считаем по названию (как в calendar_stats)
    $s = "$($ev.summary)"
    if ($s -match '(?i)стары') { $marked = 'old' }
    elseif ($s -match '(?i)новы') { $marked = 'new' }
  }
  if ($marked -ne 'new' -and $marked -ne 'old') { continue }
  $key = $d.ToString('yyyy-MM-dd')
  if (-not $perDay.ContainsKey($key)) { $perDay[$key] = @{ new = 0; old = 0 } }
  if ($marked -eq 'old') { $perDay[$key].old++; $markedOld++ } else { $perDay[$key].new++; $markedNew++ }
}

# --- 5. Вывод (без названий событий — там имена клиентов) --------------------
Write-Host "API: событий получено $($events.Count), в диапазоне $From..$To — $inRange"
Write-Host "С пометкой: новый — $markedNew, старый — $markedOld, всего помеченных — $($markedNew + $markedOld)"
Write-Host ('{0,-12} {1,6} {2,6}' -f 'дата', 'старые', 'новые')
foreach ($k in ($csvDates | Where-Object { $_ -ge $From -and $_ -le $To } | Sort-Object)) {
  $o = 0; $nw = 0
  if ($perDay.ContainsKey($k)) { $o = $perDay[$k].old; $nw = $perDay[$k].new }
  Write-Host ('{0,-12} {1,6} {2,6}' -f $k, $o, $nw)
}
if ($NoUpdate) { Write-Host 'CSV не изменялся (-NoUpdate)'; exit 0 }

# --- 6. Обновление CSV: колонки запись_старые/записи_новые перед «источник» -
# Логика идентична calendar_stats.ps1 (файлы ведутся независимо).
$oldName = 'записи_старые'; $newName = 'записи_новые'
$outCols = @($csvCols)
if ($outCols -notcontains $oldName -or $outCols -notcontains $newName) {
  $si = [array]::IndexOf($outCols, 'источник')
  if ($si -lt 0) { $si = $outCols.Count }
  $head = @($outCols[0..($si - 1)])
  $tail = @($outCols[$si..($outCols.Count - 1)])
  $head2 = @()
  $hasOld = $outCols -contains $oldName; $hasNew = $outCols -contains $newName
  if (-not $hasOld) { $head2 += $oldName }
  if (-not $hasNew) { $head2 += $newName }
  $outCols = @($head) + $head2 + $tail
}

$outLines = @(($outCols) -join ',')
$updatedRows = 0
foreach ($line in ($csvLines | Select-Object -Skip 1)) {
  $f = @($line -split ',')
  $row = @{}
  for ($i = 0; $i -lt $csvCols.Count; $i++) {
    $row[$csvCols[$i]] = if ($i -lt $f.Count) { $f[$i] } else { '' }
  }
  $date = "$($row['дата'])".Trim()
  if ($date -ge $From -and $date -le $To) {
    $o = 0; $nw = 0
    if ($perDay.ContainsKey($date)) { $o = $perDay[$date].old; $nw = $perDay[$date].new }
    $row[$oldName] = "$o"
    $row[$newName] = "$nw"
    $sum = $o + $nw
    if ($sum -gt 0) { $row['записи'] = "$sum" }   # 0 пометок = данных нет, оставляем как есть
    $updatedRows++
  } else {
    if (-not $row.ContainsKey($oldName)) { $row[$oldName] = '' }
    if (-not $row.ContainsKey($newName)) { $row[$newName] = '' }
  }
  $vals = @()
  foreach ($c in $outCols) { $vals += "$($row[$c])" }
  $outLines += ($vals -join ',')
}

[IO.File]::WriteAllLines($CsvPath, $outLines, [Text.UTF8Encoding]::new($false))
Write-Host ("CSV обновлён: {0} строк, колонки {1},{2} ({3})" -f $updatedRows, $oldName, $newName, $CsvPath) -ForegroundColor Green
exit 0
