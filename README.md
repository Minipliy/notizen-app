# Notizen – deine Notizen auf deinem eigenen Server

> **Hinweis: Dieses Projekt wurde mit KI erstellt.**
> Der gesamte Code, die Skripte und diese Anleitungen wurden von einer KI
> (Claude von Anthropic) geschrieben – das ist **nicht meine eigene Programmierarbeit**.
> Ich habe die KI angeleitet und die App ausprobiert. Benutze sie gern, aber rechne
> damit, dass Fehler drin sein können (siehe [Lizenz](LICENSE): ohne Gewähr).

## Für wen ist das?

Für alle, die ihre Notizen **nicht in einer fremden Cloud** (iCloud, Google, Microsoft …)
speichern wollen. Bei dieser App liegen deine Notizen auf **deinem eigenen kleinen
Server** – zum Beispiel einem Raspberry Pi bei dir zu Hause. Niemand außer dir hat
Zugriff darauf: kein Konto, keine Werbung, kein Tracking.

Die App sieht anders aus als Apple Notizen, kann aber vieles davon – auf **iPhone,
iPad und Mac**, und alle Geräte bleiben automatisch auf demselben Stand.

## Was die App kann

- **Mit dem Apple Pencil schreiben** – direkt auf der Notiz, mit Stiften, Farben,
  Textmarker, Radierer und Lineal. Blanko, liniertes oder kariertes Papier.
- **Text tippen** mit Formatierleiste: Überschriften, Listen, **Checklisten**, fett, kursiv,
  **Tabellen** und **mathematische Formeln** (LaTeX, z. B. `$x^2$`).
- **Fotos, gescannte Dokumente und PDFs** einfügen und darauf schreiben; PDFs mit deinen
  Anmerkungen wieder als PDF teilen.
- **Sprachnotizen** aufnehmen, mit automatischem Text (Transkript).
- **Handschrift wird erkannt** – die Suche findet auch handgeschriebene Wörter.
- **Rechnen** wie in einem Taschenrechner: `Miete + Strom =` zeigt das Ergebnis.
- **Notizen sperren** mit Passwort / Face ID – der Inhalt wird verschlüsselt, sogar dein
  eigener Server sieht nur den Titel.
- Ordner, `#Tags`, Links zwischen Notizen (`[[Titel]]`), Anpinnen, Suche,
  „Zuletzt gelöscht“, Notiz als PDF drucken.
- Funktioniert auch **ohne Internet**; Änderungen werden nachgereicht.

## So funktioniert es (in einem Satz)

Auf einem kleinen Computer bei dir zu Hause läuft ein Programm („Server“), das deine
Notizen speichert – und die App auf iPhone, iPad und Mac redet mit diesem Programm.

```
 iPhone ─┐
 iPad  ──┼──►  dein Raspberry Pi (speichert alles)
 Mac   ──┘
```

## Loslegen

👉 **[Schritt-für-Schritt-Anleitung (ohne Vorkenntnisse)](ANLEITUNG.md)**

Du brauchst einen Mac (zum Installieren der App), ein iPhone und/oder iPad, eine
(kostenlose) Apple-ID und einen Raspberry Pi oder einen anderen Computer, der dauerhaft
läuft. Rechne für die Einrichtung mit etwa 1–2 Stunden.

## Inhalt dieses Repositorys

| Ordner | Was ist drin? |
| --- | --- |
| `app/` | Die App für iPhone, iPad und Mac (Xcode-Projekt, Swift/SwiftUI) |
| `server/` | Der Server: ein einzelnes Python-Programm ohne Zusatzpakete, plus Installationsskript |
| `docs/screenshots/` | Bildschirmfotos (älterer Stand der App) |

## Technisches (für Interessierte)

- **Server:** `server/notizen_server.py` – Python 3, speichert Notizen in SQLite und Anhänge
  als Dateien. Zugriff nur mit Token. Abgleich über eine einfache HTTP-Schnittstelle mit Long-Polling.
- **App:** SwiftUI, PencilKit, Vision (Texterkennung), Speech (Transkript),
  [SwiftMath](https://github.com/mgriebling/SwiftMath) (Formeln, MIT-Lizenz).
- **Gesperrte Notizen:** AES-GCM, Schlüssel per PBKDF2-SHA256 (200 000 Runden) aus dem
  Passwort. Angehängte Dateien (Fotos, PDFs, Audio) sind dabei **nicht** verschlüsselt.
- **Konflikte:** Wird dieselbe Notiz gleichzeitig auf zwei Geräten geändert, gewinnt die neuere
  Fassung; die andere bleibt als „Konfliktkopie“ erhalten.
- **Erreichbarkeit von unterwegs:** am einfachsten mit [Tailscale](https://tailscale.com)
  (siehe Anleitung) oder mit eigener Domain und `server/vps-setup.sh` (für Fortgeschrittene).

## Lizenz

[MIT](LICENSE) – du darfst alles damit machen, auch verändern und weitergeben. Ohne Gewähr.
