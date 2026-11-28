# avito_probe.ps1 — эксперимент: есть ли ПОКАЗЫ ПО ОБЪЯВЛЕНИЮ ЗА ДЕНЬ в Avito API.
# Кандидаты: (1) stats/v1 fields += impressions/uniqImpressions,
#            (2) stats/v2 grouping=day + itemIds (фильтр по объявлению).
# Ответы сохраняются в raw-файлы (probe_*), значения секретов не печатаются.
# File encoding: UTF-8 WITH BOM (PS 5.1 + Cyrillic paths).
[CmdletBinding()]
param(
  [string]$EnvPath  = 'C:\Users\user\Desktop\opencode\.env',
  [string]$RawDir   = 'C:\Users\user\Desktop\opencode\отчёты\avito-api-raw',
  [string]$ItemId   = '8547421312',
  [string]$DateFrom = '2026-11-09',
  [string]$DateTo   = '2026-11-14'
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
function Save-Raw {
  param([string]$Name, [string]$Content)
  if (-not (Test-Path $RawDir)) { New-Item -ItemType Directory -Path $RawDir -Force | Out-Null }
  $path = Join-Path $RawDir $Name
  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
  return $path
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
Write-Host ('user_id: ' + $userId)

# --- probe 1: stats/v1 c полями impressions -------------------------------
$b1 = @{ itemIds = @([int64]$ItemId); dateFrom = $DateFrom; dateTo = $DateTo
         fields = @('uniqViews', 'impressions'); periodGrouping = 'day' } | ConvertTo-Json
$r1 = Invoke-Api -Method Post -Url ($ApiBase + '/stats/v1/accounts/' + $userId + '/items') -Token $token -BodyJson $b1
$p1 = Save-Raw -Name 'probe_v1_fields_impressions.json' -Content $r1.Body
Write-Host ('v1 fields=[uniqViews,impressions] -> HTTP ' + $r1.Status + ' -> ' + $p1)

# --- probe 2: stats/v1 c полем uniqImpressions ----------------------------
$b2 = @{ itemIds = @([int64]$ItemId); dateFrom = $DateFrom; dateTo = $DateTo
         fields = @('uniqViews', 'uniqImpressions'); periodGrouping = 'day' } | ConvertTo-Json
$r2 = Invoke-Api -Method Post -Url ($ApiBase + '/stats/v1/accounts/' + $userId + '/items') -Token $token -BodyJson $b2
$p2 = Save-Raw -Name 'probe_v1_fields_uniqimpressions.json' -Content $r2.Body
Write-Host ('v1 fields=[uniqViews,uniqImpressions] -> HTTP ' + $r2.Status + ' -> ' + $p2)

# --- probe 3: stats/v2 grouping=day + itemIds (rate limit: 1 req/min!) ----
$b3 = @{ dateFrom = $DateFrom; dateTo = $DateTo; metrics = @('impressions', 'views')
         grouping = 'day'; limit = 1000; offset = 0; itemIds = @([int64]$ItemId) } | ConvertTo-Json
$r3 = Invoke-Api -Method Post -Url ($ApiBase + '/stats/v2/accounts/' + $userId + '/items') -Token $token -BodyJson $b3
$p3 = Save-Raw -Name 'probe_v2_day_itemids.json' -Content $r3.Body
Write-Host ('v2 grouping=day + itemIds -> HTTP ' + $r3.Status + ' -> ' + $p3)

Write-Host 'DONE'
exit 0
