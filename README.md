# install-update-shutdown

Aggiorna automaticamente il sistema (Ubuntu/Debian) a un intervallo scelto e,
a scelta, lo spegne o lo riavvia **solo se l'aggiornamento e' riuscito**.
Notifiche **ntfy** e **email** con **dedup** (solo a stato cambiato), QR code per il topic e **auto-update** dal repository GitHub.

> Richiede: `bash`, `cron`, `curl`. Comandi verificati sulle man page
> ufficiali di systemd (`shutdown`) e sulla GitHub REST API.

## 📦 Installazione (via curl)

    curl -fsSL \
      https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/install-update-shutdown.sh \
      -o /usr/local/bin/install-update-shutdown.sh
    sudo chmod +x /usr/local/bin/install-update-shutdown.sh
    sudo install-update-shutdown.sh install

## 🛠️ Comandi

| Comando | Descrizione |
|---|---|
| `install` | Configura e installa (interattivo) |
| `settings` | Modifica la configurazione dopo l'installazione |
| `uninstall` | Rimuove cron, script, config e stato |
| `update` | Aggiorna lo script dal repository GitHub |
| `check-update` | Verifica se esiste una versione piu' recente |
| `status` | Mostra lo stato dell'installazione |
| `version` | Mostra la versione installata |
| `help` | Mostra l'aiuto |

## Architettura (script separati)

Il job cron esegue un wrapper che separa le due fasi:

    update-then-power.sh  =  update-check.sh && power-action.sh

- **`update-check.sh`**: controlla la disponibilita aggiornamenti a ogni run,
  esegue `apt update` + `apt upgrade`, verifica `dpkg --audit`, e notifica
  l'esito (successo o errore con exit code + ultime righe di output).
  Esce **0** solo se tutto e' andato bene.
- **`power-action.sh`**: esegue l'azione (spegnimento/riavvio) **solo se**
  l'aggiornamento e' uscito senza errori (grazie a `&&`).
- Se l'aggiornamento fallisce, il `&&` blocca l'azione: il server **non** si
  spegne ne' riavvia.

## Intervallo di controllo

Durante l'installazione viene chiesto **ogni quanti minuti** verificare gli
aggiornamenti (es. 60 = ogni ora, 240 = ogni 4 ore, 1440 = ogni giorno).
L'orario di esecuzione (HH:MM) determina il primo scatto del cron.

- **Dedup**: per impostazione predefinita una notifica viene inviata solo se
  lo **stato e cambiato** rispetto all'ultima (es. da "nessun aggiornamento" a
  "aggiornamenti disponibili"). Lo stato e salvato in `/var/lib/update-shutdown/state`.
- **Priorita ridotta**: default `Priority: 3` (normale), configurabile 1-5.
- **Errori**: se `apt update`/`apt upgrade` falliscono o `dpkg --audit` segnala
  pacchetti inconsistenti, la notifica include exit code e ultime righe di output.
  
## 📁 File creati

| Percorso | Ruolo |
|---|---|
| `/usr/local/bin/install-update-shutdown.sh` | Script principale (CLI) |
| `/usr/local/bin/update-check.sh` | Controlla + aggiorna + notifica |
| `/usr/local/bin/power-action.sh` | Spegnimento/riavvio |
| `/usr/local/bin/update-then-power.sh` | Wrapper: power solo se update riuscito |
| `/etc/update-shutdown.conf` | Configurazione (`chmod 600`) |
| `/var/lib/update-shutdown/state` | Stato per il dedup delle notifiche |

## 🔄 Auto-update

La versione e in `SCRIPT_VERSION`. `check-update` confronta la versione locale
con quella del file raw sul branch (semver `MAJOR.MINOR.PATCH`); `update`
scarica e sostituisce lo script solo se la remota e piu' alta.

## 🗑️ Disinstallazione

    sudo install-update-shutdown.sh uninstall
    # oppure lo script autonomo:
    sudo uninstall-update-shutdown.sh
    
### ⚠️⚠️ Attenzione a questi file "vecchi" (v1.x), orfani nella v2

Se sei passato da 1.x a 2.x, questi possono essere rimasti e non vengono rimossi dal nuovo uninstall:

    ls -l /usr/local/bin/update-and-shutdown.sh 2>/dev/null   # runner vecchio v1.x
    ls -l /usr/local/bin/uninstall-update-shutdown.sh 2>/dev/null  # disinstaller vecchio

Se esistono, eliminali a mano:

    sudo rm -f /usr/local/bin/update-and-shutdown.sh
    sudo rm -f /usr/local/bin/uninstall-update-shutdown.sh


## Note di sicurezza

- Il topic ntfy e casuale: nessuno puo' pubblicare/leggere senza conoscerlo.
  Rilanciando `install` viene generato un nuovo topic: iscriviti di nuovo col QR.
- Lo spegnimento (`shutdown -h now`) NON riaccende il server: servono WoL o
  riaccensione programmata BIOS/UEFI.
- Gli script runtime usano `PATH` esplicito e percorsi assoluti per funzionare
  nell'ambiente minimo di cron.

## Versioni

- **2.0.0** — Separazione update / azione (power solo se update riuscito),
  intervallo di controllo configurabile, dedup notifiche, priorita ridotta,
  comando `settings`, un solo `uninstall` completo. Fix `unbound variable`
  inizializzando le variabili opzionali.
- **1.1.0** — Reporting errori nel runner.
- **1.0.0** — Prima versione con CLI e auto-update.
