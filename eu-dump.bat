@echo off
rem Stažení artefaktů z hlavní jednotky (HJ) dárcovského vozu s EU firmwarem (VOYAH Courage H37Z) přes ADB — Windows.
rem Dvě fáze bez překryvu:
rem   fáze 1 (rychlá, výchozí): přehledy + carplay, etc, new (balíčky, které v CN nejsou), voice (hlas), ota-candidates,
rem          diff a heavy (aplikace, které se v EU liší v kódu);
rem   fáze 2 (--full): vše ostatní — celé oddíly obrazu (part-*.tar), rozbalené APEX, /data/app; 1. fáze se neopakuje.
rem Návod — README.md vedle. Logika na HJ — eu-dump-device.sh.
rem Pouze čtení: na HJ vzniká a na konci se maže jen /data/local/tmp/eudump.
rem Použití: eu-dump.bat [--full ^| --all] [výstupní_složka]
rem   (bez přepínače)  fáze 1 do nové složky eu-<datum>\
rem   --full           fáze 2 do poslední složky eu-*\ (nebo do zadané)
rem   --all            obě fáze za sebou
rem Opakované spuštění se stejnou složkou navazuje: celé stažené archivy se znovu nestahují.
rem ⛔ Výstup obsahuje sériová čísla, VIN a identifikátory CIZÍHO vozu. Složky eu-*\ jsou mimo git (.gitignore).
chcp 65001 >nul
setlocal enabledelayedexpansion
set "DIR=%~dp0"
rem adb: proměnná ADB, platform-tools\ vedle skriptu, PATH
if not defined ADB (
  if exist "%DIR%platform-tools\adb.exe" (set "ADB=%DIR%platform-tools\adb.exe") else (set "ADB=adb")
)
set "DEV=/data/local/tmp/eu-dump-device.sh"
rem seznam balíčků čínského sestavení — pro new.tar
set "CN=/data/local/tmp/eu-cn-packages.txt"

set "MODE=1"
if /i "%~1"=="--full" set "MODE=2"
if /i "%~1"=="--all" set "MODE=all"
if not "%MODE%"=="1" shift
set "OUT=%~1"
if "%OUT%"=="" if "%MODE%"=="2" (
  for /f "delims=" %%d in ('dir /b /ad /o:n "%DIR%eu-*" 2^>nul') do set "OUT=%DIR%%%d"
  if "!OUT!"=="" (
    echo [x] Chybí složka eu-* z 1. fáze. Zadej složku: %~nx0 --full ^<složka^>
    exit /b 1
  )
)
if "%OUT%"=="" (
  for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do set "TS=%%i"
  if "!TS!"=="" set "TS=dump"
  set "OUT=%DIR%eu-!TS!"
)

"%ADB%" version >nul 2>nul
if errorlevel 1 (
  echo [x] adb nenalezen. Nastav proměnnou ADB, dej platform-tools\ vedle skriptu nebo adb do PATH.
  exit /b 1
)
set "HAVE_TAR=1"
where tar >nul 2>nul
if errorlevel 1 (
  set "HAVE_TAR=0"
  echo [!] tar.exe nenalezen ^(potřeba Windows 10 1803+^) — kontrola archivů se přeskočí.
)

echo Čekám na HJ ^(potvrď ladění na displeji vozu^)...
"%ADB%" wait-for-device
for /f "usebackq tokens=*" %%s in (`"%ADB%" get-state 2^>nul`) do set "STATE=%%s"
if not "%STATE%"=="device" (
  echo [x] HJ není připravena ^(stav: %STATE%^). Zkontroluj kabel/port a ladění USB.
  exit /b 1
)

if not exist "!OUT!" mkdir "!OUT!"
if not exist "!OUT!" (
  echo [x] Složku !OUT! se nepodařilo vytvořit
  exit /b 1
)
for %%d in ("!OUT!") do set "OUT=%%~fd"
set "LOG=!OUT!\eu-dump.log"
set "DONE=!OUT!\.done"
echo [ok] HJ připojena. Výstup: !OUT!
rem >> — při navázání do stejné složky se log doplňuje
>>"!LOG!" echo EU výpis, fáze: %MODE%, adb: %ADB%

"%ADB%" push "%DIR%eu-dump-device.sh" %DEV% >nul
if errorlevel 1 (
  echo [x] skript se nepodařilo nahrát na HJ
  exit /b 1
)
"%ADB%" push "%DIR%cn-packages.txt" %CN% >nul
if errorlevel 1 (
  echo [x] seznam čínských balíčků se nepodařilo nahrát na HJ
  exit /b 1
)
rem CRLF po git checkout na Windows rozbije sh na HJ
"%ADB%" shell "sed -i 's/\r$//' %DEV% %CN%"

set "FAILS=0"
set "LOST=0"
if not "%MODE%"=="2" call :stage1
if not "%MODE%"=="1" if "!LOST!"=="0" call :stage2

"%ADB%" shell "rm -rf /data/local/tmp/eudump %DEV% %CN%" >nul 2>nul
if "!LOST!"=="1" (
  echo.
  echo [x] Spojení s HJ ztraceno. Připoj HJ a spusť znovu se stejnou složkou —
  echo     stažené archivy se znovu nestahují. Pokud se HJ už nepřipojí, uklid ručně:
  echo     adb shell rm -rf /data/local/tmp/eudump %DEV% %CN%
  if "%MODE%"=="1" (echo     %~nx0 "!OUT!") else (echo     %~nx0 --%MODE:2=full% "!OUT!")
  exit /b 2
)

powershell -NoProfile -Command "Get-ChildItem -LiteralPath '!OUT!' -Filter *.tar | Get-FileHash -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLower() + '  ./' + (Split-Path $_.Path -Leaf) } | Set-Content -Encoding ascii -LiteralPath '!OUT!\SHA256SUMS'"

if not "%MODE%"=="2" (
  echo.
  echo Kandidáti na soubor firmwaru:
  findstr /b /c:"FW: " "!OUT!\ota-search.txt"
  if errorlevel 1 echo   — nenalezeno
  echo.
  echo Balíčky CarPlay/projekce:
  findstr /b /c:"package:" "!OUT!\carplay.txt"
  if errorlevel 1 echo   — nenalezeno
)
echo.
if not "!FAILS!"=="0" (
  echo [!] kroků s prázdným/poškozeným tar: !FAILS! ^(podrobnosti — !LOG!, device-errors-*.txt^)
  exit /b 1
)
echo [ok] Hotovo: !OUT!
if "%MODE%"=="1" echo Dál, pokud je čas, — fáze 2 ^(celé oddíly^): %~nx0 --full "!OUT!"
exit /b 0

:stage1
echo -- Fáze 1: CarPlay, konfigurace, EU-only balíčky, hlas, firmware, aplikace lišící se od CN --
rem Nejdřív text — rychlé a nejcennější, kdyby se spojení přerušilo; archivy v pořadí hodnoty
call :text report  report.txt
call :text carplay carplay.txt
call :text voice   voice.txt
call :text ota     ota-search.txt
for %%s in ("tar-carplay carplay.tar opt" "tar-etc etc.tar" "tar-new new.tar opt" "tar-voice voice.tar opt" "tar-ota ota-candidates.tar opt" "tar-diff diff.tar opt" "tar-heavy heavy.tar opt") do (
  if "!LOST!"=="0" call :tar %%~s
)
if "!LOST!"=="0" call :text lists tar-lists-1.txt
if "!LOST!"=="0" call :text errs  device-errors-1.txt
goto :eof

:stage2
echo -- Fáze 2: celé oddíly obrazu ^(bez toho, co stáhla fáze 1^), APEX, /data/app --
for %%s in ("tar-apex apex.tar" "tar-dataapps data-apps.tar opt") do (
  if "!LOST!"=="0" call :tar %%~s
)
for /f "delims=" %%p in ('"%ADB%" shell sh %DEV% parts') do (
  if "!LOST!"=="0" (
    set "PN=%%p"
    call :tar tar-part "part-!PN:~1!.tar" "" "%%p"
  )
)
if "!LOST!"=="0" call :text lists tar-lists-2.txt
if "!LOST!"=="0" call :text errs  device-errors-2.txt
goto :eof

:text
echo ^> %~1 -^> %~2
>>"!LOG!" echo ^> %~1 -^> %~2
"%ADB%" shell sh %DEV% %~1 >"!OUT!\%~2" 2>&1
goto :eof

:tar
rem %1 krok, %2 soubor, %3 opt = prázdný je v pořádku, %4 oddíl pro tar-part
rem exec-out + přesměrování cmd jsou binárně bezpečné (v PowerShellu by ">" tar poškodil)
echo ^> %~1 -^> %~2 ...
findstr /l /x /c:"%~2" "!DONE!" >nul 2>nul
if not errorlevel 1 (
  echo    už staženo, přeskakuji
  >>"!LOG!" echo %~1: už staženo, přeskakuji
  goto :eof
)
"%ADB%" exec-out sh %DEV% %~1 %~4 >"!OUT!\%~2"
set "STATE="
for /f "usebackq tokens=*" %%s in (`"%ADB%" get-state 2^>nul`) do set "STATE=%%s"
if not "!STATE!"=="device" (
  echo    [x] spojení s HJ ztraceno
  >>"!LOG!" echo %~1: spojení s HJ ztraceno
  set "LOST=1"
  goto :eof
)
set "SZ=0"
for %%f in ("!OUT!\%~2") do set "SZ=%%~zf"
if "!HAVE_TAR!"=="0" if !SZ! GTR 10240 (
  echo    !SZ! bajtů ^(bez kontroly tar^)
  >>"!LOG!" echo %~1: !SZ! bajtů, bez kontroly
  >>"!DONE!" echo %~2
  goto :eof
)
set "N=0"
tar -tf "!OUT!\%~2" >nul 2>nul && for /f %%n in ('tar -tf "!OUT!\%~2" 2^>nul ^| find /c /v ""') do set "N=%%n"
if not "!N!"=="0" (
  echo    !N! položek, !SZ! bajtů
  >>"!LOG!" echo %~1: !N! položek, !SZ! bajtů
  >>"!DONE!" echo %~2
  goto :eof
)
rem prázdný tar = 0…10 KB nul; u nepovinných kroků to není chyba
if "%~3"=="opt" if !SZ! LEQ 10240 (
  echo    — prázdné
  >>"!LOG!" echo %~1: prázdné
  >>"!DONE!" echo %~2
  goto :eof
)
echo    [x] prázdný nebo poškozený tar
>>"!LOG!" echo %~1: prázdný nebo poškozený tar
set /a FAILS+=1
goto :eof
