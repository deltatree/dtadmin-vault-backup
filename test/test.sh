#!/bin/sh
# Prüft das Image mit echten Vaultwarden-Daten. Aufruf: sh test/test.sh <image> <verzeichnis-mit-vaultwarden-daten>
set -u
img="$1"; quelle="${2:-}"
if [ -z "$quelle" ]; then # Daten von einem echten Vaultwarden erzeugen lassen
  quelle=$(mktemp -d); docker run -d --name vb-vw -v "$quelle:/data" "${VAULTWARDEN_IMAGE:-vaultwarden/server:1.37.3-alpine}" >/dev/null
  i=0; until [ -f "$quelle/db.sqlite3" ] && [ -f "$quelle/rsa_key.pem" ] || [ $i -gt 60 ]; do sleep 1; i=$((i+1)); done; sleep 2; docker rm -f vb-vw >/dev/null
fi
fehler=0
ok() { echo "OK   $*"; }
nein() { echo "FEHL $*"; fehler=$((fehler + 1)); }
arbeit=$(mktemp -d); trap 'docker run --rm -v "$arbeit:/w" --entrypoint sh "$img" -c "rm -rf /w/*" >/dev/null 2>&1; rm -rf "$arbeit"' EXIT
# Unter Linux gehören Dateien aus dem Container root; aufräumen deshalb im Container.
weg() { docker run --rm -v "$arbeit:/w" --entrypoint sh "$img" -c "rm -rf /w/$1"; }
neu() { weg data; mkdir -p "$arbeit/data"; cp -a "$quelle"/. "$arbeit/data/"; weg data/backups
  docker run --rm -v "$arbeit/data:/data" --entrypoint sh "$img" -c "sqlite3 /data/db.sqlite3 'CREATE TABLE IF NOT EXISTS probe(x); DELETE FROM probe; INSERT INTO probe VALUES (1),(2),(3);'" >/dev/null; }
lauf() { docker run --rm -e HOSTNAME=testpod -v "$arbeit/data:/data" --entrypoint sh "$img" -c "$1" 2>&1; }

neu
out=$(lauf "tresor-backup manual")
echo "$out" | grep -q "OK (manual).*integrity_check=ok" && ok "Sicherung mit integrity_check" || nein "Sicherung: $out"
arch=$(ls "$arbeit"/data/backups/tresor-manual-*.tar.gz 2>/dev/null | head -1)
[ -n "$arch" ] && tar -tzf "$arch" | grep -q "^./db.sqlite3$" && ok "Archiv enthält db.sqlite3" || nein "Archiv ohne db.sqlite3"
tar -tzf "$arch" | grep -q "rsa_key" && nein "ohne age darf rsa_key nicht ins Archiv" || ok "ohne age kein rsa_key im Archiv"
echo "$out" | grep -q "HINWEIS: ohne BACKUP_AGE_RECIPIENT" && ok "Hinweis ohne age im Log" || nein "Hinweis fehlt"

neu
schl=$(lauf "age-keygen 2>/dev/null")
pub=$(echo "$schl" | sed -n 's/^# public key: //p'); echo "$schl" | grep '^AGE-SECRET-KEY' > "$arbeit/id.txt"
out=$(docker run --rm -e BACKUP_AGE_RECIPIENT="$pub" -v "$arbeit/data:/data" --entrypoint tresor-backup "$img" daily 2>&1)
echo "$out" | grep -q "OK (\(daily\|weekly\)).*\.age" && ok "age-verschlüsselt" || nein "age: $out"
enc=$(ls "$arbeit"/data/backups/tresor-*.tar.gz.age | head -1)
docker run --rm -v "$arbeit:/w" --entrypoint sh "$img" -c "age -d -i /w/id.txt /w/data/backups/$(basename "$enc") | tar -tzf -" > "$arbeit/liste" 2>&1
grep -q "rsa_key.pem" "$arbeit/liste" && grep -q "db.sqlite3" "$arbeit/liste" && ok "age-Archiv entschlüsselbar, mit rsa_key" || nein "age-Archiv: $(head -3 "$arbeit/liste")"

neu; mkdir -p "$arbeit/data/backups"
i=1; while [ $i -le 16 ]; do touch -t 2026090$(( i % 9 + 1 ))0000 "$arbeit/data/backups/tresor-daily-2026-alt$i.tar.gz"; i=$((i+1)); done
lauf "sed -i 's/date +%u/echo 1/' /usr/local/bin/tresor-backup; tresor-backup daily" > /dev/null
n=$(ls "$arbeit"/data/backups/tresor-daily-* | wc -l | tr -d ' ')
[ "$n" = 14 ] && ok "Aufbewahrung 14 tägliche" || nein "Aufbewahrung: $n statt 14"

neu
lauf "tresor-backup manual" > /dev/null
cp "$(ls "$arbeit"/data/backups/tresor-manual-*.tar.gz | head -1)" "$arbeit/data/restore.tar.gz"
lauf "sqlite3 /data/db.sqlite3 'DELETE FROM probe;'" > /dev/null
vorher=$(lauf "sqlite3 /data/db.sqlite3 'SELECT count(*) FROM probe;'")
out=$(lauf "tresor-restore")
nachher=$(lauf "sqlite3 /data/db.sqlite3 'SELECT count(*) FROM probe;'")
[ "$vorher" = 0 ] && [ "$nachher" = 3 ] && ok "Wiederherstellung: $vorher -> $nachher Zeilen" || nein "Wiederherstellung: $vorher -> $nachher ($out)"
ls -d "$arbeit"/data/backups/vor-wiederherstellung-* >/dev/null 2>&1 && ok "alter Stand aufbewahrt" || nein "alter Stand fehlt"

neu
# Ein Archiv mit gültiger Datenbank UND einem Pfad mit ..: nur die Pfadprüfung darf es ablehnen.
python3 - "$arbeit/data" <<'PY2'
import sys, tarfile, io
d = sys.argv[1]
with tarfile.open(d + "/restore.tar.gz", "w:gz") as t:
    t.add(d + "/db.sqlite3", arcname="db.sqlite3")
    daten = b"x"
    info = tarfile.TarInfo("../boese"); info.size = len(daten)
    t.addfile(info, io.BytesIO(daten))
PY2
out=$(lauf "tresor-restore")
echo "$out" | grep -q "absolute Pfade oder \.\." && ok "Archiv mit .. abgelehnt (Pfadprüfung)" || nein "Archiv mit ..: $out"
neu
echo "age-encryption.org/v1 kein tar" > "$arbeit/data/restore.tar.gz"
out=$(lauf "tresor-restore")
echo "$out" | grep -q "ABGEBROCHEN" && [ -f "$arbeit/data/db.sqlite3" ] && ok "verschlüsseltes Archiv abgelehnt, Datenbank bleibt" || nein "age-Archiv als restore: $out"

neu
docker run -d --name vb-starttest -e HOSTNAME=testpod -v "$arbeit/data:/data" "$img" >/dev/null; sleep 6; docker rm -f vb-starttest >/dev/null
[ -f "$arbeit/data/backups/.start-testpod" ] && grep -q "^ok " "$arbeit/data/backups/.start-testpod" && ok "Start-Sicherung und Marke" || nein "Start-Marke fehlt"
ls "$arbeit"/data/backups/tresor-start-* >/dev/null 2>&1 && ok "Start-Sicherung liegt vor" || nein "keine Start-Sicherung"

weg data; mkdir -p "$arbeit/data"
out=$(lauf "tresor-start & sleep 3; cat /data/backups/.start-testpod")
echo "$out" | grep -q "^ok " && ok "erster Start ohne Datenbank setzt Marke" || nein "erster Start: $out"

neu
out=$(docker run --rm --tmpfs /data:size=2m -v "$arbeit/data:/q:ro" --entrypoint sh "$img" -c "head -c 400000 /q/db.sqlite3 > /dev/null; cp /q/db.sqlite3 /data/; dd if=/dev/zero of=/data/fuell bs=1k count=\$(( \$(df -Pk /data | awk 'NR==2{print \$4}') - 50 )) 2>/dev/null; tresor-backup manual; echo rc=\$?" 2>&1)
echo "$out" | grep -q "ÜBERSPRUNGEN" && echo "$out" | grep -q "rc=3" && ok "Platzmangel erkannt" || nein "Platzmangel: $(echo "$out" | tail -2)"

echo "Fehler: $fehler"
exit "$fehler"
