param(
  [string]$Url = 'http://127.0.0.1:8077/tests/harness.html',
  [string]$Chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe',
  [string]$Profile = 'C:\Users\user\AppData\Local\Temp\cdp-profile-v2',
  [int]$TimeoutSec = 240
)
# Runs the acceptance harness in headless Chrome (REAL time: virtual-time
# budgets break WebCrypto) and waits for the report POSTed to report_server.
# ASCII-only on purpose: PS 5.1 reads BOM-less scripts as ANSI.
$ErrorActionPreference = 'Stop'
$reportPath = Join-Path $PSScriptRoot 'last-report.json'
$serverPy = Join-Path $PSScriptRoot 'report_server.py'
$encScript = Join-Path $PSScriptRoot 'make_test_enc.js'

# 1) synthetic .enc for the crypto regression test (test-only password)
if (Test-Path $reportPath) { Remove-Item $reportPath }
$enc = Join-Path $PSScriptRoot 'test.enc'
if (Test-Path $enc) { Remove-Item $enc }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: node not found (needed for make_test_enc.js)'; exit 1
}
& node $encScript
if ($LASTEXITCODE -ne 0) { Write-Output 'FAIL: make_test_enc.js failed'; exit 1 }

# 2) local report endpoint (the page beacons its JSON here)
$server = Start-Process -FilePath 'python' -ArgumentList @($serverPy, '8078') `
  -PassThru -WindowStyle Hidden
$pingOk = $false
for ($i = 0; $i -lt 20 -and -not $pingOk; $i++) {
  Start-Sleep -Milliseconds 250
  try {
    $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8078/ping' -UseBasicParsing -TimeoutSec 2
    if ($r.StatusCode -eq 200) { $pingOk = $true }
  } catch { }
}
if (-not $pingOk) {
  Write-Output 'FAIL: report server did not start'
  Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  exit 1
}

# 3) headless chrome: no --dump-dom, no virtual time (page runs until killed)
$chromeProc = Start-Process -FilePath $Chrome -ArgumentList @(
  '--headless=new', '--disable-gpu', '--no-first-run',
  ('--user-data-dir=' + $Profile), $Url
) -PassThru -WindowStyle Hidden

# 4) wait for the completed report (R.done = true)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$json = $null
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  if (Test-Path $reportPath) {
    try {
      $raw = [IO.File]::ReadAllText($reportPath, [Text.Encoding]::UTF8)
      $obj = $raw | ConvertFrom-Json
      if ($obj.done -eq $true) { $json = $obj; break }
    } catch { }
  }
}

# 5) cleanup chrome + server
taskkill /T /F /PID $chromeProc.Id 2>$null | Out-Null
Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
if (-not $json) {
  Write-Output 'FAIL: no complete report within timeout (see tests/last-report.json)'
  if (Test-Path $reportPath) { Write-Output ('partial: ' + (Get-Item $reportPath).Length + ' bytes') }
  exit 1
}

Write-Output ('PASS=' + @($json.pass).Count + ' FAIL=' + @($json.fail).Count)
Write-Output ('REPORT=' + $reportPath)
foreach ($k in $json.info.PSObject.Properties) {
  Write-Output ('  info.' + $k.Name + ' = ' + [string]$k.Value)
}
if (@($json.fail).Count -gt 0) { exit 1 } else { exit 0 }
