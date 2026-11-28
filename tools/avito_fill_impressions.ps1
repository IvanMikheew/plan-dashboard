# avito_fill_impressions.ps1 — дозаполнить/освежить ячейки «показы» в CSV статистики
# за указанный диапазон дат: по одному вызову stats/v2 grouping=item на день.
# По умолчанию заполняются только ПУСТЫЕ ячейки; флаг -Overwrite обновляет и
# непустые ( Avito T+1: пишется только строго большее значение, 0 = «не
# посчитано» и не записывается).
# (это единственный в API способ получить показы ПО ОБЪЯВЛЕНИЮ за день:
#  v2 grouping=day — только по профилю; v1 — impressions не отдаёт;
#  itemIds в v2 нет — фильтр игнорируется). Rate limit stats/v2 = 1 req/min,
#  поэтому между вызовами пауза, на 429 — повтор.
#
# Что делает: читает CSV, для каждой даты в диапазоне с ПУСТОЙ колонкой показы
#   берёт impressions объявления за этот день, заполняет ТОЛЬКО эту ячейку
#   (остальные колонки и ручные значения не трогает), сортирует строки по дате.
# File encoding: UTF-8 WITH BOM (PS 5.1 + Cyrillic paths).
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$DateFrom,
  [Parameter(Mandatory = $true)][string]$DateTo,
  [string]$ItemId   = '8547421312',
  [string]$EnvPath  = 'C:\Users\user\Desktop\opencode\.env',
  [string]$CsvPath  = 'C:\Users\user\Desktop\opencode\отчёты\статистика-авито.csv',
  [string]$RawDir   = 'C:\Users\user\Desktop\opencode\отчёты\avito-api-raw',
  [int]$PauseSec    = 63,          # пауза между вызовами stats/v2 (1 req/min)
  [switch]$Overwrite, # обновить и НЕпустые ячейки (правило «новое > записанного»)
  [switch]$DryRun   # только показать, что было бы заполнено (без записи)
)
$ErrorActionPreference = 'Stop'
$ApiBase = 'https://api.avito.ru'

function Read-EnvValue {
  param([string]$Path, [string]$Name)
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    if ($line -match ('^\s*' + [regex]::Escape($Name) + '\s*=\s*(.*)$')) {
      return $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
  return $null
}
function Invoke-Api {
  param([string]$Method, [string]$Url, [string]$Token, [string]$BodyJson)
  try {
    $a = @{ Uri = $Url; Method = $Method; Headers = @{ Authorization = 'Bearer ' + $Token }; UseBasicParsing = $true }
    if ($BodyJson) { $a.Body = $BodyJson; $a.ContentType = 'application/json' }
    $r = Invoke-WebRequest @a
    return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Body = $r.Content }
  } catch {
    $status = 0; $body = $_.Exception.Message
    if ($_.Exception.Response) {
      $status = [int]$_.Exception.Response.StatusCode
      try {
        $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $body = $sr.ReadToEnd()
      } catch { }
    }
    return [pscustomobject]@{ Ok = $false; Status = $status; Body = $body }
  }
}
function Save-Raw {
  param([string]$Name, [string]$Content)
  if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory -Path $RawDir -Force | Out-Null }
  $path = Join-Path $RawDir $Name
  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# --- auth ------------------------------------------------------------------
$clientId     = Read-EnvValue -Path $EnvPath -Name 'AVITO_CLIENT_ID'
$clientSecret = Read-EnvValue -Path $EnvPath -Name 'AVITO_CLIENT_SECRET'
if (-not $clientId -or -not $clientSecret) { Write-Host 'FATAL: creds not in .env'; exit 1 }
$pair = $clientId + ':' + $clientSecret
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
$tr = Invoke-WebRequest -Uri ($ApiBase + '/token') -Method Post `
  -Headers @{ Authorization = 'Basic ' + $b64 } `
  -ContentType 'application/x-www-form-urlencoded' `
  -Body 'grant_type=client_credentials' -UseBasicParsing
$token = ($tr.Content | ConvertFrom-Json).access_token
$self = Invoke-Api -Method Get -Url ($ApiBase + '/core/v1/accounts/self') -Token $token
$userId = ($self.Body | ConvertFrom-Json).id
if (-not $userId) { Write-Host 'FATAL: no user_id'; exit 1 }
Write-Host ('user_id: ' + $userId)

# --- CSV: читаем как есть (без BOM, CRLF), ищем пустые показы в диапазоне ---
if (-not (Test-Path -LiteralPath $CsvPath)) { Write-Host ('FATAL: CSV not found: ' + $CsvPath); exit 1 }
$rawBytes = [IO.File]::ReadAllBytes($CsvPath)
$hasBom = ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF)
$rawText = [Text.Encoding]::UTF8.GetString($rawBytes)
if ($hasBom) { $rawText = $rawText.Substring(1) }
$nl = if ($rawText.Contains("`r`n")) { "`r`n" } else { "`n" }
$hadFinalNl = $rawText.EndsWith("`n")
$lines = @($rawText -split "`r`n|`n")
if ($hadFinalNl -and $lines.Count -gt 0 -and $lines[-1] -eq '') { $lines = @($lines[0..($lines.Count - 2)]) }

$targets = @()
for ($i = 1; $i -lt $lines.Count; $i++) {
  $p = $lines[$i] -split ','
  if ($p.Count -lt 3) { continue }
  $d = $p[0].Trim()
  if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
  if ($d -lt $DateFrom -or $d -gt $DateTo) { continue }
  if ($p[2].Trim() -ne '' -and -not $Overwrite) { continue }  # без -Overwrite заполненные не трогаем
  $targets += [pscustomobject]@{ Index = $i; Date = $d; Item = $p[1].Trim() }
}
Write-Host ('empty impressions cells in range: ' + $targets.Count)
foreach ($t in $targets) { Write-Host ('  need: ' + $t.Date + ' item=' + $t.Item) }
if ($targets.Count -eq 0) { Write-Host 'NOTHING TO FILL'; exit 0 }
if ($DryRun) { Write-Host 'DRY RUN - no API calls, no writes'; exit 0 }

# --- собираем показы по дням (1 вызов stats/v2 на день) ---------------------
$url = $ApiBase + '/stats/v2/accounts/' + $userId + '/items'
$filled = @{}
$n = 0
foreach ($t in ($targets | Sort-Object Date)) {
  $n++
  $body = @{ dateFrom = $t.Date; dateTo = $t.Date; metrics = @('impressions')
             grouping = 'item'; limit = 1000; offset = 0 } | ConvertTo-Json
  $val = $null
  for ($try = 1; $try -le 3; $try++) {
    if ($n -gt 1 -or $try -gt 1) { Start-Sleep -Seconds $PauseSec }
    $res = Invoke-Api -Method Post -Url $url -Token $token -BodyJson $body
    Save-Raw -Name ('fill_v2_item_' + $t.Date + '_http' + $res.Status + '.json') -Content $res.Body | Out-Null
    if ($res.Status -eq 429) { Write-Host ('429 rate limit for ' + $t.Date + ', retry ' + $try + '/3'); continue }
    if (-not $res.Ok) { Write-Host ('HTTP ' + $res.Status + ' for ' + $t.Date + ' - skip'); break }
    try {
      $j = $res.Body | ConvertFrom-Json
      $g = @($j.result.groupings) | Where-Object { [string]$_.id -eq $t.Item } | Select-Object -First 1
      if ($g) {
        $m = @($g.metrics) | Where-Object { $_.slug -eq 'impressions' } | Select-Object -First 1
        if ($m) { $val = [int]$m.value }
      }
    } catch { Write-Host ('parse error for ' + $t.Date) }
    break
  }
  if ($null -ne $val) {
    $filled[$t.Date] = $val
    Write-Host ('got ' + $t.Date + ' impressions=' + $val + ' (item ' + $t.Item + ')')
  } else {
    Write-Host ('NO DATA for ' + $t.Date + ' - cell stays empty')
  }
}

if ($filled.Count -eq 0) { Write-Host 'NO VALUES RECEIVED - CSV untouched'; exit 6 }

# --- вписываем ячейки: только строго большее значение (0 = «не посчитано», T+1)
for ($i = 1; $i -lt $lines.Count; $i++) {
  $p = $lines[$i] -split ','
  if ($p.Count -lt 3) { continue }
  $d = $p[0].Trim()
  if ($filled.ContainsKey($d)) {
    $newV = [int]$filled[$d]
    $oldV = 0
    if ($p[2].Trim() -ne '') { $oldV = [int]$p[2] }
    if ($newV -gt $oldV) {
      $p[2] = [string]$newV
      $lines[$i] = ($p -join ',')
      Write-Host ('filled ' + $d + ' = ' + $p[2])
    } else {
      Write-Host ('keep ' + $d + ': stored=' + $p[2] + ' api=' + $newV + ' (no downgrade, no zero-fill)')
    }
  }
}

# --- сортировка строк по дате (заголовок остаётся первым) -------------------
$header = $lines[0]
$data = @($lines[1..($lines.Count - 1)] | Where-Object { $_ -ne '' })
$data = @($data | Sort-Object { if (($_ -split ',')[0] -match '^\d{4}-\d{2}-\d{2}$') { ($_ -split ',')[0] } else { '0000-00-00' } })
$lines = @($header) + $data

# --- запись назад: UTF-8, BOM как был, CRLF как был ------------------------
$out = ($lines -join $nl)
if ($hadFinalNl) { $out += $nl }
$enc = if ($hasBom) { New-Object System.Text.UTF8Encoding($true) } else { New-Object System.Text.UTF8Encoding($false) }
if (-not $DryRun) {
  [IO.File]::WriteAllText($CsvPath, $out, $enc)
}
Write-Host ('CSV updated: filled ' + $filled.Count + ' of ' + $targets.Count + ', rows sorted by date')
Write-Host 'DONE'
exit 0
