<# :
@echo off
setlocal
chcp 65001 >nul
title CS2 affinity
set "SRC=%~f0"
set "PS1=%TEMP%\cs2_affinity_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SRC,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($env:PS1,$t,(New-Object Text.UTF8Encoding $true))"
if not exist "%PS1%" (
  echo [ERROR] Could not create temp script in %TEMP%
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
echo.
pause
exit /b
#>

# ============================================================
#  Убирает CS2 с выбранных потоков CPU.
#  При запуске спрашивает, какие потоки освободить (запоминает выбор),
#  ждёт запуска cs2.exe, ставит привязку и следит за перезапусками игры.
#  Это обычная функция Windows («Задать сходство» в Диспетчере задач).
# ============================================================

$Process = 'cs2'
$RegPath = 'HKCU:\Software\MouseLatencyTools'

[Console]::OutputEncoding = [Text.Encoding]::UTF8

$n = [Environment]::ProcessorCount
$cores = $null
try { $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum } catch {}
$ht = $cores -and ($n -eq $cores * 2)

Write-Host "=== CS2: освободить потоки CPU ===" -ForegroundColor Cyan
Write-Host ("Потоков: {0} (CPU 0 ... CPU {1}){2}" -f $n, ($n - 1), $(if ($cores) { ", ядер: $cores" } else { "" }))
if ($ht) {
    $pairs = for ($c = 0; $c -lt $cores; $c++) { "Ядро {0}: {1},{2}" -f $c, ($c * 2), ($c * 2 + 1) }
    Write-Host ("Потоки по ядрам:  " + ($pairs -join '   ')) -ForegroundColor DarkGray
}

# прошлый выбор
$default = '10'
try { $saved = (Get-ItemProperty -Path $RegPath -Name Cs2Exclude -ErrorAction Stop).Cs2Exclude; if ($saved) { $default = $saved } } catch {}
if ([int]($default -split '[,\s]+' | Select-Object -First 1) -ge $n) { $default = [string]($n - 1) }

Write-Host ""
Write-Host "Какие потоки НЕ давать CS2? Через запятую, например: 10   или   10,11 (всё ядро)."
$ans = Read-Host "Потоки (Enter = $default)"
if ([string]::IsNullOrWhiteSpace($ans)) { $ans = $default }

$Exclude = @()
foreach ($part in ($ans -split '[,\s;]+' | Where-Object { $_ })) {
    if ($part -match '^\d+$' -and [int]$part -lt $n) { $Exclude += [int]$part }
    else { Write-Host "Пропускаю «$part»: такого потока нет." -ForegroundColor Yellow }
}
$Exclude = @($Exclude | Sort-Object -Unique)
if ($Exclude.Count -eq 0) { Write-Host "Не выбрано ни одного потока — выход." -ForegroundColor Red; return }
if ($Exclude.Count -ge $n) { Write-Host "Нельзя забрать у игры все потоки — выход." -ForegroundColor Red; return }
if ($Exclude.Count -gt [Math]::Max(2, [int]($n / 4))) {
    Write-Host ("Внимание: игре останется {0} из {1} потоков, FPS может упасть." -f ($n - $Exclude.Count), $n) -ForegroundColor Yellow
}
try {
    if (-not (Test-Path $RegPath)) { New-Item -Path $RegPath -Force | Out-Null }
    Set-ItemProperty -Path $RegPath -Name Cs2Exclude -Value ($Exclude -join ',')
} catch {}

$mask = ([int64]1 -shl $n) - 1
foreach ($c in $Exclude) { $mask = $mask -band (-bnot ([int64]1 -shl $c)) }
$allowed = @(0..($n - 1) | Where-Object { $mask -band ([int64]1 -shl $_) })

Write-Host ""
Write-Host ("Исключены:  CPU {0}" -f ($Exclude -join ', CPU ')) -ForegroundColor Green
Write-Host ("Разрешены:  CPU {0}" -f ($allowed -join ', '))
Write-Host ("Маска:      0x{0:X}   (ручная команда: (Get-Process cs2).ProcessorAffinity = 0x{0:X})" -f $mask) -ForegroundColor DarkGray
Write-Host "Не закрывайте это окно, пока играете. Выход — крестик или Ctrl+C."
Write-Host ""

while ($true) {
    $p = Get-Process -Name $Process -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) {
        Write-Host "`rЖду запуска $Process.exe...   " -NoNewline
        Start-Sleep -Seconds 2
        continue
    }

    Write-Host ""
    try {
        $p.ProcessorAffinity = [IntPtr]$mask
        $p.Refresh()
        $now = [int64]$p.ProcessorAffinity
        if ($now -eq $mask) {
            Write-Host ("[{0:HH:mm:ss}] {1}.exe (PID {2}): привязка установлена, CPU {3} свободны от игры." -f (Get-Date), $Process, $p.Id, ($Exclude -join ', ')) -ForegroundColor Green
        } else {
            Write-Host ("Привязка не применилась (сейчас 0x{0:X}). Запустите от имени администратора." -f $now) -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Не удалось задать привязку: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Запустите батник от имени администратора (ПКМ → Запуск от имени администратора)." -ForegroundColor Yellow
    }

    while (-not $p.HasExited) {
        Start-Sleep -Seconds 5
        try {
            $p.Refresh()
            if (-not $p.HasExited -and [int64]$p.ProcessorAffinity -ne $mask) {
                $p.ProcessorAffinity = [IntPtr]$mask
                Write-Host ("[{0:HH:mm:ss}] Привязка была сброшена — установил снова." -f (Get-Date)) -ForegroundColor Yellow
            }
        } catch {}
    }
    Write-Host ("[{0:HH:mm:ss}] {1}.exe закрыта. Жду следующего запуска." -f (Get-Date), $Process)
}
