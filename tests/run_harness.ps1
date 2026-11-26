param(
  [string]$Url = 'http://127.0.0.1:8077/tests/harness.html',
  [string]$Chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe',
  [string]$Profile = 'C:\Users\user\AppData\Local\Temp\cdp-profile-v2',
  [int]$Budget = 20000
)
# Runs the acceptance harness in headless Chrome and prints its JSON report.
# ASCII-only on purpose: PS 5.1 reads BOM-less scripts as ANSI.
$ErrorActionPreference = 'Stop'
$out = Join-Path $env:TEMP 'harness-dump.html'
$errf = Join-Path $env:TEMP 'harness-dump.err'
Remove-Item $out, $errf -ErrorAction SilentlyContinue
$chromeArgs = @(
  '--headless=new', '--disable-gpu', '--no-first-run',
  ('--user-data-dir=' + $Profile),
  ('--virtual-time-budget=' + $Budget),
  '--dump-dom', $Url
)
$p = Start-Process -FilePath $Chrome -ArgumentList $chromeArgs `
  -RedirectStandardOutput $out -RedirectStandardError $errf -Wait -PassThru
if (!(Test-Path $out)) { Write-Output 'FAIL: chrome produced no dump'; exit 1 }
$html = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
$m = [regex]::Match($html, '<pre id="report">([\s\S]*?)</pre>')
if (!$m.Success) {
  Write-Output 'FAIL: report block not found (harness did not finish)'
  Write-Output $html.Substring(0, [Math]::Min(600, $html.Length))
  exit 1
}
$json = $m.Groups[1].Value -replace '&lt;', '<' -replace '&gt;', '>' -replace '&quot;', '"' -replace '&amp;', '&'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'last-report.json'), $json, (New-Object Text.UTF8Encoding($false)))
try { $r = $json | ConvertFrom-Json } catch { Write-Output 'FAIL: bad JSON'; exit 1 }
Write-Output ('PASS=' + @($r.pass).Count + ' FAIL=' + @($r.fail).Count)
Write-Output ('REPORT=' + (Join-Path $PSScriptRoot 'last-report.json'))
foreach ($k in $r.info.PSObject.Properties) {
  Write-Output ('  info.' + $k.Name + ' = ' + [string]$k.Value)
}
if (@($r.fail).Count -gt 0) { exit 1 } else { exit 0 }
