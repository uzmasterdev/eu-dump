# EU dump: pulling artifacts from a donor car (VOYAH Courage H37Z)

[Čeština](README.md) · **English**

Scripts for a **one-time** ADB connection to a VOYAH Courage running the European firmware. The EU version has native
wireless CarPlay, while the Chinese build lacks its server side: the packages `com.mega.linkmanager` /
`com.mega.carplay*` and the daemon `/system/bin/CarPlayCommService` are missing. These files are not publicly
available, so the only way to get them is an ADB dump from a live EU car. The script also pulls the voice assistant
(it speaks English on the EU car, the Chinese build only speaks Chinese), the apps whose code differs in the EU build,
and the firmware file if it is still on the unit.

The script **only reads**. On the head unit (HU) it creates a temporary folder `/data/local/tmp/eudump` and the script
itself; at the end (in `eu-dump.sh` also on Ctrl+C) both are deleted. Nothing is installed, no system properties are
changed. The only change to the donor car is enabling ADB, and that has to be reverted ([below](#donor-car-safety)).

The scripts' console output and report section headings are in Czech; this file quotes them verbatim with an English
explanation.

## Files

| File                                     | What it does                                                                                                         |
|------------------------------------------|----------------------------------------------------------------------------------------------------------------------|
| [`eu-dump.sh`](eu-dump.sh)               | launcher for macOS and Linux                                                                                         |
| [`eu-dump.bat`](eu-dump.bat)             | launcher for Windows                                                                                                 |
| [`eu-dump-device.sh`](eu-dump-device.sh) | logic that runs on the HU (toybox `sh`, uid `shell`). Both launchers push it to `/data/local/tmp` and call it step by step |
| [`cn-packages.txt`](cn-packages.txt)     | packages of the Chinese build (cockpit 4.3.1, factory image). Anything on the donor car that is not on this list goes to `new.tar` |
| [`cn-files.txt`](cn-files.txt)           | files of the Chinese image on `/system` (incl. `/system/product`), `/system_ext`, `/vendor`. Anything not on this list goes to `eufiles.tar` |
| [`platform-tools/`](platform-tools/)     | portable `adb.exe` + `AdbWinApi.dll`, `AdbWinUsbApi.dll` for Windows — `eu-dump.bat` uses them, nothing gets installed |
| `eu-<date-time>/`                        | output of a run. ⛔ **Excluded in `.gitignore`**: gigabytes of third-party binaries, serial numbers, VIN and logcat of **someone else's car** |

## Two phases

The dump is split into two phases **without overlap**: each archive skips everything contained in the archives before
it (same path lists → `tar -X`), and phase 2 skips everything from phase 1. No file is downloaded twice.

**Phase 1 — the main wins** (`./eu-dump.sh`), about 3 GB. 3 minutes on the emulator, on the car depending on USB.
Archives come in order of value: if time runs out, the most important part is already on disk and a resumed run
continues from the interrupted archive.

| File in `eu-<date>/`    | Contents                                                                                                                                                                                                                                   |
|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `report.txt`            | build (`fingerprint`, `display.id`), full `getprop`, partition `build.prop` files, `df` and `/proc/mounts`, `by-name` partitions, all packages with path, version and uid, APEX, `pm list libraries/features`, `BOOTCLASSPATH`/`SYSTEMSERVERCLASSPATH`; contents of `diff.tar`/`heavy.tar` with sizes; **files that are not in the Chinese image**, and which of them `shell` cannot read |
| `carplay.txt`           | CarPlay and projection packages, `dumpsys package` for each, files matching the pattern (= contents of `carplay.tar`), SELinux rules, `privapp-permissions`, properties, `service list`, processes, `/dev/i2c-*` and `/dev/iap*` nodes, `dumpsys usb`, **programs of the services in `.rc` and whether they are readable**, libraries by name (`libiap*`, `*mfi*`, `mdnssd` …), logcat |
| `voice.txt`             | voice packages, `dumpsys package`, the `*/third_party` tree (ASR/KWS/NLU models, TTS voices — this shows which languages the unit has), resource versions and configs, locale, `dumpsys voiceinteraction`, logcat |
| `ota-search.txt`        | contents of `/ota`, `/ota/load`, `/fota`, `/log/ota`, `/cache`, `<storage>/com.mega.update` etc.; update properties and services; **firmware file candidates** (lines starting with `FW:`). Logs in `/log` and `/qlog` are not searched (except `/log/ota`) |
| `carplay.tar`           | everything found for CarPlay: files, package APKs, `.rc`, `/data/carplay` if readable                                                                                                                                                      |
| `etc.tar`               | `etc/` of all partitions: permissions, init, selinux, vintf, audio policies, `EcuTable.json`; plus `build.prop` and VINTF manifests                                                                                                        |
| `new.tar`               | **system packages that are not in the Chinese build** (`cn-packages.txt`): the CarPlay server, radio, European services and anything we don't know about in advance. Whole app directories (with `lib/` and `oat/`). Apps installed by the owner are not pulled |
| `voice.tar`             | voice assistant: `VCOS_Voice` (`com.voyah.ai.voice`), `VCOS_Tts` (`com.voyah.vcos.ttsservices`), `VCOS_VoiceUI`, `VCOS_VoiceDrawing`, in the EU `H37Z_MSVA` (`com.microsoft.assistant.client`) and `H37Z_AIWindow`, other packages matched by name (voice/tts/speech/asr/microsoft/cerence/nuance …) and all of `*/third_party` with the models; ~1.4 GB in the Chinese build, ~1.1 GB in EU 1.1.4.508 |
| `ota-candidates.tar`    | firmware file candidates that were found                                                                                                                                                                                                   |
| `diff.tar`              | apps whose code differs in the EU build (H37Z) — see the [list below](#apps-that-differ-in-the-eu-build) — and **every `H37Z_*` directory**; ~1–2 GB |
| `eufiles.tar`           | **files that are not in the Chinese image** (`cn-files.txt`) and do not belong to apps in earlier archives: libraries, programs, configs, EU resources. Without file systems mounted inside partitions (IDPS data, overlayfs, modem firmware) |
| `heavy.tar`             | large apps that differ: `VCOS_Map` (map hidden in the EU), `VCOS_VoyahMusic` (non-Chinese music) and every `H37Z_*` directory over 150 MB |
| `tar-lists-1.txt`       | path lists each tar was built from (for checking)                                                                                                                                                                                          |
| `device-errors-1.txt`   | errors on the HU (`Permission denied` etc.) per step                                                                                                                                                                                       |

**Phase 2 — full, everything else** (`./eu-dump.sh --full`). Tens of minutes up to an hour, depending on USB.

| File in `eu-<date>/`    | Contents                                                                                                            |
|-------------------------|---------------------------------------------------------------------------------------------------------------------|
| `apex.tar`              | unpacked mounted APEX modules: `javalib/`, `etc/`, manifests (partitions only hold `.apex`/`.capex` archives)        |
| `data-apps.tar`         | APKs from `/data/app`: updates of system apps and third-party apps                                                  |
| `part-<partition>.tar`  | each image partition in full (`/odm`, `/system_ext`, `/product`, `/vendor`, `/system` …), smallest first, **without** what is already in phase 1 |
| `tar-lists-2.txt`, `device-errors-2.txt` | same as in phase 1                                                                                 |

Shared: `eu-dump.log` (progress, entry count and size of each archive), `SHA256SUMS` (archive hashes), `.done`
(archives downloaded completely, for resuming).

### Apps that differ in the EU build

All `VCOS_*` apps are built with the flag `FLAVOR=H37A` or `H37Z`, but only some of them have real code differences.
Those go to `diff.tar` (sizes from the Chinese build):

| Group | App directories | Why |
|---|---|---|
| Language | `H37_SJGD_ARService` (23 MB), `VCOS_InputMethod` (28 MB) | multilingual in the EU (de/fr/nl/…), keyboard layouts |
| CarPlay | `VCOS_BluetoothPhone` (20 MB), `VCOS_EdgeSlide` (18 MB), `MontecarloSystemUI` (88 MB), `VCOS_SystemUi` (48 MB), `MontecarloWifiDialog` | stubs in the Chinese build (`DiffApi`), `persist.sys.carplay_enable`, projection plugin manager, hotspot for wireless CarPlay |
| `is37Z()` branches | `VCOS_Launcher` (96 MB), `VCOS_Adas` (94 MB), `VCOS_Calendar` (21 MB), `MegaPermissionController` (69 MB), `VCOS_VehicleSettings` (176 MB) | layouts, ADAS voice warnings disabled in the EU, non-Chinese layouts, units and menus |
| Region and cloud | `VCOS_Ecall` (26 MB), `VCOS_UserCenter`, `VCOS_VehicleActivation`, `VCOS_Mqtt_Service`, `VCOS_MessagePush`, `VCOS_Push`, `VCOS_AppStore`, `UpdateService`, `SystemUpdater`, `VCOS_Weather` | eCall 112, account and activation on the overseas backend, cloud channels, app store, OTA, weather |

⚠️ **In the EU build app directories carry the model prefix**: `VCOS_EdgeSlide` → `H37Z_VCOS_EdgeSlide`,
`H37_SJGD_ARService` → `H37Z_SJGD_ARService` (38 of them on the 1.1.4.508 car). The script looks for all three forms
of the name and also puts every `H37Z_*` directory into `diff.tar`: it is built for the EU model, so it differs from
CN by definition. The first dump (2026-10-14) could not do that yet, which is why the EU `VCOS_*` builds are missing
from it.

Not in phase 1 (phase 2 pulls them): large and identical or purely Chinese — `VCOS_SceneMode`, `VCOS_UnityServer`,
`VCOS_DrvAsstUnityServer`, `webview`, Chinese video services, `SentryService`/`DVR`/`AVM` (cut down in the EU) and
AOSP services.

## Preparation

1. **adb.** Looked up in this order: the `ADB` variable, the `platform-tools/` folder next to the script, `adb` in
   `PATH`. **Windows: nothing to install**, `adb.exe` with its libraries is in the repository (`platform-tools/`, adb
   from Google Platform-Tools, sha256 `e1657ca239bcf53f60dd622a8476d51b8df3c2a3169f7b6082142942560627ed`). macOS:
   `brew install android-platform-tools`. Linux: the `android-tools` package or
   [Platform-Tools](https://developer.android.com/tools/releases/platform-tools) into `platform-tools/` next to the
   script. Checking archives on Windows needs the built-in `tar.exe` (Windows 10 1803 and later). Without it the
   script downloads everything but cannot verify archive integrity.
2. **Disk space.** Phase 1: about 3 GB, plus the firmware file if found (a few GB). Phase 2: another 7–10 GB.
3. **USB-A ↔ USB-A cable** into the port in the center console.
4. **Enable ADB on the car.** The console port is in host mode from the factory (for flash drives) and ADB does not
   work on it. A **flash drive with a `.usb.ini` file** switches it to device mode; no settings or engineering menu
   are needed:
   - FAT32 flash drive, file `.usb.ini` in the root (the name starts with a dot), content exactly `mode=device`, plain
     text **without BOM**;
   - **no** `.usb_ext.ini` / `usb.persist=true` file: that keeps the mode one-time, and after an HU restart the port
     goes back to host by itself;
   - plug the flash drive into the port and wait until it mounts (the drive "drops off" when the port switches, that is
     expected), then remove it and plug the cable into the same port;
   - nothing on the flash drive except `.usb.ini` (⛔ especially no OTA zip: the car's updater might pick it up);
   - confirm the debugging prompt on the car's screen, **do not tick "always allow from this computer"**.

   ⚠️ The mechanism is verified on the Chinese version (a `vold` modified by the cockpit supplier). Whether the EU build
   contains the same is not verified. ⛔ If the flash drive does not work, **do not go into the car's engineering
   menu**: right next to the relevant items are things like factory reset `恢复出厂设置` (also wipes the eSIM), vehicle
   mode `车辆模式` (transport/showroom, locks the transmission) and writing the factory coding `配置字`.
5. **The car owner's consent.** The script changes nothing, but the dump contains identifiers of their car.

## Running

macOS / Linux:

```bash
./eu-dump.sh                       # phase 1 → new folder eu-<date>/
./eu-dump.sh --full                # phase 2 → into the latest eu-*/ folder
./eu-dump.sh --all                 # both phases in a row
./eu-dump.sh ~/dumps/h37z          # phase 1 into a custom folder
./eu-dump.sh --full ~/dumps/h37z   # phase 2 into the same folder
```

Windows (from `cmd`, **not from PowerShell**):

```bat
eu-dump.bat
eu-dump.bat --full
eu-dump.bat --all
```

⚠️ The switch (`--full` / `--all`) goes **first**, the output folder after it.

Recommended order: run phase 1, check the results right away (see below), and only then, if there is time, run
phase 2.

At the end of phase 1 the script prints the firmware file candidates and the CarPlay packages found to the console.
Exit code `1` means some required archive is empty or corrupt: see `eu-dump.log` and `device-errors-*.txt`. Empty
`carplay.tar`, `data-apps.tar` and `ota-candidates.tar` are not treated as errors.

**Interruption and resuming.** After each archive the script checks the connection to the HU. If it is lost (cable,
HU going to sleep, restart), it exits with code `2` and prints the command to run again **with the same folder**.
Archives downloaded completely (`.done`) are skipped, the interrupted archive is downloaded again, text reports are
refreshed.

## Donor car safety

Verified in the script code and on the emulator under uid `shell` (same permissions as on the real car, no root):

- **Writes on the HU**: only `/data/local/tmp/eu-dump-device.sh`, `/data/local/tmp/eu-cn-packages.txt`,
  `/data/local/tmp/eu-cn-files.txt` and `/data/local/tmp/eudump/` (path lists and errors, a few MB). Archives stream to the laptop
  (`exec-out tar … > file`); they do not accumulate on the HU and take no space there.
- **Commands on the HU only read**: `getprop`, `pm list`/`pm path`, `dumpsys`, `logcat -d`, `ls`, `find`, `tar -c`.
  No `setprop`, `settings put`, `am`, `pm install/disable`, `reboot`.
- **Reading does not touch devices**: the filesystem walk does not enter `/proc`, `/sys`, `/dev`, `/config`, `/acct`;
  `tar` only takes image partition directories and regular files. `/dev/*` nodes are only listed (`ls`), never opened.
- Under uid `shell` anything closed is simply not read (`Permission denied` in `device-errors-*.txt`); the script
  makes no attempt to bypass permissions.

What depends on the people at the car:

1. **The car is stationary** (P, parking brake), not driving. Multi-gigabyte archives load the unit's flash and CPU,
   the UI may slow down. Do not run while driving.
2. **Power.** Phase 2 can take up to an hour. Keep the car in Ready mode or on the charger so the HU does not fall
   asleep midway and the 12V battery does not drain.
3. **Afterwards, put everything back the way it was:**
   - remove the flash drive with `.usb.ini` and **restart the HU** (the one-time mode is cleared, the port is host
     again). Without a restart: `adb shell setprop sys.usb.device_mode disable_persist`, or plug in a flash drive whose
     `.usb.ini` contains `mode=host`;
   - if "always allow" was ticked after all: revoke USB debugging authorizations in "Developer options" (if the item
     is available);
   - if the run was interrupted (cable, HU sleep): clean up the leftovers with
     `adb shell rm -rf /data/local/tmp/eudump /data/local/tmp/eu-dump-device.sh /data/local/tmp/eu-cn-packages.txt /data/local/tmp/eu-cn-files.txt`.
     `eu-dump.bat` does not clean up after Ctrl+C, run the command manually in that case.

## What to check right away, while the car is with you

- In `carplay.txt` → "BALÍČKY podle vzoru" (packages matching the pattern) there should be `com.mega.linkmanager`,
  `com.mega.carplay` or `com.mega.carplayapp`. ⚠️ `com.thunder.carplay` is karaoke, not CarPlay.
- In "Programy služeb CarPlay z .rc" (programs of the CarPlay services) there will be
  `/system/bin/CarPlayCommService`, `IAPCommService` and `megalink.sh`. The daemons are **not readable** under
  `shell` (on 1.1.4.508 SELinux does not even allow `ls`) — this is expected, see the limitations.
- In `report.txt` → "SOUBORY, které v čínském obrazu nejsou" (files not in the Chinese image): everything readable
  from it is in `eufiles.tar`.
- If the packages are there but `carplay.tar` is empty or small: see `device-errors-1.txt`, section
  `tar-carplay.err`.
- If `ota-search.txt` has candidates (`FW:`), check that `ota-candidates.tar` contains them (`tar -tvf`).
- In `report.txt` → "BALÍČKY, které v čínském sestavení nejsou" (packages not in the Chinese build): this is the core
  of the EU/CN difference, all of it is in `new.tar`.
- In `voice.txt` → the `*/third_party` tree: look for English resources (directories or files `en`, `en-US`,
  `english`, voices `en-US-*Neural`) and a supplier other than iFlytek (`cerence`, `nuance`). Switch the assistant to
  English on the car's screen and run phase 1 again into the same folder: text reports and logcat are refreshed,
  archives are not downloaded again.

## Limitations

- The script runs under uid `shell` without root. Whatever is closed to `shell` is not pulled: `/data` (except
  `/data/app` by exact paths), `/vendor/build.prop`, part of `/vendor/bin`, `/ota/package`, `/data/ota_package`,
  `/mnt/vendor/persist`, some SELinux files (`*_hwservice_contexts`, `*_mac_permissions.xml`). For such places the
  report will contain a directory listing or `Permission denied`.
- **The native CarPlay daemons** `/system/bin/CarPlayCommService` and `IAPCommService` (contexts
  `carplaycommunication_exec`/`iapcommunication_exec`) are fully closed to `shell`; not even phase 2 pulls them.
  Without them CarPlay will not start elsewhere; they can only come from an H37Z OTA package or a partition image
  (root, service tools).
- **Car location**: NMEA sentences and coordinates are dropped from the logcat excerpts in `carplay.txt` and
  `voice.txt` (`IAPCommService` logs the position it sends to the iPhone). `getprop` in `report.txt` still contains
  the VIN and serial numbers.
- **The firmware file** is found only if it sits somewhere accessible: `/ota/load`, `/fota`, `/sdcard`, a flash drive.
  A package downloaded via OTA is usually deleted after installation.
- `adb pull` is not used: on the Chinese version SELinux does not let the `adbd` sync service into some partitions,
  while `tar` under `shell` can read them. That is why everything is pulled via `adb exec-out tar`.
- ✅ Verified on a lab emulator of the HU (build 4.3.1) under uid `shell`: phases 1 and 2, no file in two archives,
  `new.tar` for packages removed from the list, finding a planted test firmware file with spaces in its name,
  resuming, cleanup on the HU, `eufiles` (on the CN emulator only emulator differences; IDPS data and overlay excluded).
- ✅ **Live EU car**, build `V1.1.4.508-20251125`, 2026-10-14, Windows, phase 1: all 7 archives complete, sha256
  matches. Found: `com.mega.carplay` 1.0.95 + `com.mega.linkmanager`, `libcarplayplugin_R17A8.so`,
  `init.megalink.rc`, `/system/etc/carplay/`, MFi 3.0 active; voice = Microsoft (`com.microsoft.assistant.client`).
  Not found: the firmware file (candidates were only logs — that is why `/log` and `/qlog` are no longer searched),
  the EU `VCOS_*` builds (the `H37Z_` prefix bug, fixed). `Get-FileHash` failed on Windows — `certutil` is now the
  fallback.

## After the dump

⛔ Do not publish anything from `report.txt`/`carplay.txt` without cleaning it up: serial numbers, VIN, MAC addresses
and ICCID of someone else's car. Raw data stays in `eu-<date>/` outside git.
