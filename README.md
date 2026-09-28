# dtadmin-vault-backup

Sicherungs-Container für die DTAdmin-Vorlage **„Passwort-Tresor (Vaultwarden)“**.
Er läuft als zweiter Container im Pod und sieht dasselbe Volume `/data` wie Vaultwarden.

## Was er tut

- **Beim Start:** spielt `/data/restore.tar.gz` ein, falls vorhanden. Danach sichert er den Tresor
  und setzt die Marke `/data/backups/.start-<pod>`. Vaultwarden startet erst nach dieser Marke.
  So entsteht vor jedem Update eine Sicherung.
- **Täglich 03:15 (Europe/Berlin):** eine Sicherung. Sonntags zählt sie als wöchentliche.
- **Auf Wunsch:** Die Datei `/data/backups/JETZT` löst innerhalb einer Minute eine Sicherung aus.

Jede Sicherung:

1. prüft den freien Platz (das Doppelte der Nutzdaten muss frei sein);
2. kopiert die Datenbank konsistent mit `sqlite3 .backup`;
3. prüft die Kopie mit `PRAGMA integrity_check`;
4. packt Datenbank, `attachments/` und `sends/` als `tar.gz`;
5. verschlüsselt das Archiv mit [age](https://age-encryption.org), wenn `BACKUP_AGE_RECIPIENT` gesetzt ist.
   Nur dann kommen `rsa_key*` und `config.json` mit ins Archiv.

Aufbewahrung unter `/data/backups/`: 14 tägliche, 8 wöchentliche, 5 Start-Sicherungen, 5 manuelle.

## Umgebung

| Variable | Bedeutung |
|---|---|
| `BACKUP_AGE_RECIPIENT` | öffentlicher age-Schlüssel (`age1…`); leer = unverschlüsselt ohne Schlüsseldateien |
| `TZ` | Zeitzone für die Uhrzeit der Sicherung, Standard `Europe/Berlin` |
| `DATA_DIR` | Datenverzeichnis, Standard `/data` |

## Wiederherstellen

1. Das Archiv entschlüsseln, falls nötig: `age -d -i schluessel.txt tresor-daily-….tar.gz.age > restore.tar.gz`.
2. `restore.tar.gz` nach `/data/restore.tar.gz` legen (in DTAdmin über den Volume-Browser).
3. Den Stack neu starten. Der alte Stand liegt danach in `/data/backups/vor-wiederherstellung-<zeit>/`.

Ein Archiv mit absoluten Pfaden, `..` oder ohne `db.sqlite3` lehnt der Container ab und ändert nichts.

## Prüfen

```sh
docker build -t dtadmin-vault-backup:test .
sh test/test.sh dtadmin-vault-backup:test
```

Der Test startet kurz einen echten Vaultwarden, um Daten zu erzeugen.

## Versionen

Jede Version erscheint als `ghcr.io/deltatree/dtadmin-vault-backup:<version>` über einen Git-Tag `v<version>`.
Ein Tag wird nie neu vergeben.
