# Anleitung: Notizen selbst einrichten – ganz ohne Vorkenntnisse

> Diese Anleitung (wie das ganze Projekt) wurde mit KI erstellt. Wenn etwas nicht klappt
> oder ein Schritt bei dir anders aussieht, schau unten bei [„Wenn etwas nicht klappt“](#wenn-etwas-nicht-klappt)
> oder eröffne auf GitHub ein „Issue“.

Am Ende dieser Anleitung hast du:

- einen kleinen **Server** bei dir zu Hause, der deine Notizen speichert,
- die **App** auf deinem iPhone, iPad und/oder Mac,
- und alle Geräte bleiben automatisch auf demselben Stand.

Plane **1–2 Stunden** ein. Du musst nichts programmieren – nur abtippen und klicken.

---

## Inhalt

1. [Was du brauchst](#1-was-du-brauchst)
2. [Ein paar Begriffe kurz erklärt](#2-ein-paar-begriffe-kurz-erklärt)
3. [Teil A – Den Server einrichten (Raspberry Pi)](#teil-a--den-server-einrichten-raspberry-pi)
4. [Teil B – Die App auf iPhone, iPad und Mac bringen](#teil-b--die-app-auf-iphone-ipad-und-mac-bringen)
5. [Teil C – App und Server verbinden](#teil-c--app-und-server-verbinden)
6. [Teil D – Auch unterwegs synchronisieren (optional)](#teil-d--auch-unterwegs-synchronisieren-optional)
7. [Sicherungskopie machen](#sicherungskopie-machen)
8. [Updates einspielen](#updates-einspielen)
9. [Wenn etwas nicht klappt](#wenn-etwas-nicht-klappt)
10. [Was ist wie privat?](#was-ist-wie-privat)

---

## 1. Was du brauchst

| Was | Wofür | Hinweis |
| --- | --- | --- |
| **Ein Mac** (macOS 15 oder neuer) | Um die App auf deine Geräte zu bringen | Wird nur zum Installieren gebraucht – und falls du die App auch auf dem Mac willst |
| **iPhone und/oder iPad** (iOS/iPadOS 18 oder neuer) | Darauf läuft die App | Plus passendes **Kabel** zum Mac |
| **Eine Apple-ID** | Damit Apple dir erlaubt, eigene Apps zu installieren | Die normale, kostenlose reicht |
| **Ein Raspberry Pi** (Modell 4 oder 5) mit Netzteil und **microSD-Karte** (ab 16 GB) | Das ist dein Server – er speichert die Notizen | Kostet ca. 60–100 €. Alternativ geht jeder Computer, der immer an ist (siehe Kasten unten) |
| **WLAN oder Netzwerkkabel** | Damit Pi, Mac und iPhone sich finden | Alle Geräte müssen im selben Heimnetz sein |

> **Kein Raspberry Pi? Erst mal nur ausprobieren?**
> Du kannst den Server auch auf deinem Mac laufen lassen (siehe [Teil A, Variante B](#variante-b-nur-ausprobieren-server-auf-dem-mac)).
> Dann funktioniert der Abgleich aber nur, solange der Mac eingeschaltet ist.

---

## 2. Ein paar Begriffe kurz erklärt

- **Server:** ein Computer, der für andere Geräte etwas erledigt. Hier: Er speichert deine Notizen,
  und iPhone, iPad und Mac holen sie sich von dort.
- **Raspberry Pi:** ein kleiner, günstiger Computer in Scheckkartengröße. Er braucht kaum Strom
  und kann deshalb immer eingeschaltet bleiben.
- **Terminal:** ein Programm auf dem Mac, in das man Befehle eintippt statt zu klicken.
  Du findest es mit **⌘ + Leertaste**, dann „Terminal“ tippen und Enter drücken.
  Einen Befehl führst du aus, indem du ihn hineinkopierst und **Enter** drückst.
- **SSH:** damit steuerst du den Raspberry Pi vom Terminal deines Macs aus – so, als würdest du
  direkt davor sitzen.
- **Token:** ein langes, zufälliges Passwort, das der Server selbst erzeugt. Nur Geräte, die es
  kennen, dürfen deine Notizen lesen.
- **Xcode:** das kostenlose Programm von Apple, mit dem man Apps baut und auf Geräte überträgt.

---

## Teil A – Den Server einrichten (Raspberry Pi)

### A1. Betriebssystem auf die Speicherkarte spielen

1. Lade auf deinem Mac den **Raspberry Pi Imager** herunter: <https://www.raspberrypi.com/software/>
   und installiere ihn (Datei öffnen, in „Programme“ ziehen).
2. Stecke die microSD-Karte in deinen Mac (ggf. mit Adapter).
3. Öffne den Raspberry Pi Imager und wähle:
   - **Gerät:** dein Raspberry-Pi-Modell
   - **Betriebssystem:** „Raspberry Pi OS (other)“ → **„Raspberry Pi OS Lite (64-bit)“**
     (die Version ohne Bildschirm-Oberfläche reicht völlig)
   - **Speicher:** deine microSD-Karte
4. Wenn der Imager fragt, ob du **Einstellungen anpassen** möchtest, sag **Ja / „Einstellungen bearbeiten“** und trage ein:
   - **Hostname:** `notizen` (so heißt der Pi später im Netzwerk)
   - **Benutzername und Passwort:** frei wählbar, z. B. Benutzer `pi` – **merk dir beides!**
   - **WLAN:** Name und Passwort deines WLANs (nicht nötig, wenn du ein Netzwerkkabel nutzt)
   - **Zeitzone / Tastatur:** Europe/Berlin, de
   - Reiter **„Dienste“:** **SSH aktivieren** → „Passwort zur Authentifizierung verwenden“
5. Auf **Schreiben** klicken und warten, bis es fertig ist. Das kann einige Minuten dauern.
6. Karte in den Raspberry Pi stecken, Netzteil anschließen. Der Pi braucht beim ersten Start
   **2–5 Minuten**.

### A2. Vom Mac aus mit dem Pi verbinden

1. Öffne das **Terminal** auf deinem Mac (⌘ + Leertaste → „Terminal“).
2. Tippe Folgendes ein (ersetze `pi` durch deinen Benutzernamen, falls du einen anderen gewählt hast)
   und drücke Enter:

   ```bash
   ssh pi@notizen.local
   ```

3. Beim ersten Mal kommt eine Frage „Are you sure you want to continue connecting?“ – tippe
   `yes` und Enter.
4. Gib dein Pi-Passwort ein. **Beim Tippen erscheinen keine Zeichen** – das ist normal. Einfach
   tippen und Enter drücken.
5. Wenn vorne jetzt etwas wie `pi@notizen:~ $` steht, bist du auf dem Pi. 🎉

### A3. Den Notizen-Server installieren

Kopiere diese Befehle **einzeln** ins Terminal und drücke jeweils Enter:

```bash
sudo apt update && sudo apt install -y git python3
```

```bash
git clone https://github.com/Minipliy/notizen-app.git
```

```bash
sudo bash notizen-app/server/install.sh
```

Am Ende steht so etwas da:

```
Der Notizen-Server läuft.
Server-Adresse für die App:  http://192.168.178.42:8787
Token für die App:           Xy3k...langes-Zeichengewirr...
```

**Schreib dir beides auf** (oder lass das Terminal offen). Das brauchst du gleich in der App.

Der Server startet ab jetzt **automatisch**, wenn der Pi eingeschaltet wird. Deine Notizen liegen
auf dem Pi im Ordner `/var/lib/notizen`.

> Token vergessen? Auf dem Pi anzeigen mit: `sudo cat /var/lib/notizen/token.txt`

Du kannst das Terminal jetzt mit `exit` verlassen.

### Variante B: Nur ausprobieren (Server auf dem Mac)

1. Lade das Projekt herunter: Auf <https://github.com/Minipliy/notizen-app> oben auf den grünen
   Knopf **„Code“** → **„Download ZIP“** klicken. Die ZIP-Datei im Ordner „Downloads“ doppelklicken.
2. Im Terminal:

   ```bash
   cd ~/Downloads/notizen-app-main/server
   ```

   ```bash
   python3 notizen_server.py
   ```

   (Falls der Mac fragt, ob er Entwicklerwerkzeuge installieren soll: **Installieren** und den
   Befehl danach nochmal ausführen.)
3. Das Terminal zeigt den **Token**. Die Server-Adresse ist `http://DEIN-MAC-NAME.local:8787` –
   deinen Mac-Namen findest du unter **Systemeinstellungen → Allgemein → Info → Name**
   (Leerzeichen durch `-` ersetzen).
4. Solange das Terminal-Fenster offen ist, läuft der Server.

---

## Teil B – Die App auf iPhone, iPad und Mac bringen

Die App ist (noch) nicht im App Store. Du installierst sie mit Xcode selbst – das ist
kostenlos und erlaubt.

### B1. Xcode installieren

1. Öffne den **App Store** auf dem Mac, suche nach **Xcode** und installiere es.
   ⚠️ Xcode ist sehr groß (über 10 GB) – das kann eine Weile dauern.
2. Öffne Xcode einmal. Es fragt eventuell nach zusätzlichen Komponenten
   (z. B. „iOS“) – bestätigen und installieren lassen.

### B2. Das Projekt herunterladen und öffnen

1. Falls noch nicht geschehen: Auf <https://github.com/Minipliy/notizen-app> auf
   **„Code“ → „Download ZIP“** klicken und die ZIP-Datei doppelklicken.
2. Öffne den entpackten Ordner, dann den Ordner **`app`**, und doppelklicke auf
   **`Notizen.xcodeproj`**. Xcode öffnet sich.
3. Xcode lädt beim ersten Öffnen automatisch eine kleine Zusatzbibliothek (für Formeln) aus dem
   Internet. Warte, bis oben in der Mitte nichts mehr von „Resolving packages“ steht.

### B3. Deine Apple-ID eintragen und die App „unterschreiben“

Apple verlangt, dass jede App einer Person zugeordnet ist. Das machst du so:

1. In Xcode oben im Menü: **Xcode → Einstellungen (Settings) → Accounts**.
   Unten links auf **„+“** → **„Apple ID“** → mit deiner Apple-ID anmelden. Fenster schließen.
2. Klicke links in der Seitenleiste ganz oben auf das **blaue Symbol „Notizen“**.
3. In der Mitte unter **TARGETS** auf **„Notizen“** klicken, dann oben den Reiter
   **„Signing & Capabilities“** wählen.
4. Haken bei **„Automatically manage signing“** setzen (falls nicht schon gesetzt).
5. Bei **Team** deinen Namen auswählen (z. B. „Max Mustermann (Personal Team)“).
6. Bei **Bundle Identifier** steht `com.example.notizen`. Ändere das in etwas Eigenes, das sonst
   niemand benutzt, z. B. **`de.maxmustermann.notizen`** (nur Kleinbuchstaben, Punkte, keine Umlaute).
7. Wenn danach keine rote Fehlermeldung mehr zu sehen ist, ist alles richtig.

### B4. App auf das iPhone oder iPad übertragen

1. Verbinde das iPhone/iPad **per Kabel** mit dem Mac und entsperre es.
   Wenn gefragt wird „Diesem Computer vertrauen?“ → **Vertrauen** und Code eingeben.
2. **Entwicklermodus einschalten** (nur beim ersten Mal):
   Auf dem iPhone/iPad **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** (ganz unten)
   → einschalten → Gerät startet neu → danach „Einschalten“ bestätigen.
   *Taucht „Entwicklermodus“ nicht auf? Dann einmal Schritt 3 versuchen – danach erscheint er.*
3. In Xcode oben in der Mitte auf die Geräteauswahl klicken (dort steht z. B. „iPhone 17“) und
   **dein echtes Gerät** auswählen.
4. Oben links auf den **▶-Knopf** (Play) klicken. Xcode baut die App – beim ersten Mal dauert das
   ein paar Minuten.
5. Erscheint auf dem iPhone „Nicht vertrauenswürdiger Entwickler“:
   **Einstellungen → Allgemein → VPN & Geräteverwaltung** → deine Apple-ID antippen →
   **Vertrauen**. Dann die App „Notizen“ öffnen.

Für weitere Geräte (z. B. iPad) einfach Schritt 1–5 wiederholen.

> **Wichtig bei kostenloser Apple-ID:** Apple lässt selbst installierte Apps nur **7 Tage**
> laufen. Danach öffnet sich die App nicht mehr – deine Notizen sind aber **nicht weg**
> (sie liegen ja auf deinem Server). Einfach das Gerät wieder anschließen und in Xcode auf ▶
> drücken. Mit dem kostenpflichtigen Apple-Entwicklerprogramm (99 €/Jahr) hält sie ein Jahr.

### B5. App auf dem Mac

1. In Xcode oben bei der Geräteauswahl **„My Mac“** wählen und auf **▶** klicken. Die App startet.
2. Damit du sie auch ohne Xcode öffnen kannst: Menü **Product → Archive**. Im Fenster, das danach
   aufgeht, auf **„Distribute App“** → **„Custom“** → **„Copy App“** → Speicherort wählen.
   Die fertige **Notizen.app** in den Ordner **Programme** ziehen.

---

## Teil C – App und Server verbinden

Mach das auf **jedem** Gerät einmal:

1. Öffne die App **Notizen**.
2. Tippe links oben auf das **Zahnrad** (⚙︎).
3. Trage ein:
   - **Adresse:** `http://notizen.local:8787`
     (oder die Adresse, die das Installationsskript angezeigt hat, z. B. `http://192.168.178.42:8787`)
   - **Token:** das lange Zeichengewirr aus Teil A3
4. Tippe auf **„Verbindung testen“**. Erscheint „Verbindung steht“, auf **„Sichern“** tippen.
5. Unten links steht jetzt **„Synchronisiert“**. Fertig! 🎉

Lege zum Test auf dem iPhone eine Notiz an – nach ein, zwei Sekunden erscheint sie auch auf
den anderen Geräten.

> Beim ersten Verbinden fragt iOS, ob die App „Geräte im lokalen Netzwerk finden“ darf –
> bitte **Erlauben**, sonst findet die App deinen Pi nicht.

---

## Teil D – Auch unterwegs synchronisieren (optional)

Bis jetzt funktioniert der Abgleich nur **zu Hause im WLAN**. Unterwegs speichert die App alles
auf dem Gerät und gleicht ab, sobald du wieder zu Hause bist.

Wenn du auch unterwegs synchronisieren willst, ist **Tailscale** der einfachste und sichere Weg.
Tailscale verbindet deine Geräte über eine verschlüsselte Verbindung – so, als wären sie im selben
WLAN. Für private Nutzung ist es kostenlos. (Tailscale ist eine Firma; deine Notizen gehen dabei
aber verschlüsselt direkt zwischen deinen Geräten hin und her.)

1. Erstelle ein Konto auf <https://tailscale.com> (z. B. mit deiner Apple-ID anmelden).
2. Verbinde dich wie in Teil A2 mit dem Pi (`ssh pi@notizen.local`) und gib ein:

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   ```

   ```bash
   sudo tailscale up
   ```

   Es erscheint ein Link – öffne ihn im Browser und melde dich an. Damit ist der Pi in deinem
   Tailscale-Netz.
3. Jetzt bekommt der Server eine sichere https-Adresse:

   ```bash
   sudo tailscale serve --bg 8787
   ```

   Die Ausgabe zeigt eine Adresse wie `https://notizen.tail1234.ts.net`. Falls stattdessen ein
   Link zum Freischalten von HTTPS erscheint: öffnen, bestätigen, Befehl nochmal ausführen.
4. Installiere die App **Tailscale** aus dem App Store auf iPhone, iPad und Mac und melde dich
   mit **demselben Konto** an.
5. Ändere in der Notizen-App (Zahnrad) die Adresse auf die **https-Adresse** aus Schritt 3.
   Der Token bleibt gleich. Diese Adresse funktioniert dann **zu Hause und unterwegs**,
   solange Tailscale auf dem Gerät eingeschaltet ist.

> ❌ **Bitte nicht** den Port 8787 in deinem Router „freigeben“ / „weiterleiten“. Dann wäre dein
> Server ungeschützt aus dem ganzen Internet erreichbar, und die Verbindung wäre unverschlüsselt.

*Für Fortgeschrittene mit eigenem gemieteten Server und eigener Domain gibt es `server/vps-setup.sh`
(Anleitung oben in der Datei).*

---

## Sicherungskopie machen

Deine Notizen liegen nur auf dem Pi (und als Kopie auf deinen Geräten). Mach ab und zu eine
Sicherung, z. B. einmal im Monat.

1. Mit dem Pi verbinden (`ssh pi@notizen.local`) und eingeben:

   ```bash
   sudo tar czf ~/notizen-backup.tar.gz -C /var/lib notizen && sudo chown $USER ~/notizen-backup.tar.gz
   ```

2. `exit` eingeben, dann **auf dem Mac** im Terminal:

   ```bash
   scp pi@notizen.local:notizen-backup.tar.gz ~/Desktop/
   ```

Die Datei `notizen-backup.tar.gz` liegt jetzt auf deinem Schreibtisch. Bewahre sie an einem sicheren
Ort auf (z. B. USB-Stick).

---

## Updates einspielen

**Server** (auf dem Pi, nach `ssh pi@notizen.local`):

```bash
cd ~/notizen-app && git pull && sudo bash server/install.sh
```

**App:** Neue ZIP von GitHub herunterladen, `app/Notizen.xcodeproj` öffnen, Team und
Bundle Identifier wieder wie in [B3](#b3-deine-apple-id-eintragen-und-die-app-unterschreiben)
eintragen (**denselben** Bundle Identifier wie vorher!) und auf ▶ drücken. Deine Notizen
bleiben erhalten.

> Tipp für Fortgeschrittene: Lege neben `app/Signing.xcconfig` eine Datei `Signing.local.xcconfig`
> mit `DEVELOPMENT_TEAM = …` und `PRODUCT_BUNDLE_IDENTIFIER = …` an – dann musst du nach Updates
> nichts mehr in Xcode eintragen.

---

## Wenn etwas nicht klappt

| Problem | Lösung |
| --- | --- |
| `ssh: Could not resolve hostname notizen.local` | Pi noch nicht fertig gestartet (5 Min. warten) oder nicht im selben WLAN. Alternativ die IP-Adresse des Pi nehmen – sie steht in deinem Router (z. B. FritzBox: fritz.box → Heimnetz). |
| Beim Passwort erscheinen keine Zeichen | Normal – einfach tippen und Enter. |
| App: „Server nicht erreichbar“ | Ist der Pi an? Bist du im selben WLAN (oder Tailscale an)? Adresse genau so wie oben eingetragen, mit `http://` und `:8787`? Lokales Netzwerk erlaubt (iPhone: Einstellungen → Notizen → Lokales Netzwerk)? |
| App: „Token falsch“ | Token nochmal anzeigen (`sudo cat /var/lib/notizen/token.txt`) und genau abschreiben bzw. kopieren. |
| App: „Unterwegs nur mit https:// möglich“ | Außerhalb des Heimnetzes erlaubt iOS nur verschlüsselte Adressen – nutze Tailscale (Teil D). |
| App: „Server veraltet – bitte aktualisieren“ | Server-Update einspielen (siehe [Updates](#updates-einspielen)). |
| Xcode: rote Fehler bei „Signing“ | Team ausgewählt? Bundle Identifier geändert (darf nicht `com.example.notizen` bleiben)? |
| Xcode: „Developer Mode disabled“ | Entwicklermodus auf dem iPhone einschalten (siehe B4, Schritt 2). |
| Die App öffnet sich nach einer Woche nicht mehr | Normal bei kostenloser Apple-ID – Gerät anschließen, in Xcode ▶ drücken. |
| Ich habe das Passwort einer gesperrten Notiz vergessen | Leider nicht wiederherstellbar – das ist der Sinn der Verschlüsselung. |

---

## Was ist wie privat?

- **Deine Notizen** liegen auf deinem Pi und als Kopie auf deinen Geräten. Keine Firma bekommt sie.
- **Im Heimnetz** läuft die Verbindung über `http://` – also **unverschlüsselt**, aber nur innerhalb
  deines eigenen WLANs.
- **Mit Tailscale** ist die Verbindung verschlüsselt (https), auch unterwegs.
- **Gesperrte Notizen** werden zusätzlich auf dem Gerät verschlüsselt. Selbst wer an deinen Pi
  kommt, sieht nur den Titel. Angehängte Fotos, PDFs und Audiodateien sind dabei allerdings
  **nicht** verschlüsselt.
- **Texterkennung** (Handschrift, Fotos) läuft komplett auf deinem Gerät.
- **Sprachnotizen** werden von Apples Spracherkennung in Text umgewandelt – wenn möglich auf dem
  Gerät, sonst kann Apple die Aufnahme dafür verarbeiten (iOS fragt vorher um Erlaubnis).
