<# :
@echo off
setlocal
chcp 65001 >nul
title Network on/off for tests
net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator rights...
  set "SELF=%~f0"
  powershell -NoProfile -Command "Start-Process -FilePath $env:SELF -Verb RunAs"
  exit /b
)
set "SRC=%~f0"
set "PS1=%TEMP%\network_toggle_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SRC,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($env:PS1,$t,(New-Object Text.UTF8Encoding $true))"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
echo.
pause
exit /b
#>

# ============================================================
#  Отключение и включение интернета на время тестов.
#  Выключает физические сетевые адаптеры (кабель и Wi-Fi) и запоминает,
#  какие именно, чтобы потом включить их обратно. Ничего не удаляет и не меняет в настройках сети.
# ============================================================

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$dir = Join-Path $env:ProgramData 'MouseLatencyTools'
$state = Join-Path $dir 'disabled_adapters.txt'

function Show-State {
    Write-Host ""
    Write-Host "Сетевые адаптеры:" -ForegroundColor Cyan
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue | ForEach-Object {
        $c = if ($_.Status -eq 'Up') { 'Green' } elseif ($_.Status -eq 'Disabled') { 'Yellow' } else { 'Gray' }
        Write-Host ("  {0,-28} {1}" -f $_.Name, $_.Status) -ForegroundColor $c
    }
}

Write-Host "=== ИНТЕРНЕТ НА ВРЕМЯ ТЕСТОВ ===" -ForegroundColor Cyan
Show-State
Write-Host ""
Write-Host "1 — отключить интернет (выключить сетевые адаптеры)"
Write-Host "2 — включить интернет обратно"
Write-Host "3 — только показать состояние"
$a = Read-Host "Выбор"

if ($a -eq '1') {
    $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -ne 'Disabled' })
    if (-not $ads.Count) { Write-Host "Нет включённых адаптеров." -ForegroundColor Yellow; return }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($state, [string[]]($ads | ForEach-Object { $_.Name }))
    foreach ($ad in $ads) {
        try { Disable-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop; Write-Host "Выключен: $($ad.Name)" -ForegroundColor Yellow }
        catch { Write-Host "Не удалось выключить $($ad.Name): $($_.Exception.Message)" -ForegroundColor Red }
    }
    Write-Host ""
    Write-Host "Интернет отключён. После тестов запустите этот файл снова и выберите 2." -ForegroundColor Cyan
} elseif ($a -eq '2') {
    $names = if (Test-Path $state) { [IO.File]::ReadAllLines($state) } else { @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Disabled' } | ForEach-Object { $_.Name }) }
    foreach ($n in $names) {
        if (-not $n) { continue }
        try { Enable-NetAdapter -Name $n -Confirm:$false -ErrorAction Stop; Write-Host "Включён: $n" -ForegroundColor Green }
        catch { Write-Host "Не удалось включить $($n): $($_.Exception.Message)" -ForegroundColor Red }
    }
    if (Test-Path $state) { Remove-Item $state -Force }
    Write-Host "Подождите 5–10 секунд, пока подключение восстановится." -ForegroundColor Cyan
}
Show-State
