# set_password.ps1 — ввод пароля сайта одним окном: сохраняет пароль и заливает данные.
# Запуск двойным кликом через «ВВЕСТИ-ПАРОЛЬ.bat». Пароль вводится скрыто.
$ErrorActionPreference = 'Stop'

Write-Host '=== Пароль для сайта (план + статистика Авито) ==='
Write-Host 'Введите ваш пароль. Ввод скрыт.'
$sec = Read-Host -AsSecureString 'Пароль'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
try { $pw = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if (-not $pw) { Write-Host 'Пароль пуст - ничего не сделано.' -ForegroundColor Red; exit 1 }

# Сохраняем пароль в .env (заменой строки PLAN_PASSWORD)
$envFile = 'C:\Users\user\Desktop\opencode\.env'
$lines = @()
if (Test-Path -LiteralPath $envFile) {
  $lines = Get-Content -LiteralPath $envFile | Where-Object { $_ -notmatch '^PLAN_PASSWORD=' }
}
$lines += "PLAN_PASSWORD=$pw"
[IO.File]::WriteAllLines($envFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host 'Пароль сохранён.' -ForegroundColor Green

# Заливка: шифрует план и статистику этим паролем и пушит в GitHub
& powershell -ExecutionPolicy Bypass -File 'C:\Users\user\Desktop\opencode\plan-dashboard\tools\sync_all.ps1'

Write-Host ''
Write-Host 'Готово! Сайт обновится через 1-2 минуты.' -ForegroundColor Green
