# avito_stats.ps1 - Avito Business API (api.avito.ru) daily statistics -> CSV
# File encoding: UTF-8 WITH BOM (PS 5.1 + Cyrillic paths).
#
# What it does (per run):
#   1) reads AVITO_CLIENT_ID / AVITO_CLIENT_SECRET from -EnvPath (never printed),
#   2) POST /token (client_credentials),
#   3) GET  /core/v1/accounts/self                        -> user_id,
#   4) POST /stats/v2/accounts/{user_id}/items (grouping=day)   -> per-day shows/views/contacts,
#   5) POST /stats/v2/accounts/{user_id}/items (grouping=item)  -> per-item totals (cross-check),
#   6) POST /stats/v1/accounts/{user_id}/items (periodGrouping=day) -> per-item per-day uniq counters,
#   7) POST /core/v1/accounts/{user_id}/calls/stats/           -> per-item calls,
#   8) saves raw JSON responses to -RawDir and appends CSV rows (no duplicates).
#
# CSV columns: дата,объявление_id,показы,просмотры,контакты,записи,источник
#   показы   = v2 metric "impressions"
#   просмотры= v2 metric "views"
#   контакты = v2 metric "contacts"
#   записи   = always empty (offline data)
#   источник = avito-api
# NOTE: v2 metrics are per-PROFILE (all items of the account). If the account has
# more than one active item in the period, the script falls back to per-item v1
# counters (просмотры=uniqViews, контакты=uniqContacts) and leaves показы empty.
#
# Contract source: official Avito API for business OpenAPI spec (Avito API v1/v2,
# statistics section). Rate limit: stats/v2 - max 1 request per minute (script
# sleeps 62s between v2 calls). Data depth: 270 days.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File avito_stats.ps1 -DateFrom 2026-11-15 -DateTo 2026-11-24
#   powershell -ExecutionPolicy Bypass -File avito_stats.ps1 -DateFrom 2026-11-25 -DateTo 2026-11-30 -ItemId 8547421312

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$DateFrom,          # yyyy-MM-dd
  [Parameter(Mandatory = $true)][string]$DateTo,            # yyyy-MM-dd
  [string]$ItemId   = '8547421312',
  [string]$EnvPath  = 'C:\Users\user\Desktop\opencode\.env',
  [string]$CsvPath  = 'C:\Users\user\Desktop\opencode\отчёты\статистика-авито.csv',
  [string]$RawDir   = 'C:\Users\user\Desktop\opencode\отчёты\avito-api-raw',
  [switch]$NoCsv    # fetch + save raw only, do not touch the CSV
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

function Get-AvitoToken {
  param([string]$ClientId, [string]$ClientSecret)
  $pair = $ClientId + ':' + $ClientSecret
  $b64  = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
  for ($try = 1; $try -le 3; $try++) {
    try {
      $r = Invoke-WebRequest -Uri ($ApiBase + '/token') -Method Post `
            -Headers @{ Authorization = 'Basic ' + $b64 } `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body 'grant_type=client_credentials' -UseBasicParsing
      $j = $r.Content | ConvertFrom-Json
      if (-not $j.access_token) { throw 'token response has no access_token' }
      return [pscustomobject]@{ Ok = $true; Status = [int]$r.StatusCode; Token = $j.access_token }
    } catch {
      $status = 0; $body = $_.Exception.Message
      if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
        try {
          $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
          $body = $sr.ReadToEnd()
        } catch { }
      }
      if (($status -eq 0 -or $status -ge 500 -or $status -eq 429) -and $try -lt 3) {
        Write-Host ('token: transient error HTTP ' + $status + ', retry ' + $try + '/3 in 20s')
        Start-Sleep -Seconds 20
        continue
      }
      return [pscustomobject]@{ Ok = $false; Status = $status; Token = $null; Body = $body }
    }
  }
}

function Invoke-Api {
  param([string]$Method, [string]$Url, [string]$Token, [string]$BodyJson)
  try {
    $args2 = @{ Uri = $Url; Method = $Method; Headers = @{ Authorization = 'Bearer ' + $Token }; UseBasicParsing = $true }
    if ($BodyJson) { $args2.Body = $BodyJson; $args2.ContentType = 'application/json' }
    $r = Invoke-WebRequest @args2
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
  $safe = ($Name -replace '[^A-Za-z0-9._-]', '_')
  $path = Join-Path $RawDir $safe
  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

# ---------- main ----------
if (-not (Test-Path $EnvPath)) { Write-Host ('FATAL: .env not found: ' + $EnvPath); exit 1 }
$clientId     = Read-EnvValue -Path $EnvPath -Name 'AVITO_CLIENT_ID'
$clientSecret = Read-EnvValue -Path $EnvPath -Name 'AVITO_CLIENT_SECRET'
if (-not $clientId -or -not $clientSecret) {
  Write-Host 'FATAL: AVITO_CLIENT_ID / AVITO_CLIENT_SECRET not found in .env'
  exit 1
}
Write-Host 'creds: loaded from .env (values not shown)'

$auth = Get-AvitoToken -ClientId $clientId -ClientSecret $clientSecret
if (-not $auth.Ok) {
  Write-Host ('AUTH FAILED: HTTP ' + $auth.Status)
  Write-Host ('body: ' + $auth.Body)
  exit 2
}
Write-Host ('AUTH OK: HTTP ' + $auth.Status + ', token acquired (value not shown)')
$token = $auth.Token

# --- user_id ---
$self = Invoke-Api -Method Get -Url ($ApiBase + '/core/v1/accounts/self') -Token $token
if (-not $self.Ok) {
  Write-Host ('SELF FAILED: HTTP ' + $self.Status)
  Write-Host ('body: ' + $self.Body)
  exit 3
}
$selfObj = $self.Body | ConvertFrom-Json
$userId = $selfObj.id
if (-not $userId) { Write-Host ('SELF: no id field in response: ' + $self.Body); exit 3 }
Write-Host ('user_id: ' + $userId + ' (account id, not a secret)')
# privacy: save only the id, not the full self profile (email/phone/name)
Save-Raw -Name ('self_user_id.json') -Content ('{"id": ' + $userId + '}') | Out-Null

$metrics = @('impressions','views','contacts','contactsShowPhone','contactsMessenger','favorites','viewsToContactsConversion','impressionsToViewsConversion')

function Post-StatsV2 {
  param([string]$Grouping, [string]$Tag)
  $body = @{
    dateFrom = $DateFrom
    dateTo   = $DateTo
    metrics  = $metrics
    grouping = $Grouping
    limit    = 1000
    offset   = 0
  } | ConvertTo-Json
  $url = $ApiBase + '/stats/v2/accounts/' + $userId + '/items'
  for ($try = 1; $try -le 3; $try++) {
    $res = Invoke-Api -Method Post -Url $url -Token $token -BodyJson $body
    if ($res.Status -eq 429) {
      Write-Host ('stats/v2 grouping=' + $Grouping + ' -> HTTP 429 (rate limit), wait 65s, try ' + $try + '/3')
      Start-Sleep -Seconds 65
      continue
    }
    $saved = Save-Raw -Name ('stats_v2_' + $Tag + '_' + $DateFrom + '_' + $DateTo + '_http' + $res.Status + '.json') -Content $res.Body
    Write-Host ('stats/v2 grouping=' + $Grouping + ' -> HTTP ' + $res.Status + ' saved: ' + $saved)
    return $res
  }
  Save-Raw -Name ('stats_v2_' + $Tag + '_' + $DateFrom + '_' + $DateTo + '_http' + $res.Status + '.json') -Content $res.Body | Out-Null
  return $res
}

# --- v2 per-day (rate limit: 1 req/min for this method) ---
$v2day = Post-StatsV2 -Grouping 'day' -Tag 'day'
Write-Host 'waiting 62s (stats/v2 rate limit: 1 request per minute)...'
Start-Sleep -Seconds 62
$v2item = Post-StatsV2 -Grouping 'item' -Tag 'item'

# --- v1 per-item per-day ---
$v1body = @{
  itemIds        = @([int64]$ItemId)
  dateFrom       = $DateFrom
  dateTo         = $DateTo
  fields         = @('uniqViews','uniqContacts','uniqFavorites')
  periodGrouping = 'day'
} | ConvertTo-Json
$v1 = Invoke-Api -Method Post -Url ($ApiBase + '/stats/v1/accounts/' + $userId + '/items') -Token $token -BodyJson $v1body
$saved = Save-Raw -Name ('stats_v1_item_' + $DateFrom + '_' + $DateTo + '_http' + $v1.Status + '.json') -Content $v1.Body
Write-Host ('stats/v1 -> HTTP ' + $v1.Status + ' saved: ' + $saved)

# --- calls ---
$callsBody = @{ dateFrom = $DateFrom; dateTo = $DateTo; itemIds = @([int64]$ItemId) } | ConvertTo-Json
$calls = Invoke-Api -Method Post -Url ($ApiBase + '/core/v1/accounts/' + $userId + '/calls/stats/') -Token $token -BodyJson $callsBody
$saved = Save-Raw -Name ('calls_stats_' + $DateFrom + '_' + $DateTo + '_http' + $calls.Status + '.json') -Content $calls.Body
Write-Host ('calls/stats -> HTTP ' + $calls.Status + ' saved: ' + $saved)

if (-not $v2day.Ok) { Write-Host 'FATAL: stats/v2 day failed (see raw file)'; exit 4 }

# ---------- parse v2 (per-day) ----------
# Response: { result: { dataTotalCount, groupings: [ { id: <unix seconds>, type: "dates",
#            metrics: [ {slug, value}, ... ] }, ... ], timestamp } }
function Get-MetricsMap {
  param($groupingEntry)
  $m = @{}
  foreach ($x in $groupingEntry.metrics) { $m[[string]$x.slug] = $x.value }
  return $m
}

$v2dayObj = $v2day.Body | ConvertFrom-Json
$dayRows = @()   # pscustomobject: date, impressions, views, contacts, contactsShowPhone, contactsMessenger
foreach ($g in @($v2dayObj.result.groupings)) {
  $ts = [int64]$g.id
  $dUtc = [DateTimeOffset]::FromUnixTimeSeconds($ts).UtcDateTime.ToString('yyyy-MM-dd')
  $dMsk = [DateTimeOffset]::FromUnixTimeSeconds($ts).ToOffset([TimeSpan]::FromHours(3)).ToString('yyyy-MM-dd')
  $mm = Get-MetricsMap -groupingEntry $g
  # choose the date label that falls inside the requested range (fallback: UTC)
  $d = $dUtc
  if (($dUtc -lt $DateFrom -or $dUtc -gt $DateTo) -and $dMsk -ge $DateFrom -and $dMsk -le $DateTo) { $d = $dMsk }
  $dayRows += [pscustomobject]@{
    date = $d
    impressions = if ($mm.ContainsKey('impressions')) { $mm['impressions'] } else { '' }
    views       = if ($mm.ContainsKey('views'))       { $mm['views'] }       else { '' }
    contacts    = if ($mm.ContainsKey('contacts'))    { $mm['contacts'] }    else { '' }
    contactsShowPhone    = if ($mm.ContainsKey('contactsShowPhone'))    { $mm['contactsShowPhone'] }    else { '' }
    contactsMessenger    = if ($mm.ContainsKey('contactsMessenger'))    { $mm['contactsMessenger'] }    else { '' }
  }
}

# ---------- parse v2 (per-item) ----------
$itemCount = 0; $itemTotals = ''
if ($v2item.Ok) {
  $v2itemObj = $v2item.Body | ConvertFrom-Json
  $groups = @($v2itemObj.result.groupings)
  $itemCount = $groups.Count
  Write-Host ('v2 item grouping entries: ' + $itemCount)
  foreach ($g in $groups) {
    $mm = Get-MetricsMap -groupingEntry $g
    Write-Host ('  item id=' + $g.id + ' impressions=' + $mm['impressions'] + ' views=' + $mm['views'] + ' contacts=' + $mm['contacts'])
    if ([string]$g.id -eq $ItemId) { $itemTotals = $mm }
  }
}

# ---------- parse v1 (per-item per-day) ----------
# Response: { errors, result: { items: [ { itemId, stats: [ { date, uniqViews, ... }, ... ] } ] } }
$v1Rows = @{}
if ($v1.Ok) {
  $v1Obj = $v1.Body | ConvertFrom-Json
  foreach ($it in @($v1Obj.result.items)) {
    if ([string]$it.itemId -ne $ItemId) { continue }
    foreach ($st in @($it.stats)) {
      $d = [string]$st.date
      if ($d -match '^\d{4}-\d{2}-\d{2}') {
        $v1Rows[$d.Substring(0,10)] = [pscustomobject]@{
          uniqViews    = if ($st.PSObject.Properties['uniqViews'])    { $st.uniqViews }    else { '' }
          uniqContacts = if ($st.PSObject.Properties['uniqContacts']) { $st.uniqContacts } else { '' }
          uniqFavorites= if ($st.PSObject.Properties['uniqFavorites']){ $st.uniqFavorites }else { '' }
        }
      }
    }
  }
  Write-Host ('v1 per-day rows parsed: ' + $v1Rows.Count)
}

# ---------- build CSV rows ----------
$singleItem = ($itemCount -le 1)
$csvRows = @()
foreach ($r in ($dayRows | Sort-Object date)) {
  if ($r.date -lt $DateFrom -or $r.date -gt $DateTo) { continue }
  if ($singleItem) {
    $csvRows += ($r.date + ',' + $ItemId + ',' + $r.impressions + ',' + $r.views + ',' + $r.contacts + ',,avito-api')
  } else {
    $v1r = $v1Rows[$r.date]
    $views = ''; $contacts = ''
    if ($v1r) { $views = $v1r.uniqViews; $contacts = $v1r.uniqContacts }
    $csvRows += ($r.date + ',' + $ItemId + ',,' + $views + ',' + $contacts + ',,avito-api')
    Write-Host ('WARN multi-item account: показы unavailable per item for ' + $r.date + ' (v2 is profile-level)')
  }
}
Write-Host ('CSV rows prepared: ' + $csvRows.Count)

# ---------- verify ----------
$sumImp = 0; $sumViews = 0; $sumContacts = 0
foreach ($r in $dayRows) {
  if ($r.date -ge $DateFrom -and $r.date -le $DateTo) {
    $sumImp += [int](0 + $r.impressions); $sumViews += [int](0 + $r.views); $sumContacts += [int](0 + $r.contacts)
    Write-Host ('  ' + $r.date + ' | показы=' + $r.impressions + ' | просмотры=' + $r.views + ' | контакты=' + $r.contacts + ' | тел=' + $r.contactsShowPhone + ' | чат=' + $r.contactsMessenger)
  }
}
Write-Host ('SUMS (v2, profile): impressions=' + $sumImp + ' views=' + $sumViews + ' contacts=' + $sumContacts)

if ($NoCsv) { Write-Host 'DONE (NoCsv)'; exit 0 }
if ($csvRows.Count -eq 0) { Write-Host 'WARN: 0 rows - nothing to append'; exit 5 }

# ---------- append to CSV (dedupe by date|itemId) ----------
$existing = @{}
if (Test-Path $CsvPath) {
  foreach ($line in [System.IO.File]::ReadAllLines($CsvPath)) {
    $p = $line.Split(',')
    if ($p.Count -ge 2 -and $p[0] -match '^\d{4}-\d{2}-\d{2}$') { $existing[$p[0] + '|' + $p[1]] = $true }
  }
}
$toAdd = @()
foreach ($line in $csvRows) {
  $p = $line.Split(',')
  if (-not $existing.ContainsKey($p[0] + '|' + $p[1])) { $toAdd += $line }
}
if ($toAdd.Count -gt 0) {
  [System.IO.File]::AppendAllLines($CsvPath, [string[]]$toAdd, (New-Object System.Text.UTF8Encoding($false)))
}
Write-Host ('CSV updated: added ' + $toAdd.Count + ' of ' + $csvRows.Count + ' rows -> ' + $CsvPath)
Write-Host 'DONE'
exit 0
