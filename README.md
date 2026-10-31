# install-update-shutdown

Aggiorna automaticamente il sistema (Ubuntu/Debian) a un orario fisso e,
a scelta, lo spegne o lo riavvia. Supporta notifiche **ntfy** e **email**,
con **QR code** per l'iscrizione al topic e **auto-update** dallo stesso
repository GitHub.

> Richiede: `bash`, `cron`, `curl`. Comandi verificati sulle man page
> ufficiali di systemd (`shutdown`) e sulla GitHub REST API.

## Installazione (via curl)

    curl -fsSL \
      https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/install-update-shutdown.sh \
      -o /usr/local/bin/install-update-shutdown.sh
    sudo chmod +x /usr/local/bin/install-update-shutdown.sh
    sudo install-update-shutdown.sh install

## Comandi

| Comando | Descrizione |
|---|---|
| `install` | Configura e installa runner + cron (interattivo) |
| `uninstall` | Rimuove job cron, runner e config |
| `write-uninstaller` | Crea lo script di disinstallazione autonomo |
| `update` | Aggiorna lo script dal repository GitHub |
| `check-update` | Verifica se esiste una versione piu' recente |
| `status` | Mostra lo stato dell'installazione |
| `version` | Mostra la versione installata |
| `help` | Mostra l'aiuto |

Esempi:

    sudo install-update-shutdown.sh install
    sudo install-update-shutdown.sh check-update
    sudo install-update-shutdown.sh update
    sudo install-update-shutdown.sh status

## Cosa fa

1. Richiede: notifiche (ntfy default/privato con topic random, e/o email),
   azione post-aggiornamento (nessuna / spegnimento / riavvio) e orario.
2. Genera `/usr/local/bin/update-and-shutdown.sh` (runner) che:
   - esegue `apt update` + `apt upgrade` con `DEBIAN_FRONTEND=noninteractive`
   - verifica lo stato dei pacchetti con `dpkg --audit`
   - **solo se tutto e' andato a buon fine** esegue l'azione scelta
   - invia una notifica di esito
3. Installa un job cron nell'orario scelto (default 02:00).
4. Mostra un **QR code** con il topic ntfy (e l'indirizzo leggibile).

## File creati

| Percorso | Ruolo |
|---|---|
| `/usr/local/bin/install-update-shutdown.sh` | Lo script principale |
| `/usr/local/bin/update-and-shutdown.sh` | Runner eseguito dal cron |
| `/etc/update-shutdown.conf` | Configurazione (`chmod 600`) |
| `/usr/local/bin/uninstall-update-shutdown.sh` | Disinstaller (se generato) |

## Auto-update

La versione e' dichiarata nella variabile `SCRIPT_VERSION` in testa allo
script. `check-update` scarica il file raw dal branch e confronta le
versioni (semver `MAJOR.MINOR.PATCH`). `update` scarica e sostituisce
lo script in `/usr/local/bin` solo se la versione remota e' piu' alta.

## Disinstallazione

    sudo install-update-shutdown.sh uninstall
    # oppure, se hai generato il disinstaller autonomo:
    sudo uninstall-update-shutdown.sh

## Note di sicurezza

- Il topic ntfy e' casuale: nessuno puo' pubblicare/leggere senza
  conoscerlo. Rilanciando `install` viene generato un nuovo topic:
  iscriviti di nuovo con il QR.
- Il runner usa percorsi assoluti e `PATH` esplicito per funzionare
  correttamente nell'ambiente minimo di cron.
