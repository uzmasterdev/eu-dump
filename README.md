# EU výpis: stažení artefaktů z dárcovského vozu (VOYAH Courage H37Z)

**Čeština** · [English](README_EN.md)

Skripty pro **jednorázové** připojení k VOYAH Courage s evropským firmwarem přes ADB. EU verze má nativní bezdrátové
CarPlay, kdežto čínské sestavení jeho serverovou část nemá: chybí balíčky `com.mega.linkmanager` / `com.mega.carplay*`
a démon `/system/bin/CarPlayCommService`. Veřejně tyto soubory k dispozici nejsou, takže je lze získat jen ADB výpisem
z živého EU vozu. Dále skript stahuje hlasového asistenta (na EU voze mluví anglicky, čínské sestavení umí jen
čínsky), aplikace, které se v EU sestavení liší v kódu, a soubor firmwaru, pokud na jednotce zůstal.

Skript **pouze čte**. Na hlavní jednotce (HJ) vznikne dočasná složka `/data/local/tmp/eudump` a samotný skript, na
konci (v `eu-dump.sh` i po Ctrl+C) se obojí smaže. Nic se neinstaluje, vlastnosti systému se nemění. Jediné, co se na
dárcovském voze mění, je zapnutí ADB, a to je potřeba vrátit ([níže](#bezpečnost-dárcovského-vozu)).

## Soubory

| Soubor                                   | Co dělá                                                                                                                |
|------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| [`eu-dump.sh`](eu-dump.sh)               | spuštění z macOS a Linuxu                                                                                              |
| [`eu-dump.bat`](eu-dump.bat)             | spuštění z Windows                                                                                                     |
| [`eu-dump-device.sh`](eu-dump-device.sh) | logika, která běží na HJ (toybox `sh`, uid `shell`). Oba spouštěče ho nahrají do `/data/local/tmp` a volají po krocích |
| [`cn-packages.txt`](cn-packages.txt)     | balíčky čínského sestavení (kokpit 4.3.1, tovární obraz). Co na dárcovském voze v seznamu není, jde do `new.tar`        |
| [`cn-files.txt`](cn-files.txt)           | soubory čínského obrazu na `/system` (vč. `/system/product`), `/system_ext`, `/vendor`. Co v seznamu není, jde do `eufiles.tar` |
| [`platform-tools/`](platform-tools/)     | přenosné `adb.exe` + `AdbWinApi.dll`, `AdbWinUsbApi.dll` pro Windows — `eu-dump.bat` je použije, nic se neinstaluje      |
| `eu-<datum-čas>/`                        | výsledek běhu. ⛔ **Zavřeno v `.gitignore`**: gigabajty cizích binárek, sériová čísla, VIN a logcat **cizího vozu**    |

## Dvě fáze

Výpis je rozdělen na dvě fáze **bez překryvu**: každý archiv vynechá vše, co obsahují archivy před ním (stejné seznamy
cest → `tar -X`), a druhá fáze vynechá vše z první. Žádný soubor se nestahuje dvakrát.

**Fáze 1 — hlavní výsledky** (`./eu-dump.sh`), kolem 3 GB. Na emulátoru 3 minuty, na voze podle USB. Archivy jdou
v pořadí hodnoty: když dojde čas, nejdůležitější je už na disku a navázání pokračuje od přerušeného archivu.

| Soubor v `eu-<datum>/`  | Co obsahuje                                                                                                                                                                                                                                |
|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `report.txt`            | sestavení (`fingerprint`, `display.id`), celý `getprop`, `build.prop` oddílů, `df` a `/proc/mounts`, oddíly `by-name`, všechny balíčky s cestou, verzí a uid, APEX, `pm list libraries/features`, `BOOTCLASSPATH`/`SYSTEMSERVERCLASSPATH`; obsah `diff.tar`/`heavy.tar` s velikostmi; **soubory, které v čínském obrazu nejsou**, a z nich ty, které `shell` nepřečte |
| `carplay.txt`           | balíčky CarPlay a projekce, `dumpsys package` ke každému, soubory podle vzoru (= obsah `carplay.tar`), pravidla SELinux, `privapp-permissions`, vlastnosti, `service list`, procesy, uzly `/dev/i2c-*` a `/dev/iap*`, `dumpsys usb`, **programy služeb z `.rc` a jejich čitelnost**, knihovny podle jména (`libiap*`, `*mfi*`, `mdnssd` …), logcat |
| `voice.txt`             | balíčky hlasu, `dumpsys package`, strom `*/third_party` (modely ASR/KWS/NLU, hlasy TTS — tady je vidět, jaké jazyky jednotka má), verze a konfigurace prostředků, locale, `dumpsys voiceinteraction`, logcat                       |
| `ota-search.txt`        | obsah `/ota`, `/ota/load`, `/fota`, `/log/ota`, `/cache`, `<médium>/com.mega.update` atd.; vlastnosti a služby aktualizací; **kandidáti na soubor firmwaru** (řádky `FW:`). Logy `/log` a `/qlog` se nehledají (kromě `/log/ota`) |
| `carplay.tar`           | vše nalezené k CarPlay: soubory, APK balíčků, `.rc`, `/data/carplay`, pokud je čitelné                                                                                                                                                     |
| `etc.tar`               | `etc/` všech oddílů: permissions, init, selinux, vintf, zvukové politiky, `EcuTable.json`; plus `build.prop` a manifesty VINTF                                                                                                             |
| `new.tar`               | **systémové balíčky, které v čínském sestavení nejsou** (`cn-packages.txt`): server CarPlay, rádio, evropské služby a vše, o čem dopředu nevíme. Celé adresáře aplikací (s `lib/` a `oat/`). Aplikace nainstalované majitelem se nestahují  |
| `voice.tar`             | hlasový asistent: `VCOS_Voice` (`com.voyah.ai.voice`), `VCOS_Tts`, `VCOS_VoiceUI`, `VCOS_VoiceDrawing`, v EU `H37Z_MSVA` (`com.microsoft.assistant.client`) a `H37Z_AIWindow`, další balíčky podle jména (voice/tts/speech/asr/microsoft/cerence/nuance …) a celé `*/third_party` s modely; v čínském sestavení ~1,4 GB, v EU 1.1.4.508 ~1,1 GB |
| `ota-candidates.tar`    | nalezení kandidáti na soubor firmwaru                                                                                                                                                                                                      |
| `diff.tar`              | aplikace, které se v EU sestavení (H37Z) liší v kódu — viz [seznam níže](#aplikace-které-se-v-eu-liší) — a **všechny adresáře `H37Z_*`**; ~1–2 GB                                                                                          |
| `eufiles.tar`           | **soubory, které v čínském obrazu nejsou** (`cn-files.txt`) a nepatří do aplikací z předchozích archivů: knihovny, programy, konfigurace, prostředky EU. Bez FS připojených dovnitř oddílů (data IDPS, overlayfs, firmware modemu) |
| `heavy.tar`             | velké aplikace, které se liší: `VCOS_Map` (v EU skrytá mapa), `VCOS_VoyahMusic` (zahraniční hudba) a každý adresář `H37Z_*` nad 150 MB                                                                                                     |
| `tar-lists-1.txt`       | seznamy cest, ze kterých se skládal každý tar (pro kontrolu)                                                                                                                                                                               |
| `device-errors-1.txt`   | chyby na HJ (`Permission denied` apod.) po krocích                                                                                                                                                                                        |

**Fáze 2 — úplná, všechno ostatní** (`./eu-dump.sh --full`). Desítky minut až hodina, podle USB.

| Soubor v `eu-<datum>/`  | Co obsahuje                                                                                                         |
|-------------------------|---------------------------------------------------------------------------------------------------------------------|
| `apex.tar`              | rozbalené připojené APEX moduly: `javalib/`, `etc/`, manifesty (v oddílech jsou jen archivy `.apex`/`.capex`)       |
| `data-apps.tar`         | APK z `/data/app`: aktualizace systémových aplikací a aplikace třetích stran                                       |
| `part-<oddíl>.tar`      | každý oddíl obrazu celý (`/odm`, `/system_ext`, `/product`, `/vendor`, `/system` …), od menších k větším, **bez** toho, co je už ve fázi 1 |
| `tar-lists-2.txt`, `device-errors-2.txt` | totéž co u fáze 1                                                                                  |

Společné: `eu-dump.log` (průběh, počet položek a velikost každého archivu), `SHA256SUMS` (hashe archivů), `.done`
(archivy stažené celé, pro navázání).

### Aplikace, které se v EU liší

Všechny aplikace `VCOS_*` se sestavují s příznakem `FLAVOR=H37A` nebo `H37Z`, ale skutečné rozdíly v kódu mají jen
některé. Ty jdou do `diff.tar` (velikosti z čínského sestavení):

| Skupina | Adresáře aplikací | Proč |
|---|---|---|
| Jazyk | `H37_SJGD_ARService` (23 MB), `VCOS_InputMethod` (28 MB) | v EU vícejazyčnost (de/fr/nl/…), rozložení klávesnice |
| CarPlay | `VCOS_BluetoothPhone` (20 MB), `VCOS_EdgeSlide` (18 MB), `MontecarloSystemUI` (88 MB), `VCOS_SystemUi` (48 MB), `MontecarloWifiDialog` | v čínském sestavení pahýly (`DiffApi`), `persist.sys.carplay_enable`, správce zásuvných modulů projekce, hotspot pro bezdrátové CarPlay |
| Větve `is37Z()` | `VCOS_Launcher` (96 MB), `VCOS_Adas` (94 MB), `VCOS_Calendar` (21 MB), `MegaPermissionController` (69 MB), `VCOS_VehicleSettings` (176 MB) | rozvržení, v EU vypnuté hlasové výstrahy ADAS, zahraniční rozvržení, jednotky a nabídky |
| Region a cloud | `VCOS_Ecall` (26 MB), `VCOS_UserCenter`, `VCOS_VehicleActivation`, `VCOS_Mqtt_Service`, `VCOS_MessagePush`, `VCOS_Push`, `VCOS_AppStore`, `UpdateService`, `SystemUpdater`, `VCOS_Weather` | eCall 112, účet a aktivace na zahraničním backendu, cloudové kanály, obchod, OTA, počasí |

⚠️ **V EU sestavení mají adresáře aplikací prefix modelu**: `VCOS_EdgeSlide` → `H37Z_VCOS_EdgeSlide`,
`H37_SJGD_ARService` → `H37Z_SJGD_ARService` (na voze 1.1.4.508 jich je 38). Skript hledá všechny tři podoby jména
a navíc bere do `diff.tar` každý adresář `H37Z_*`: sestavuje se pro EU model, takže se od CN liší už z definice. První
výpis (2026-10-14) to ještě neuměl, proto v něm EU verze `VCOS_*` chybí.

Do fáze 1 nejdou (stáhne je fáze 2): velké a stejné nebo čistě čínské — `VCOS_SceneMode`, `VCOS_UnityServer`,
`VCOS_DrvAsstUnityServer`, `webview`, čínské video služby, `SentryService`/`DVR`/`AVM` (v EU osekané) a služby AOSP.

## Příprava

1. **adb.** Hledá se v tomto pořadí: proměnná `ADB`, složka `platform-tools/` vedle skriptu, `adb` v `PATH`.
   **Windows: nic instalovat netřeba**, `adb.exe` s knihovnami je v repozitáři (`platform-tools/`, adb z Google
   Platform-Tools, sha256 `e1657ca239bcf53f60dd622a8476d51b8df3c2a3169f7b6082142942560627ed`). macOS:
   `brew install android-platform-tools`. Linux: balíček `android-tools` nebo
   [Platform-Tools](https://developer.android.com/tools/releases/platform-tools) do `platform-tools/` vedle skriptu. Ke kontrole archivů na Windows je potřeba vestavěný `tar.exe` (Windows 10 1803 a novější). Bez něj skript
   stáhne vše, ale celistvost archivů neověří.
2. **Místo na disku.** Fáze 1: kolem 3 GB, plus soubor firmwaru, pokud se najde (jednotky GB). Fáze 2: dalších
   7–10 GB.
3. **Kabel USB-A ↔ USB-A** do portu ve středové konzoli.
4. **Zapnout ADB na voze.** Port v konzoli je z výroby v režimu host (pro flashky) a ADB na něm nejde. Do režimu device
   ho přepne **flashka se souborem `.usb.ini`** a nastavení ani inženýrské menu nejsou potřeba:
   - flashka FAT32, v kořeni soubor `.usb.ini` (jméno začíná tečkou), obsah přesně `mode=device`, prostý text **bez
     BOM**;
   - **žádný** soubor `.usb_ext.ini` / `usb.persist=true`: pak jde o jednorázový režim a po restartu HJ se port sám vrátí
     do host;
   - zasunout flashku do portu a počkat, až se připojí (flashka při přepnutí „odpadne“, to je v pořádku), pak ji vyndat
     a do téhož portu zapojit kabel;
   - na flashce kromě `.usb.ini` nic jiného nemít (⛔ hlavně ne OTA zip: aktualizátor vozu by ho mohl převzít);
   - na displeji vozu potvrdit žádost o ladění, **„vždy povolit z tohoto počítače“ nezaškrtávat**.

   ⚠️ Mechanismus je ověřený na čínské verzi (upravený `vold` od dodavatele kokpitu). Že EU sestavení obsahuje totéž,
   ověřeno není. ⛔ Pokud flashka nezabere, **do inženýrského menu vozu nelézt**: hned vedle jsou položky jako
   tovární reset `恢复出厂设置` (maže i eSIM), režim vozidla `车辆模式` (přeprava/předváděcí, blokuje převodovku) a zápis
   továrního kódování `配置字`.
5. **Souhlas majitele vozu.** Skript nic nemění, ale výpis obsahuje identifikátory jeho auta.

## Spuštění

macOS / Linux:

```bash
./eu-dump.sh                       # fáze 1 → nová složka eu-<datum>/
./eu-dump.sh --full                # fáze 2 → do poslední složky eu-*/
./eu-dump.sh --all                 # obě fáze za sebou
./eu-dump.sh ~/dumps/h37z          # fáze 1 do vlastní složky
./eu-dump.sh --full ~/dumps/h37z   # fáze 2 do téže složky
```

Windows (z `cmd`, **ne z PowerShellu**):

```bat
eu-dump.bat
eu-dump.bat --full
eu-dump.bat --all
```

⚠️ Přepínač (`--full` / `--all`) se zadává **jako první**, výstupní složka až za ním.

Doporučený postup: spustit fázi 1, rovnou zkontrolovat výsledky (níže) a teprve pak, pokud je čas, fázi 2.

Na konci fáze 1 skript vypíše do konzole kandidáty na soubor firmwaru a nalezené balíčky CarPlay. Návratový kód `1`
znamená, že některý povinný archiv je prázdný nebo poškozený: viz `eu-dump.log` a `device-errors-*.txt`. Prázdné
`carplay.tar`, `data-apps.tar` a `ota-candidates.tar` se za chybu nepovažují.

**Přerušení a navázání.** Po každém archivu skript ověří spojení s HJ. Pokud se ztratí (kabel, uspání HJ, restart),
skončí s kódem `2` a vypíše příkaz pro opakované spuštění **se stejnou složkou**. Archivy stažené celé (`.done`) se
přeskočí, přerušený archiv se stáhne znovu, textové přehledy se obnoví.

## Bezpečnost dárcovského vozu

Ověřeno v kódu skriptů a na emulátoru pod uid `shell` (stejná práva jako na skutečném voze, bez root):

- **Zápis na HJ**: jen `/data/local/tmp/eu-dump-device.sh`, `/data/local/tmp/eu-cn-packages.txt`,
  `/data/local/tmp/eu-cn-files.txt` a `/data/local/tmp/eudump/` (seznamy cest a chyby, jednotky MB). Archivy tečou proudem do notebooku (`exec-out tar … > soubor`), na HJ se nehromadí a místo nezabírají.
- **Příkazy na HJ jen čtou**: `getprop`, `pm list`/`pm path`, `dumpsys`, `logcat -d`, `ls`, `find`, `tar -c`.
  Žádné `setprop`, `settings put`, `am`, `pm install/disable`, `reboot`.
- **Čtení nesahá na zařízení**: procházení FS nevstupuje do `/proc`, `/sys`, `/dev`, `/config`, `/acct`; `tar` bere
  jen adresáře oddílů obrazu a běžné soubory. Uzly `/dev/*` se jen vypíšou (`ls`), neotevírají se.
- Pod uid `shell` se zavřené prostě nepřečte (`Permission denied` v `device-errors-*.txt`), obcházet práva se skript
  nepokouší.

Co záleží na lidech u vozu:

1. **Vůz stojí** (P, parkovací brzda), nejede. Archivy o gigabajtech zatěžují flash a CPU jednotky, rozhraní se může
   zpomalit. Za jízdy nespouštět.
2. **Napájení.** Fáze 2 může trvat až hodinu. Držet vůz v režimu Ready nebo na nabíječce, aby HJ uprostřed neusnula
   a nevybíjela se 12V baterie.
3. **Po výpisu vrátit vše do původního stavu:**
   - vyndat flashku s `.usb.ini` a **restartovat HJ** (jednorázový režim se zruší, port je zase host). Bez restartu:
     `adb shell setprop sys.usb.device_mode disable_persist`, nebo zasunout flashku s `.usb.ini` obsahujícím
     `mode=host`;
   - pokud se přece jen zaškrtlo „vždy povolit“: v „Pro vývojáře“ odvolat autorizace ladění (pokud je položka dostupná);
   - pokud se běh přerušil (kabel, uspání HJ): uklidit zbytky
     `adb shell rm -rf /data/local/tmp/eudump /data/local/tmp/eu-dump-device.sh /data/local/tmp/eu-cn-packages.txt /data/local/tmp/eu-cn-files.txt`. `eu-dump.bat` po Ctrl+C neuklízí,
     příkaz pak spustit ručně.

## Co zkontrolovat hned, dokud je vůz u vás

- V `carplay.txt` → „BALÍČKY podle vzoru“ by měly být `com.mega.linkmanager`, `com.mega.carplay` nebo
  `com.mega.carplayapp`. ⚠️ `com.thunder.carplay` je karaoke, ne CarPlay.
- V „Programy služeb CarPlay z .rc“ budou `/system/bin/CarPlayCommService`, `IAPCommService` a `megalink.sh`.
  Démoni jsou pod `shell` **nečitelní** (na 1.1.4.508 SELinux nedovolí ani `ls`) — to se očekává, viz omezení.
- Pokud balíčky jsou, ale `carplay.tar` je prázdný nebo malý: viz `device-errors-1.txt`, oddíl `tar-carplay.err`.
- Pokud jsou v `ota-search.txt` kandidáti (`FW:`), ověřit, že je `ota-candidates.tar` obsahuje (`tar -tvf`).
- V `report.txt` → „BALÍČKY, které v čínském sestavení nejsou“ (vše je v `new.tar`) a „SOUBORY, které v čínském
  obrazu nejsou“ (vše čitelné je v `eufiles.tar`): to je jádro rozdílu EU/CN.
- V `voice.txt` → strom `*/third_party`: hledat anglické prostředky (adresáře nebo soubory `en`, `en-US`, `english`,
  hlasy `en-US-*Neural`) a jiného dodavatele než iFlytek (`cerence`, `nuance`). Na displeji vozu přepnout asistenta
  do angličtiny a spustit fázi 1 znovu do stejné složky: textové přehledy a logcat se obnoví, archivy se nestahují znovu.

## Omezení

- Skript běží pod uid `shell` bez root. Co je pro `shell` zavřené, se nestáhne: `/data` (kromě `/data/app` podle
  přesných cest), `/vendor/build.prop`, část `/vendor/bin`, `/ota/package`, `/data/ota_package`,
  `/mnt/vendor/persist`, některé soubory SELinux (`*_hwservice_contexts`, `*_mac_permissions.xml`). U takových míst
  bude v přehledu výpis adresáře nebo `Permission denied`.
- **Nativní démoni CarPlay** `/system/bin/CarPlayCommService` a `IAPCommService` (kontext
  `carplaycommunication_exec`/`iapcommunication_exec`) jsou pro `shell` zavření úplně, nestáhne je ani fáze 2. Bez
  nich se CarPlay jinde nespustí; dostat je jde jen z OTA balíčku H37Z nebo z obrazu oddílu (root, servis).
- **Poloha vozu**: z výňatků logcat v `carplay.txt` a `voice.txt` se vyhazují věty NMEA a souřadnice
  (`IAPCommService` do logu píše polohu, kterou posílá do iPhonu). `getprop` v `report.txt` dál obsahuje VIN a
  sériová čísla.
- **Soubor firmwaru** se najde, jen pokud leží na přístupném místě: `/ota/load`, `/fota`, `/sdcard`, na flashce.
  Balíček stažený přes OTA se po instalaci obvykle maže.
- `adb pull` se nepoužívá: na čínské verzi SELinux nepouští sync-službu `adbd` do části oddílů, kdežto `tar` pod
  `shell` je přečte. Proto se vše stahuje přes `adb exec-out tar`.
- ✅ Ověřeno na laboratorním emulátoru HJ (sestavení 4.3.1) pod uid `shell`: fáze 1 a 2, žádný soubor ve dvou
  archivech, `new.tar` pro balíčky vyňaté ze seznamu, nalezení podstrčeného testovacího souboru firmwaru s mezerami ve
  jméně, navázání, úklid na HJ, `eufiles` (na CN emulátoru jen rozdíly emulátoru, data IDPS a overlay vyřazeny).
- ✅ **Živý EU vůz**, sestavení `V1.1.4.508-20251125`, 2026-10-14, Windows, fáze 1: všech 7 archivů celých, sha256
  sedí. Nalezeno: `com.mega.carplay` 1.0.95 + `com.mega.linkmanager`, `libcarplayplugin_R17A8.so`,
  `init.megalink.rc`, `/system/etc/carplay/`, MFi 3.0 aktivní; hlas = Microsoft (`com.microsoft.assistant.client`).
  Nenalezeno: soubor firmwaru (v kandidátech byly jen logy — proto se teď `/log` a `/qlog` nehledají), EU verze
  `VCOS_*` (chyba s prefixem `H37Z_`, opraveno). Na Windows selhal `Get-FileHash` — teď je záloha přes `certutil`.

## Po výpisu

⛔ Z `report.txt`/`carplay.txt` nic nepublikovat bez vyčištění: sériová čísla, VIN, MAC adresy a ICCID cizího vozu.
Surová data zůstávají v `eu-<datum>/` mimo git.
