<#
.SYNOPSIS
  calendar_stats.ps1 — записи клиентов из Google Calendar (ICS): считает по дням
  события с пометкой «новый» / «старый» в SUMMARY и обновляет CSV статистики.

.DESCRIPTION
  1. Скачивает ICS по ссылке CALENDAR_ICS_URL из .env (секрет: не логируется, не коммитится).
  2. Парсит VEVENT: раскрывает свёрнутые строки, разворачивает RRULE
     (FREQ/DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL), учитывает EXDATE
     и исключения RECURRENCE-ID (перенесённые/отменённые вхождения).
     Часовой пояс: TZID-время и «плавающее» время = местное (Asia/Krasnoyarsk, UTC+7);
     UTC (Z) → +7 ч.
  3. Для диапазона дат считает по дням: события, где SUMMARY содержит «новый»
     или «старый» (регистр не важен; пишутся также «новая/новые», «старая/старые»).
     События с STATUS:CANCELLED не считаются.
  4. Обновляет CSV: добавляет колонки запись_старые, запись_новые (перед «источник»)
     и заполняет их по дням. Колонка «записи» = новая+старая, но только если сумма > 0
     (0 пометок = данных нет, не ноль — пометок может ещё не быть).
  В лог НЕ пишутся названия событий (в них имена клиентов).

.PARAMETER From, -To
  Диапазон дат YYYY-MM-DD. По умолчанию — все даты из CSV.

.PARAMETER NoUpdate
  Только посчитать и напечатать, CSV не изменять.

.PARAMETER CsvPath / EnvFile
  Пути по умолчанию: отчёты\статистика-авито.csv и opencode\.env.

.EXAMPLE
  .\tools\calendar_stats.ps1 -From 2026-11-15 -To 2026-11-24
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

# --- 1. Ссылка на ICS: только из окружения или .env (значение не печатаем) ---
$icsUrl = $env:CALENDAR_ICS_URL
if (-not $icsUrl) {
  if (-not (Test-Path -LiteralPath $EnvFile)) { Fail ".env не найден: $EnvFile" 2 }
  $line = Get-Content -LiteralPath $EnvFile -Encoding UTF8 |
    Where-Object { $_ -match '^\s*CALENDAR_ICS_URL\s*=' } | Select-Object -First 1
  if (-not $line) { Fail 'CALENDAR_ICS_URL нет в .env' 2 }
  $icsUrl = ($line -replace '^\s*CALENDAR_ICS_URL\s*=\s*', '').Trim().Trim('"').Trim("'")
}
if (-not $icsUrl) { Fail 'CALENDAR_ICS_URL пуст' 2 }

# --- 2. Диапазон дат --------------------------------------------------------
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

# --- 3. Скачивание ICS (значение ссылки не печатаем) -------------------------
# для тестов CALENDAR_ICS_URL может быть локальным файлом (.ics) или file://
try {
  if ($icsUrl -match '^(file://|[A-Za-z]:\\|\\\\)') {
    $localIcs = $icsUrl -replace '^file://', ''
    $bytes = [IO.File]::ReadAllBytes($localIcs)
  } else {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object Net.WebClient
    $wc.Headers.Add('User-Agent', 'plan-dashboard-calendar/1.0')
    $bytes = $wc.DownloadData($icsUrl)
  }
} catch { Fail "чтение ICS: $($_.Exception.Message)" 4 }
if ($bytes.Length -ge 2 -and $bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
  $ms = New-Object IO.MemoryStream(, $bytes)
  $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
  $sr = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
  try { $ics = $sr.ReadToEnd() } finally { $sr.Close() }
} else {
  $ics = [Text.Encoding]::UTF8.GetString($bytes)
}
if ($ics -notmatch 'BEGIN:VCALENDAR') { Fail 'ответ не похож на ICS (нет BEGIN:VCALENDAR)' 4 }

# раскрытие свёрнутых строк (RFC 5545): continuation начинается с пробела/таба
$ics = $ics -replace "`r`n[ \t]", '' -replace "`n[ \t]", ''

# --- 4. Вспомогательные парсеры ---------------------------------------------
function Get-Prop([string]$block, [string]$name) {
  $m = [regex]::Match($block, "(?m)^$name[^:\r\n]*:([^\r\n]*)")
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return $null
}

# значение даты/времени ICS -> локальное DateTime (Asia/Krasnoyarsk, UTC+7)
function Convert-IcsDate([string]$params, [string]$val) {
  $val = $val.Trim()
  if ($val -match '^(\d{4})(\d{2})(\d{2})$') {
    return [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 0, 0, 0)
  }
  if ($val -match '^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})(Z?)$') {
    $dt = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3],
                          [int]$Matches[4], [int]$Matches[5], [int]$Matches[6])
    if ($Matches[7] -eq 'Z') { $dt = $dt.AddHours(7) }   # UTC -> UTC+7 (нет перехода на летнее время)
    return $dt
  }
  return $null
}

# --- 5. Разбор VEVENT --------------------------------------------------------
$blocks = [regex]::Matches($ics, '(?s)BEGIN:VEVENT(.*?)END:VEVENT')
$found = $blocks.Count
$evList = @()
$exclMap = @{}   # UID -> даты исключений (RECURRENCE-ID)
$badStart = 0

foreach ($m in $blocks) {
  $b = $m.Groups[1].Value
  $ms = [regex]::Match($b, '(?m)^DTSTART([^:\r\n]*):([^\r\n]+)')
  if (-not $ms.Success) { $badStart++; continue }
  $base = Convert-IcsDate $ms.Groups[1].Value $ms.Groups[2].Value
  if ($null -eq $base) { $badStart++; continue }
  $uid    = Get-Prop $b 'UID'
  $recIdV = Get-Prop $b 'RECURRENCE-ID'
  $status = Get-Prop $b 'STATUS'
  $summary= Get-Prop $b 'SUMMARY'
  $rrule  = Get-Prop $b 'RRULE'
  # EXDATE — исключённые вхождения (могут быть списком через запятую)
  $exdates = @()
  foreach ($mEx in [regex]::Matches($b, '(?m)^EXDATE([^:\r\n]*):([^\r\n]+)')) {
    foreach ($part in ($mEx.Groups[2].Value -split ',')) {
      $exd = Convert-IcsDate $mEx.Groups[1].Value $part
      if ($exd) { $exdates += $exd.Date }
    }
  }
  $ev = [pscustomobject]@{
    Uid = $uid; RecId = $null; Status = $status; Summary = $summary
    Base = $base; RRule = $rrule; Block = $b; ExDates = $exdates
  }
  if ($recIdV) {
    $msR = [regex]::Match($b, '(?m)^RECURRENCE-ID([^:\r\n]*):([^\r\n]+)')
    $rid = Convert-IcsDate $msR.Groups[1].Value $msR.Groups[2].Value
    $ev.RecId = $rid
    if ($uid -and $rid) {
      if (-not $exclMap.ContainsKey($uid)) { $exclMap[$uid] = New-Object System.Collections.Generic.List[datetime] }
      $exclMap[$uid].Add($rid.Date)
    }
  }
  $evList += $ev
}
if ($found -eq 0) { Fail 'в ICS нет VEVENT' 4 }

# --- 6. Разворот RRULE + подсчёт --------------------------------------------
$perDay = @{}      # 'yyyy-MM-dd' -> @{ new = n; old = n }
$inRange = 0; $markedNew = 0; $markedOld = 0
$knownFreq = @('DAILY', 'WEEKLY', 'MONTHLY', 'YEARLY')

foreach ($ev in $evList) {
  if ($ev.Status -and $ev.Status.ToUpper() -eq 'CANCELLED') { continue }

  # даты вхождений
  $occ = New-Object System.Collections.Generic.List[datetime]
  if ($ev.RecId) {
    # изменённое вхождение — само по себе (его слот исключён из мастер-события)
    $occ.Add($ev.Base)
  } elseif (-not $ev.RRule) {
    $occ.Add($ev.Base)
  } else {
    $freq = $null; $interval = 1; $count = $null; $until = $null
    foreach ($p in ($ev.RRule -split ';')) {
      $kv = $p -split '=', 2
      if ($kv.Count -lt 2) { continue }
      switch ($kv[0]) {
        'FREQ'     { $freq = $kv[1].ToUpper() }
        'INTERVAL' { $interval = [Math]::Max(1, [int]$kv[1]) }
        'COUNT'    { $count = [int]$kv[1] }
        'UNTIL'    { $until = Convert-IcsDate '' $kv[1] }
      }
    }
    $excl = $null
    if ($ev.Uid -and $exclMap.ContainsKey($ev.Uid)) { $excl = $exclMap[$ev.Uid] }
    if ($freq -and ($knownFreq -notcontains $freq)) { $freq = $null }  # неизвестная частота -> только первое
    $cur = $ev.Base
    $n = 0
    while ($n -lt 5000) {
      if ($cur.Date -gt $rangeEnd) { break }
      if ($until -and $cur -gt $until) { break }
      $n++
      $skip = ($excl -and ($excl -contains $cur.Date)) -or ($ev.ExDates -contains $cur.Date)
      if (-not $skip -and $cur.Date -ge $rangeStart -and $cur.Date -le $rangeEnd) { $occ.Add($cur) }
      if ($count -and $n -ge $count) { break }
      if (-not $freq) { break }
      switch ($freq) {
        'DAILY'   { $cur = $cur.AddDays($interval) }
        'WEEKLY'  { $cur = $cur.AddDays(7 * $interval) }
        'MONTHLY' { $cur = $cur.AddMonths($interval) }
        'YEARLY'  { $cur = $cur.AddYears($interval) }
      }
    }
  }

  foreach ($d in $occ) {
    if ($d.Date -lt $rangeStart -or $d.Date -gt $rangeEnd) { continue }
    $inRange++
    $s = "$($ev.Summary)"
    $isOld = $s -match '(?i)стары'      # старый/старая/старые
    $isNew = $s -match '(?i)новы'       # новый/новая/новые
    if (-not $isOld -and -not $isNew) { continue }
    $key = $d.Date.ToString('yyyy-MM-dd')
    if (-not $perDay.ContainsKey($key)) { $perDay[$key] = @{ new = 0; old = 0 } }
    if ($isOld) { $perDay[$key].old++; $markedOld++ } else { $perDay[$key].new++; $markedNew++ }
  }
}

# --- 7. Вывод (без названий событий — там имена клиентов) --------------------
Write-Host "ICS: событий в файле $found, в диапазоне $From..$To — $inRange (пропусков DTSTART: $badStart)"
Write-Host "С пометкой: новый — $markedNew, старый — $markedOld, всего помеченных — $($markedNew + $markedOld)"
Write-Host ('{0,-12} {1,6} {2,6}' -f 'дата', 'старые', 'новые')
foreach ($k in ($csvDates | Where-Object { $_ -ge $From -and $_ -le $To } | Sort-Object)) {
  $o = 0; $nw = 0
  if ($perDay.ContainsKey($k)) { $o = $perDay[$k].old; $nw = $perDay[$k].new }
  Write-Host ('{0,-12} {1,6} {2,6}' -f $k, $o, $nw)
}
if ($NoUpdate) { Write-Host 'CSV не изменялся (-NoUpdate)'; exit 0 }

# --- 8. Обновление CSV: колонки запись_старые/записи_новые перед «источник» -
$oldName = 'записи_старые'; $newName = 'записи_новые'
$outCols = @($csvCols)
$added = $false
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
  $added = $true
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
