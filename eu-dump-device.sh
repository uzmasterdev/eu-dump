#!/system/bin/sh
#
# Část eu-dump.sh / eu-dump.bat — běží NA HLAVNÍ JEDNOTCE (toybox sh, uid shell).
# Hostitelský skript ho nahraje do /data/local/tmp a volá po krocích:
#   sh eu-dump-device.sh <krok> [oddíl]
# Textové kroky píší zprávu na stdout, tar-kroky tar-proud na stdout
# (hostitel ho přijímá přes `adb exec-out`, protože `adb pull` z části oddílů
# nefunguje — SELinux nepustí sync-službu adbd, kdežto shell číst může).
# Chyby (Permission denied apod.) jdou do $W/<krok>.err: exec-out slévá stderr
# do stejného proudu, proto se v tar-krocích vše navíc odvádí do souboru nebo /dev/null.
#
# Dvě fáze výpisu bez překryvu:
#   1 (rychlá)  report carplay ota → tar-carplay tar-etc tar-ota
#   2 (úplná)   tar-apex tar-dataapps tar-part <oddíl>… — všechno ostatní; co stáhla
#               1. fáze, se vynechá podle týchž seznamů (p1.lst → tar -X)
#
# Pouze čtení: na jednotce se nic nemění kromě pracovní složky /data/local/tmp/eudump.
#
W=/data/local/tmp/eudump
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

# ---- seznamy se sestaví jednou za sezení a kroky je sdílejí (nový .lst vzniká jen přes mv, celý)

# Vše k CarPlay/projekci: soubory podle vzoru na oddílech a v APEX, .rc, APK balíčků, /data/carplay
cp_list() {
  L="$W/carplay.lst"; [ -e "$L" ] && return
  {
    for p in $(parts) $(apex_dirs); do find "$p" 2>/dev/null | grep -iE "$CP_RE"; done
    for p in $(parts); do grep -rliE 'carplay|iapcomm|linkmanager' "$p/etc/init" 2>/dev/null; done
    for p in $(pm list packages -a 2>/dev/null | sed 's/^package://' | grep -iE "$CP_RE"); do
      pm path "$p" 2>/dev/null | sed 's/^package://'
    done
    for d in /data/carplay /data/iap /data/vendor/carplay; do [ -r "$d" ] && echo "$d"; done
  } | sort -u >"$L.tmp"
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

# Co už stáhla 1. fáze — výjimky pro 2. fázi (tar -X, adresář se vynechá i s obsahem)
p1_list() {
  cp_list; etc_list
  cat "$W/carplay.lst" "$W/etc.lst" >"$W/p1.lst"
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
  cp_list
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

tar-carplay) # vše k CarPlay: soubory, jejich adresáře-balíčky, .rc, APK balíčků
  cp_list
  tar -cf - -T "$W/carplay.lst" 2>>"$ERR"
  ;;

tar-etc)     # konfigurace oddílů: permissions, init, selinux, vintf, audio, EcuTable.json apod.
  etc_list
  tar -cf - -T "$W/etc.lst" 2>>"$ERR"
  ;;

tar-ota)     # kandidáti na soubor firmwaru
  ota_list
  tar -cf - -T "$W/ota.lst" 2>>"$ERR"
  ;;

# ============================================================ FÁZE 2 =========

parts)       # seznam oddílů pro tar-part (hostitel volá po jednom)
  parts
  ;;

tar-apex)    # rozbalené připojené APEX: javalib, etc, manifesty (v oddílech leží jen archivy .apex)
  p1_list
  for a in $(apex_dirs); do
    for s in javalib etc apex_manifest.pb apex_manifest.json; do [ -e "$a/$s" ] && echo "$a/$s"; done
  done >"$W/apex.lst"
  tar -cf - -X "$W/p1.lst" -T "$W/apex.lst" 2>>"$ERR"
  ;;

tar-dataapps) # APK z /data/app (aktualizace systémových + aplikace třetích stran): adresář zavřený, soubory podle cesty čitelné
  cp_list
  pkg_apk_paths | grep '^/data/' | grep -vxF -f "$W/carplay.lst" >"$W/dataapps.lst"
  tar -cf - -T "$W/dataapps.lst" 2>>"$ERR"
  ;;

tar-part)    # jeden oddíl obrazu celý, kromě toho, co stáhla 1. fáze
  case " $(parts | tr '\n' ' ') " in *" $ARG "*) ;; *) echo "není oddíl obrazu: $ARG" >>"$ERR"; exit 2 ;; esac
  p1_list
  tar -cf - -X "$W/p1.lst" "$ARG" 2>>"$ERR"
  ;;

# ============================================================ služební =======

lists)       # seznamy, podle kterých se skládaly tar (pro kontrolu, že se nic neztratilo)
  for f in "$W"/*.lst; do [ -e "$f" ] && { echo "===== $f"; cat "$f"; }; done
  ;;
errs)
  for f in "$W"/*.err; do [ -s "$f" ] && { echo "===== $f"; sort -u "$f" | head -n 500; }; done
  ;;
cleanup)
  rm -rf "$W"
  ;;
*)
  echo "neznámý krok: $STAGE" >&2; exit 2
  ;;
esac
exit 0
