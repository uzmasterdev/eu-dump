#!/system/bin/sh
#
# Část eu-dump.sh / eu-dump.bat — běží NA HLAVNÍ JEDNOTCE (toybox sh, uid shell).
# Hostitelský skript ho nahraje do /data/local/tmp (spolu se seznamem čínských balíčků) a volá po krocích:
#   sh eu-dump-device.sh <krok> [oddíl]
# Textové kroky píší zprávu na stdout, tar-kroky tar-proud na stdout
# (hostitel ho přijímá přes `adb exec-out`, protože `adb pull` z části oddílů
# nefunguje — SELinux nepustí sync-službu adbd, kdežto shell číst může).
# Chyby (Permission denied apod.) jdou do $W/<krok>.err: exec-out slévá stderr
# do stejného proudu, proto se v tar-krocích vše navíc odvádí do souboru nebo /dev/null.
#
# Dvě fáze výpisu bez překryvu. Každý archiv vynechá vše, co obsahují archivy před ním (tar -X):
#   1 (rychlá)  report carplay voice ota → tar-carplay tar-etc tar-new tar-voice tar-ota tar-diff tar-heavy
#   2 (úplná)   tar-apex tar-dataapps tar-part <oddíl>… — všechno ostatní
#
# Pouze čtení: na jednotce se nic nemění kromě pracovní složky /data/local/tmp/eudump.
#
W=/data/local/tmp/eudump
CN_PKGS=/data/local/tmp/eu-cn-packages.txt   # balíčky čínského sestavení (nahrává hostitel)
mkdir -p "$W"
STAGE="$1"
ARG="${2:-}"
ERR="$W/$STAGE${ARG:+-${ARG##*/}}.err"
: >"$ERR"

# Oddíly obrazu (ro) — v pořadí „nejdřív malé“. Výpis /apex je zavřený — moduly bereme z /proc/mounts.
PARTS="/odm /oem /system_dlkm /vendor_dlkm /system_ext /product /vendor /system"

# Jména, podle kterých hledáme stack CarPlay / projekce.
# Zachytí i com.thunder.carplay (karaoke) — při rozboru vyřadit.
CP_RE='carplay|linkmanager|iap2|iapcomm|iap_|/iap|mfi|androidauto|android_auto|projection|airplay|carlife|megalink'

# Hlasový asistent: balíčky podle jména, soubory podle cesty (prostředky ASR/TTS leží mimo APK, v */third_party)
VOICE_PKG_RE='voice|\.tts|ttsserv|speech|asr|vui|nlu|iflytek|cerence|nuance|aispeech|unisound|assistant|wakeup'
VOICE_PATH_RE='/third_party$|iflytek|cerence|nuance|aispeech|unisound'
VOICE_APPS='VCOS_Voice VCOS_Tts VCOS_VoiceUI VCOS_VoiceDrawing'

# Aplikace, které se v EU sestavení (H37Z) liší v kódu: jazyky, CarPlay, větve is37Z(), region a cloud
DIFF_APPS='H37_SJGD_ARService VCOS_InputMethod
  VCOS_BluetoothPhone VCOS_EdgeSlide MontecarloSystemUI VCOS_SystemUi MontecarloWifiDialog
  VCOS_Launcher VCOS_Adas VCOS_Calendar MegaPermissionController VCOS_VehicleSettings
  VCOS_Ecall VCOS_UserCenter VCOS_VehicleActivation VCOS_Mqtt_Service VCOS_MessagePush VCOS_Push
  VCOS_AppStore UpdateService SystemUpdater VCOS_Weather'
# Liší se také, ale jsou velké — na konec 1. fáze
HEAVY_APPS='VCOS_Map VCOS_VoyahMusic'

# Procházení FS pro kandidáty nevstupuje do duplicitních pohledů na totéž úložiště (FUSE/bind: /mnt/user,
# /mnt/media_rw ↔ /storage/<UUID>, /data/media ↔ /storage/emulated) — jinak by soubor z flashky byl v archivu dvakrát.
# Určitě ne firmware: logy, data a nainstalované kopie aplikací, ART cache, vlastní pracovní složka
NOT_FW='^/log/(android|qnx|adas|kernel|anr|tombstone)|^/data/(data|user|user_de|app|dalvik-cache|misc|local/traces|system|system_ce|system_de|vendor_ce|vendor_de)/|^/data_mirror/|^/data/local/tmp/eudump/'
MEDIA_RE='\.(mp4|mkv|avi|mov|h264|h265|ts|jpg|jpeg|png|mp3|flac|wav|aac|m4a|ogg)$'

sec() { printf '\n\n===== %s =====\n' "$1"; }
run() { printf '\n$ %s\n' "$*"; sh -c "$*" 2>&1; }

# Oddíly, které skutečně existují. Odkazy (/odm → /vendor/odm apod.) přeskakujeme — jejich obsah
# se stáhne z vlastnického oddílu, jinak by vznikly duplicity.
parts() {
  for p in $PARTS; do [ -d "$p" ] && [ ! -L "$p" ] && echo "$p"; done
}

# Cesty připojených APEX modulů (bez @verze — duplicity)
apex_dirs() {
  awk '$2 ~ "^/apex/[^/]+$" && $2 !~ "@" {print $2}' /proc/mounts 2>/dev/null | sort -u
}

# Cesty všech APK z pm, včetně splitů a aktualizovaných systémových v /data/app
pkg_apk_paths() {
  pm list packages -a 2>/dev/null | sed 's/^package://' | while read -r p; do
    pm path "$p" 2>/dev/null | sed 's/^package://'
  done | sort -u
}

# APK balíčku → co archivovat: celý adresář aplikace (s lib/ a oat/), pokud v něm APK leží samo;
# jinak (APK přímo v app/, overlay/ nebo v /data/app) jen soubor
pkg_items() {
  pm path "$1" 2>/dev/null | sed 's/^package://' | while read -r a; do
    d="${a%/*}"
    case "$a" in
      /data/*) echo "$a" ;;
      *) case "$d" in */app|*/priv-app|*/overlay|*/framework) echo "$a" ;; *) echo "$d" ;; esac ;;
    esac
  done
}

# Ze seznamu cest vyhodí ty, jejichž předek už v seznamu je (jinak by je tar zabalil dvakrát)
collapse() {
  sort -u | awk '{
    n = split($0, a, "/"); p = ""; skip = 0
    for (i = 2; i < n; i++) { p = p "/" a[i]; if (p in k) { skip = 1; break } }
    if (!skip) { k[$0] = 1; print }
  }'
}

# Adresáře aplikací podle jména (app/ a priv-app/ všech oddílů)
app_dirs() {
  for n in $*; do
    for p in $(parts); do for d in app priv-app; do [ -d "$p/$d/$n" ] && echo "$p/$d/$n"; done; done
  done
}

# ---- seznamy se sestaví jednou za sezení a kroky je sdílejí (nový .lst vzniká jen přes mv, celý)

# Úplný seznam cest na oddílech obrazu — jeden průchod find pro všechna hledání podle vzoru
index() {
  L="$W/index.lst"; [ -e "$L" ] && return
  for p in $(parts); do find "$p" 2>/dev/null; done >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Vše k CarPlay/projekci: soubory podle vzoru na oddílech a v APEX, .rc, APK balíčků, /data/carplay
carplay_list() {
  index   # dřív než L: proměnné funkcí v sh jsou globální a index() si L přepíše
  L="$W/carplay.lst"; [ -e "$L" ] && return
  {
    grep -iE "$CP_RE" "$W/index.lst"
    for a in $(apex_dirs); do find "$a" 2>/dev/null | grep -iE "$CP_RE"; done
    for p in $(parts); do grep -rliE 'carplay|iapcomm|linkmanager' "$p/etc/init" 2>/dev/null; done
    for p in $(pm list packages -a 2>/dev/null | sed 's/^package://' | grep -iE "$CP_RE"); do pkg_items "$p"; done
    for d in /data/carplay /data/iap /data/vendor/carplay; do [ -r "$d" ] && echo "$d"; done
  } | collapse >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Konfigurace oddílů: celé etc/ + build.prop a manifesty VINTF
etc_list() {
  L="$W/etc.lst"; [ -e "$L" ] && return
  for p in $(parts); do
    [ -d "$p/etc" ] && echo "$p/etc"
    for f in "$p/build.prop" "$p/manifest.xml" "$p/compatibility_matrix.xml"; do [ -r "$f" ] && echo "$f"; done
  done >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Systémové balíčky, které v čínském sestavení nejsou (EU-only: CarPlay, rádio, evropské služby …).
# Jen -s: aplikace, které si nainstaloval majitel vozu, k firmwaru nepatří (aktualizace systémových v /data zůstávají)
new_pkgs() {
  if [ -r "$CN_PKGS" ]; then
    pm list packages -s 2>/dev/null | sed 's/^package://' | grep -vxF -f "$CN_PKGS"
  else
    echo "chybí seznam čínských balíčků $CN_PKGS" >>"$ERR"
  fi
}
new_list() {
  L="$W/new.lst"; [ -e "$L" ] && return
  for p in $(new_pkgs); do pkg_items "$p"; done | collapse >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Hlasový asistent: aplikace (i aktualizace v /data/app), */third_party (modely ASR/KWS/NLU, hlasy TTS), knihovny dodavatelů
voice_pkgs() {
  pm list packages -a 2>/dev/null | sed 's/^package://' | grep -iE "$VOICE_PKG_RE"
}
voice_list() {
  index
  L="$W/voice.lst"; [ -e "$L" ] && return
  {
    app_dirs $VOICE_APPS
    grep -iE "$VOICE_PATH_RE" "$W/index.lst"
    for p in $(voice_pkgs); do pkg_items "$p"; done
  } | collapse >"$L.tmp"
  mv "$L.tmp" "$L"
}

diff_list() {
  L="$W/diff.lst"; [ -e "$L" ] && return
  app_dirs $DIFF_APPS | collapse >"$L.tmp"
  mv "$L.tmp" "$L"
}

heavy_list() {
  L="$W/heavy.lst"; [ -e "$L" ] && return
  app_dirs $HEAVY_APPS | collapse >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Kandidáti na soubor firmwaru — jeden průchod FS: podle jména (> 1 MB) nebo prostě velké (> 30 MB), bez médií
ota_list() {
  L="$W/ota.lst"; [ -e "$L" ] && return
  find / \( -path /proc -o -path /sys -o -path /dev -o -path /acct -o -path /config -o -path /d \
            -o -path /system -o -path /system_ext -o -path /vendor -o -path /product -o -path /odm -o -path /apex \
            -o -path /mnt/user -o -path /mnt/pass_through -o -path /mnt/installer -o -path /mnt/androidwritable \
            -o -path /mnt/runtime -o -path /mnt/media_rw -o -path /data/media -o -path /storage/self -o -path /data_mirror \) -prune -o \
         -type f -size +1M \( -iname '*.zip' -o -iname 'payload*.bin' -o -iname '*update*' -o -iname '*ota*' -o -iname '*fota*' \
                   -o -iname '*.img' -o -iname '*.pkg' -o -iname '*.tgz' -o -iname '*.tar*' -o -iname '*.mbn' \
                   -o -iname '*h37*' -o -iname '*firmware*' -o -iname '*.7z' -o -iname '*.rar' -o -size +30M \) -print 2>/dev/null \
    | grep -vE "$NOT_FW" | grep -viE "$MEDIA_RE" | sort -u >"$L.tmp"
  mv "$L.tmp" "$L"
}

# Archivy 1. fáze v pořadí; každý vynechá obsah těch před ním
P1="carplay etc new voice diff heavy"

# Výjimky pro tar -X: seznamy uvedených archivů → $W/x.lst
excl() {
  : >"$W/x.lst"
  for n in "$@"; do "${n}_list"; cat "$W/$n.lst" >>"$W/x.lst"; done 2>>"$ERR"
}

# tar 1. fáze: seznam <jméno> bez obsahu archivů před ním
tar_p1() {
  name="$1"; before=""
  for n in $P1; do [ "$n" = "$name" ] && break; before="$before $n"; done
  { "${name}_list"; excl $before; } 2>>"$ERR"   # nic kromě tar nesmí jít do proudu
  tar -cf - -X "$W/x.lst" -T "$W/$name.lst" 2>>"$ERR"
}

case "$STAGE" in

# ============================================================ FÁZE 1 =========

report)
  echo "EU výpis HJ VOYAH — přehled, $(date '+%Y-%m-%d %H:%M:%S %z')"
  sec "SESTAVENÍ"
  run 'getprop ro.build.fingerprint; getprop ro.build.display.id; getprop ro.build.version.incremental'
  run 'getprop | grep -iE "ro.product|ro.build|version|hu_|soc|board|platform|region|country|oversea|locale|market|channel|ecu"'
  sec "VŠECHNY VLASTNOSTI (getprop) — ⛔ obsahuje sériová čísla, do gitu nedávat"
  run getprop
  sec "BUILD.PROP oddílů"
  for p in $(parts); do for f in "$p/build.prop" "$p/etc/build.prop" "$p/default.prop"; do
    [ -r "$f" ] && { echo "--- $f"; cat "$f"; }
  done; done 2>&1
  sec "ODDÍLY"
  run 'df -h'; run 'cat /proc/mounts'
  run 'ls -l /dev/block/by-name/ 2>/dev/null || ls -l /dev/block/bootdevice/by-name/'
  sec "BALÍČKY (cesta, verze, uid)"
  run 'pm list packages -a -f -U --show-versioncode'
  run 'pm list packages -a --apex-only --show-versioncode'
  run 'pm list packages -d'
  run 'pm list libraries'; run 'pm list features'
  sec "BALÍČKY, které v čínském sestavení nejsou (obsah new.tar)"
  new_pkgs
  sec "Adresáře aplikací, které se v EU liší (obsah diff.tar, heavy.tar)"
  diff_list; heavy_list; cat "$W/diff.lst" "$W/heavy.lst"
  sec "Připojené APEX"
  apex_dirs
  sec "EXTERNÍ JAR (bootclasspath / systemserverclasspath)"
  echo "BOOTCLASSPATH=$BOOTCLASSPATH"
  echo "SYSTEMSERVERCLASSPATH=$SYSTEMSERVERCLASSPATH"
  echo "DEX2OATBOOTCLASSPATH=$DEX2OATBOOTCLASSPATH"
  ;;

carplay)
  echo "EU výpis HJ VOYAH — CarPlay/projekce, $(date '+%Y-%m-%d %H:%M:%S %z')"
  sec "BALÍČKY podle vzoru"
  pm list packages -a -f -U --show-versioncode 2>&1 | grep -iE "$CP_RE"
  sec "dumpsys package pro nalezené"
  for p in $(pm list packages -a 2>/dev/null | sed 's/^package://' | grep -iE "$CP_RE"); do
    echo "########## $p"; pm path "$p"; dumpsys package "$p"
  done 2>&1
  sec "SOUBORY podle vzoru (oddíly obrazu, /apex, .rc, APK balíčků) — přesně obsah carplay.tar"
  carplay_list
  while read -r f; do ls -ldZ "$f"; done <"$W/carplay.lst" 2>&1
  sec "Kontexty SELinux"
  for p in $(parts); do grep -rhiE 'carplay|iapcomm|iap_device|mfi' "$p/etc/selinux" 2>/dev/null; done | sort -u
  sec "privapp-permissions / default-permissions"
  for p in $(parts); do grep -rliE 'carplay|linkmanager' "$p/etc/permissions" "$p/etc/default-permissions" "$p/etc/sysconfig" 2>/dev/null; done
  sec "VLASTNOSTI"
  getprop | grep -iE 'carplay|iap|ecu.config|androidauto|mfi|link'
  sec "SLUŽBY, PROCESY, UZLY"
  run "service list | grep -iE 'carplay|iap|link|projection'"
  run "ps -AZ | grep -iE 'carplay|iap|linkmanager|mfi'"
  run 'ls -lZ /dev/i2c-* /dev/iap* 2>&1'
  run 'ls -laZ /data/carplay /data/iap /data/vendor/carplay 2>&1'
  run 'ls -lZ /system/bin/*CarPlay* /system/bin/*IAP* /system/bin/*Comm* /vendor/bin/*carplay* /vendor/bin/*iap* 2>&1'
  run "dumpsys activity services | grep -iE -A3 'carplay|linkmanager|iap'"
  run "dumpsys usb"
  sec "logcat (aktuální buffer) — řádky CarPlay/iAP"
  logcat -d -b all 2>/dev/null | grep -iE 'carplay|iap2|iapcomm|linkmanager|MegaLink|mfi' | tail -n 3000
  ;;

voice)
  echo "EU výpis HJ VOYAH — hlasový asistent, $(date '+%Y-%m-%d %H:%M:%S %z')"
  sec "BALÍČKY hlasu podle vzoru"
  pm list packages -a -f -U --show-versioncode 2>&1 | grep -iE "$VOICE_PKG_RE"
  sec "dumpsys package pro nalezené (zkráceno)"
  for p in $(voice_pkgs); do
    echo "########## $p"; pm path "$p"; dumpsys package "$p" | head -n 200
  done 2>&1
  sec "SOUBORY (obsah voice.tar bez toho, co je už v předchozích archivech)"
  voice_list
  while read -r f; do ls -ldZ "$f"; done <"$W/voice.lst" 2>&1
  sec "Strom */third_party (modely, jazyky, hlasy)"
  for p in $(parts); do [ -d "$p/third_party" ] && ls -lR "$p/third_party"; done 2>&1 | head -n 5000
  sec "Verze a konfigurace prostředků (malé textové soubory, prvních 4 KB)"
  for p in $(parts); do
    [ -d "$p/third_party" ] && find "$p/third_party" -type f -size -64k \
      \( -iname 'version*' -o -iname '*.json' -o -iname 'config*' -o -iname '*.txt' -o -iname '*.ini' -o -iname '*.conf' \) 2>/dev/null
  done | head -n 300 | while read -r f; do echo "--- $f"; head -c 4096 "$f"; echo; done
  sec "JAZYK a locale"
  getprop | grep -iE 'locale|lang|voice|tts|asr|speech'
  run 'settings get system system_locales; settings get secure voice_interaction_service; settings get secure voice_recognition_service; settings get secure assistant'
  run 'dumpsys voiceinteraction | head -n 80'
  sec "logcat (aktuální buffer) — řádky hlasu"
  logcat -d -b main,system 2>/dev/null | grep -iE 'voice|asr|tts|wakeup|iflytek|cerence|nuance|speech' | tail -n 2000
  ;;

ota)
  echo "EU výpis HJ VOYAH — hledání souboru firmwaru, $(date '+%Y-%m-%d %H:%M:%S %z')"
  sec "Známá místa OTA"
  for d in /ota /ota/load /ota/package /fota /log/ota /data/ota_package /data/ota /cache /cache/recovery \
           /metadata/ota /sdcard/com.mega.update /sdcard/Download /storage/emulated/0 /mnt/media_rw; do
    echo "--- $d"; ls -laZ "$d" 2>&1
  done
  for s in /storage/*; do echo "--- $s (médium)"; ls -la "$s" "$s/com.mega.update" 2>&1; done
  sec "VLASTNOSTI aktualizací"
  getprop | grep -iE 'ota|update|fota|upgrade|slot|signature|version'
  sec "SLUŽBY aktualizací"
  run "dumpsys package com.mega.update | head -60"
  run "dumpsys activity services com.mega.update"
  run "dumpsys activity services com.android.car.systemupdater"
  # Předpona FW: — podle ní hostitelský skript vypíše kandidáty v závěrečném shrnutí
  sec "KANDIDÁTI na soubor firmwaru (jméno a > 1 MB, nebo > 30 MB bez médií; mimo oddíly obrazu) — obsah ota-candidates.tar"
  ota_list
  while read -r f; do ls -l "$f" | sed 's/^/FW: /'; done <"$W/ota.lst" 2>/dev/null
  ;;

tar-carplay) tar_p1 carplay ;;  # vše k CarPlay: soubory, adresáře-balíčky, .rc, APK balíčků
tar-etc)     tar_p1 etc ;;      # konfigurace oddílů: permissions, init, selinux, vintf, audio, EcuTable.json
tar-new)     tar_p1 new ;;      # balíčky, které v čínském sestavení nejsou
tar-voice)   tar_p1 voice ;;    # hlasový asistent: aplikace, modely ASR/TTS, knihovny
tar-diff)    tar_p1 diff ;;     # aplikace, které se v EU liší v kódu
tar-heavy)   tar_p1 heavy ;;    # velké aplikace, které se liší (mapa, hudba)

tar-ota)     # kandidáti na soubor firmwaru (mimo oddíly obrazu — s ostatními archivy se nepřekrývají)
  ota_list 2>>"$ERR"
  tar -cf - -T "$W/ota.lst" 2>>"$ERR"
  ;;

# ============================================================ FÁZE 2 =========

parts)       # seznam oddílů pro tar-part (hostitel volá po jednom)
  parts
  ;;

tar-apex)    # rozbalené připojené APEX: javalib, etc, manifesty (v oddílech leží jen archivy .apex)
  excl $P1
  for a in $(apex_dirs); do
    for s in javalib etc apex_manifest.pb apex_manifest.json; do [ -e "$a/$s" ] && echo "$a/$s"; done
  done >"$W/apex.lst" 2>>"$ERR"
  tar -cf - -X "$W/x.lst" -T "$W/apex.lst" 2>>"$ERR"
  ;;

tar-dataapps) # APK z /data/app (aktualizace systémových + aplikace třetích stran): adresář zavřený, soubory podle cesty čitelné
  excl $P1
  pkg_apk_paths 2>>"$ERR" | grep '^/data/' | grep -vxF -f "$W/x.lst" >"$W/dataapps.lst"
  tar -cf - -T "$W/dataapps.lst" 2>>"$ERR"
  ;;

tar-part)    # jeden oddíl obrazu celý, kromě toho, co stáhla 1. fáze
  case " $(parts | tr '\n' ' ') " in *" $ARG "*) ;; *) echo "není oddíl obrazu: $ARG" >>"$ERR"; exit 2 ;; esac
  excl $P1
  tar -cf - -X "$W/x.lst" "$ARG" 2>>"$ERR"
  ;;

# ============================================================ služební =======

lists)       # seznamy, podle kterých se skládaly tar (pro kontrolu, že se nic neztratilo)
  for f in "$W"/*.lst; do
    case "$f" in */index.lst|*/x.lst) continue ;; esac
    [ -e "$f" ] && { echo "===== $f"; cat "$f"; }
  done
  ;;
errs)
  for f in "$W"/*.err; do [ -s "$f" ] && { echo "===== $f"; sort -u "$f" | head -n 500; }; done
  ;;
cleanup)
  rm -rf "$W" "$CN_PKGS"
  ;;
*)
  echo "neznámý krok: $STAGE" >&2; exit 2
  ;;
esac
exit 0
