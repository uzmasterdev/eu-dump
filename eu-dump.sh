#!/usr/bin/env bash
#
# Stažení artefaktů z hlavní jednotky (HJ) dárcovského vozu s EU firmwarem (VOYAH Courage H37Z) přes ADB.
# Dvě fáze bez překryvu:
#   fáze 1 (rychlá, výchozí): přehledy (sestavení, balíčky, CarPlay, hlas, hledání firmwaru) + carplay.tar, etc.tar,
#          new.tar (balíčky, které v čínském sestavení nejsou), voice.tar (hlasový asistent), ota-candidates.tar,
#          diff.tar a heavy.tar (aplikace, které se v EU liší v kódu, včetně všech H37Z_*),
#          eufiles.tar (soubory, které v čínském obrazu nejsou: knihovny, programy, konfigurace);
#   fáze 2 (--full): vše ostatní — celé oddíly obrazu (part-*.tar), rozbalené APEX, /data/app;
#          co stáhla 1. fáze, se neopakuje.
# Návod — README.md vedle.
#
# Pouze čtení: na HJ vzniká a na konci se maže jen /data/local/tmp/eudump.
# Soubory se stahují přes `adb exec-out tar` (adb pull z části oddílů nefunguje).
#
# Použití: ./eu-dump.sh [--full | --all] [výstupní_složka]
#   (bez přepínače)  fáze 1 → nová složka eu-<datum>/
#   --full           fáze 2 → do poslední složky eu-*/ (nebo do zadané)
#   --all            obě fáze za sebou
# Opakované spuštění se stejnou složkou navazuje: celé stažené archivy se znovu nestahují.
#
# ⛔ Výstup obsahuje sériová čísla, VIN a identifikátory CIZÍHO vozu. Složky eu-*/ jsou mimo git (.gitignore).
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE=1
case "${1:-}" in
  --full) MODE=2; shift ;;
  --all)  MODE=all; shift ;;
esac
OUT="${1:-}"
if [ -z "$OUT" ] && [ "$MODE" = 2 ]; then
  OUT="$(ls -d "$DIR"/eu-*/ 2>/dev/null | sort | tail -n 1)"
  [ -n "$OUT" ] || { echo "✖ chybí složka eu-*/ z 1. fáze. Zadej složku: $0 --full <složka>"; exit 1; }
fi
[ -n "$OUT" ] || OUT="$DIR/eu-$(date +%Y%m%d-%H%M%S)"
DEV=/data/local/tmp/eu-dump-device.sh
CN=/data/local/tmp/eu-cn-packages.txt   # seznam balíčků čínského sestavení — pro new.tar
CNF=/data/local/tmp/eu-cn-files.txt     # seznam souborů čínského obrazu — pro eufiles.tar

# adb: proměnná ADB → platform-tools/ vedle skriptu → PATH
pick_adb() {
  [ -n "${ADB:-}" ] && { echo "$ADB"; return; }
  [ -x "$DIR/platform-tools/adb" ] && { echo "$DIR/platform-tools/adb"; return; }
  command -v adb >/dev/null 2>&1 && { echo adb; return; }
  echo ""
}
ADB="$(pick_adb)"
[ -n "$ADB" ] || { echo "✖ adb nenalezen (proměnná ADB, platform-tools/ vedle skriptu nebo adb v PATH)."; exit 1; }

echo "⏳ Čekám na HJ (potvrď ladění na displeji vozu)…"
"$ADB" wait-for-device
state="$("$ADB" get-state 2>/dev/null || true)"
[ "$state" = "device" ] || { echo "✖ HJ není připravena (stav: ${state:-žádný})."; exit 1; }

mkdir -p "$OUT" || exit 1
OUT="$(cd "$OUT" && pwd)"
LOG="$OUT/eu-dump.log"
DONE="$OUT/.done"   # archivy stažené celé při živém spojení (pro navázání)
echo "✔ HJ připojena. Výstup: $OUT"
echo "EU výpis $(date '+%Y-%m-%d %H:%M:%S'), fáze: $MODE, adb: $ADB" >>"$LOG"   # >> — při navázání se log doplňuje

# Úklid na HJ při jakémkoli ukončení, i při Ctrl+C (při vytrženém kabelu se neprovede — viz README)
cleanup() { "$ADB" shell "rm -rf /data/local/tmp/eudump $DEV $CN $CNF" >/dev/null 2>&1; }
trap cleanup EXIT
trap 'exit 130' INT TERM

"$ADB" push "$DIR/eu-dump-device.sh" "$DEV" >/dev/null || { echo "✖ skript se nepodařilo nahrát na HJ"; exit 1; }
"$ADB" push "$DIR/cn-packages.txt" "$CN" >/dev/null || { echo "✖ seznam čínských balíčků se nepodařilo nahrát na HJ"; exit 1; }
"$ADB" push "$DIR/cn-files.txt" "$CNF" >/dev/null || { echo "✖ seznam souborů čínského obrazu se nepodařilo nahrát na HJ"; exit 1; }
# CRLF po úpravě na Windows rozbije sh na HJ
"$ADB" shell "sed -i 's/\r\$//' $DEV $CN $CNF"

fails=0

text() {  # krok → textový soubor
  local stage="$1" file="$2"
  printf '▶ %-13s → %s\n' "$stage" "$file" | tee -a "$LOG"
  "$ADB" shell sh "$DEV" "$stage" >"$OUT/$file" 2>&1
}

tar_entries() {  # počet položek v celém tar; prázdný/poškozený (i useknutý) → chyba
  local n
  n="$(tar -tf "$1" 2>/dev/null | wc -l | tr -d ' ')" && [ "$n" -gt 0 ] && echo "$n"
}

# krok → tar, kontrola celistvosti, velikost. 3. argument opt = prázdný je v pořádku, 4. — oddíl pro tar-part
tarstage() {
  local stage="$1" file="$2" opt="${3:-}" arg="${4:-}"
  printf '▶ %-13s → %s … ' "$stage" "$file" | tee -a "$LOG"
  if grep -qxF "$file" "$DONE" 2>/dev/null; then
    echo "už staženo, přeskakuji" | tee -a "$LOG"
    return
  fi
  local t0=$SECONDS n
  "$ADB" exec-out sh "$DEV" "$stage" $arg >"$OUT/$file"
  if [ "$("$ADB" get-state 2>/dev/null)" != device ]; then
    echo "✖ spojení s HJ ztraceno" | tee -a "$LOG"
    echo
    echo "Připoj HJ a spusť znovu se stejnou složkou — stažené archivy se znovu nestahují:"
    echo "  $0 $( [ "$MODE" = 2 ] && echo '--full ')$( [ "$MODE" = all ] && echo '--all ')\"$OUT\""
    exit 2
  fi
  if n="$(tar_entries "$OUT/$file")"; then
    printf '%s položek, %s, %ss\n' "$n" "$(du -h "$OUT/$file" | cut -f1)" "$((SECONDS - t0))" | tee -a "$LOG"
    echo "$file" >>"$DONE"
  elif [ "$opt" = opt ] && [ "$(wc -c <"$OUT/$file")" -le 10240 ]; then  # prázdný tar = 0…10 KB nul
    echo "— prázdné" | tee -a "$LOG"
    echo "$file" >>"$DONE"
  else
    echo "✖ prázdný nebo poškozený tar" | tee -a "$LOG"
    fails=$((fails + 1))
  fi
}

sums() {
  if command -v shasum >/dev/null 2>&1; then (cd "$OUT" && shasum -a 256 ./*.tar >SHA256SUMS)
  elif command -v sha256sum >/dev/null 2>&1; then (cd "$OUT" && sha256sum ./*.tar >SHA256SUMS); fi
}

stage1() {
  echo "── Fáze 1: CarPlay, konfigurace, EU-only balíčky, hlas, firmware, aplikace lišící se od CN ──" | tee -a "$LOG"
  # Nejdřív text — rychlé a nejcennější, kdyby se spojení přerušilo; archivy v pořadí hodnoty
  text report   report.txt
  text carplay  carplay.txt
  text voice    voice.txt
  text ota      ota-search.txt
  tarstage tar-carplay carplay.tar opt
  tarstage tar-etc     etc.tar
  tarstage tar-new     new.tar opt
  tarstage tar-voice   voice.tar opt
  tarstage tar-ota     ota-candidates.tar opt
  tarstage tar-diff    diff.tar opt
  tarstage tar-eufiles eufiles.tar opt
  tarstage tar-heavy   heavy.tar opt
  text lists tar-lists-1.txt
  text errs  device-errors-1.txt
}

stage2() {
  echo "── Fáze 2: celé oddíly obrazu (bez toho, co stáhla fáze 1), APEX, /data/app ──" | tee -a "$LOG"
  tarstage tar-apex     apex.tar
  tarstage tar-dataapps data-apps.tar opt
  local p
  for p in $("$ADB" shell sh "$DEV" parts | tr -d '\r'); do
    tarstage tar-part "part-${p#/}.tar" "" "$p"
  done
  text lists tar-lists-2.txt
  text errs  device-errors-2.txt
}

case "$MODE" in
  1)   stage1 ;;
  2)   stage2 ;;
  all) stage1; stage2 ;;
esac
cleanup
sums

if [ "$MODE" != 2 ]; then
  echo
  echo "Kandidáti na soubor firmwaru:"
  grep '^FW: ' "$OUT/ota-search.txt" | sed 's/^FW: /  /' || echo "  — nenalezeno"
  echo
  echo "Balíčky CarPlay/projekce:"
  sed -n '/BALÍČKY podle vzoru/,/=====/p' "$OUT/carplay.txt" | grep '^package:' | sed 's/^/  /' || echo "  — nenalezeno"
fi
echo
if [ "$fails" -gt 0 ]; then
  echo "⚠ kroků s prázdným/poškozeným tar: $fails (podrobnosti — $LOG, device-errors-*.txt)"
  exit 1
fi
echo "✔ Hotovo: $OUT"
[ "$MODE" = 1 ] && echo "Dál, pokud je čas, — fáze 2 (celé oddíly): $0 --full \"$OUT\""
exit 0
