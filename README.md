# KOReader SDR Backup

[![Release](https://img.shields.io/github/v/release/komadorirobin/koreader-sdr-backup.koplugin)](https://github.com/komadorirobin/koreader-sdr-backup.koplugin/releases/latest)

Det här paketet säkerhetskopierar KOReaders lässtatus trådlöst till datorn och kan återställa den på samma eller en helt ny Android-enhet.

Backupen innehåller:

- alla `.sdr`-mappar på intern lagring och anslutna minneskort;
- varje mapps lagringsrot och exakta relativa sökväg;
- relevanta Lua-inställningar i `koreader/settings` (bland annat samlingar och pluginstatus);
- statistik-, ordförråds- och relevanta plugin-databaser, men inte stora återskapningsbara bokcachefiler;
- `history.lua`, andra globala historikfiler och `settings.reader.lua`;
- ett manifest och SHA-256-kontrollsummor på datorn.

Ett nytt minneskort får normalt ett nytt Android-UUID. Manifestet använder därför en logisk lagringsrot plus relativ sökväg. Vid återställning mappas intern lagring automatiskt. Om backupen innehåller ett minneskort ska exakt ett flyttbart kort vara anslutet.

## Installera

1. Aktivera ADB och anslut läsaren.
2. Kör `./install_to_reader.sh` i Terminal. Vid flera ADB-enheter: `ADB_SERIAL=IP:PORT ./install_to_reader.sh`.
3. Starta om KOReader. Menyn **SDR Backup** visas i huvudmenyn.

Det går också att kopiera mappen `sdrbackup.koplugin` manuellt till `koreader/plugins/` och sedan fylla i datoradress och token via **SDR Backup > Konfigurera dator**.

Den senaste installationsfilen finns på [GitHub Releases](https://github.com/komadorirobin/koreader-sdr-backup.koplugin/releases/latest).

## Starta mottagaren på Macen

Dubbelklicka på `start_server.command`. Första gången skapas en lång slumpmässig token i `~/.koreader-sdr-backup-server.json`. Fönstret visar datoradressen, token och backupmappen. Standardplatsen är `~/KOReader SDR Backups`.

Läsaren och datorn måste vara på samma lokala nätverk och macOS kan fråga om Python får ta emot inkommande anslutningar.

## Backup

Öppna **SDR Backup > Skapa komplett backup**. En avbruten överföring kan fortsättas via **Fortsätt avbruten backup**; filer som redan kommit fram med rätt storlek skickas inte igen. En backup visas som återställningsbar först efter att datorn verifierat alla filer och skapat kontrollsummor.

## Återställning

Starta mottagaren och välj **SDR Backup > Återställ från backup**. Befintliga filer med samma sökväg ersätts.

`.sdr`-mappar återställs direkt. KOReaders öppna globala historik- och databasfiler aktiveras i två säkra starter:

1. Efter nedladdningen stänger pluginet KOReader.
2. Öppna KOReader; pluginet installerar stagedata och stänger automatiskt.
3. Öppna KOReader igen. Då är den återställda historiken och statistiken aktiv.

Behåll alltid datorbackupen tills du har öppnat flera böcker och verifierat läsposition, status, anteckningar och statistik.

## OTA-uppdateringar

Välj **SDR Backup > Sök efter pluginuppdateringar**. Pluginet hämtar metadata från den senaste GitHub-releasen och laddar därefter ner de tre små pluginfilerna direkt från den taggade källkoden. Varje fil verifieras mot `files.sha256` och installeras atomiskt, utan release-redirect eller beroende av `unzip`. KOReader erbjuder sedan omstart.

Framtida releaser publiceras med `./scripts/publish_release.sh vX.Y.Z`. Skriptet kontrollerar att versionsnumren stämmer, kör testerna, bygger ZIP och checksumma, skapar Git-taggen och publicerar båda releasefilerna.
