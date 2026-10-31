# install-update-shutdown

Aggiorna automaticamente un sistema Ubuntu o Debian a un orario prestabilito e, a scelta, lo spegne o lo riavvia. Supporta notifiche tramite **ntfy** e **email**, mostra un **QR code** per iscriversi al topic ntfy e può aggiornarsi dal repository GitHub.

> [!NOTE]
> Richiede `bash`, `cron` e `curl`. I comandi sono verificati con le man page ufficiali di `systemd` (`shutdown`) e con la GitHub REST API.

## 📦 Installazione

```bash
sudo curl -fsSL \
  https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/install-update-shutdown.sh \
  -o /usr/local/bin/install-update-shutdown.sh

sudo chmod +x /usr/local/bin/install-update-shutdown.sh
sudo install-update-shutdown.sh install
```

## 🛠️ Comandi

| Comando | Descrizione |
|---|---|
| `install` | Configura e installa runner e cron in modalità interattiva |
| `uninstall` | Rimuove il job cron, il runner e la configurazione |
| `write-uninstaller` | Crea uno script di disinstallazione autonomo |
| `update` | Aggiorna lo script dal repository GitHub |
| `check-update` | Verifica se è disponibile una versione più recente |
| `status` | Mostra lo stato dell’installazione |
| `version` | Mostra la versione installata |
| `help` | Mostra l’aiuto |

### Esempi

```bash
sudo install-update-shutdown.sh install
sudo install-update-shutdown.sh check-update
sudo install-update-shutdown.sh update
sudo install-update-shutdown.sh status
```

## ⚙️ Funzionamento

1. Durante l’installazione, scegli:
   - le notifiche: ntfy pubblico o privato con topic casuale, email o entrambi;
   - l’azione da eseguire dopo l’aggiornamento: nessuna, spegnimento o riavvio;
   - l’orario di esecuzione.
2. Viene creato `/usr/local/bin/update-and-shutdown.sh`, il runner che:
   - esegue `apt update` e `apt upgrade` con `DEBIAN_FRONTEND=noninteractive`;
   - controlla lo stato dei pacchetti con `dpkg --audit`;
   - esegue l’azione scelta **solo se l’aggiornamento è riuscito**;
   - invia una notifica con l’esito.
3. Viene installato un job cron all’orario scelto, che per impostazione predefinita è `02:00`.
4. Se hai scelto ntfy, viene mostrato un **QR code** per iscriversi al topic, insieme all’indirizzo in formato leggibile.

## 📁 File creati

| Percorso | Ruolo |
|---|---|
| `/usr/local/bin/install-update-shutdown.sh` | Script principale |
| `/usr/local/bin/update-and-shutdown.sh` | Runner eseguito da cron |
| `/etc/update-shutdown.conf` | File di configurazione, con permessi `600` |
| `/usr/local/bin/uninstall-update-shutdown.sh` | Disinstaller autonomo, se generato |

## 🔄 Aggiornamento dello script

La versione è dichiarata nella variabile `SCRIPT_VERSION`, all’inizio dello script.

Il comando `check-update` scarica la versione presente nel branch GitHub e la confronta con quella installata usando il formato semver `MAJOR.MINOR.PATCH`. Il comando `update` scarica e sostituisce lo script in `/usr/local/bin` solo se la versione remota è più recente.

## 🗑️ Disinstallazione

```bash
sudo install-update-shutdown.sh uninstall
```

In alternativa, se hai generato il disinstaller autonomo:

```bash
sudo uninstall-update-shutdown.sh
```

## 🔒 Note di sicurezza

- Il topic ntfy è casuale: per leggere o pubblicare notifiche è necessario conoscerlo. Se esegui di nuovo `install`, viene generato un nuovo topic: iscriviti nuovamente usando il QR code.
- Il runner usa percorsi assoluti e un `PATH` esplicito, così da funzionare correttamente nell’ambiente ridotto di cron.
