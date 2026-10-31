#!/usr/bin/env bash
# install-update-shutdown.sh
# Aggiornamento automatico del sistema con notifica (ntfy/email) e azione
# opzionale (spegnimento/riavvio). Gestito da CLI, installabile via curl.
#
# Installazione:
#   curl -fsSL https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/install-update-shutdown.sh \
#     -o /usr/local/bin/install-update-shutdown.sh && sudo chmod +x /usr/local/bin/install-update-shutdown.sh
#   sudo install-update-shutdown.sh install
#
# Uso:
#   install-update-shutdown.sh install | uninstall | update | check-update | status | version | help

set -euo pipefail

# --- METADATI (aggiorna SCRIPT_VERSION a ogni rilascio) ---
SCRIPT_NAME="install-update-shutdown.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_REPO_OWNER="xunil89"
SCRIPT_REPO_NAME="server-ubuntu-script"
SCRIPT_BRANCH="install-update-shutdown"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/${SCRIPT_BRANCH}/${SCRIPT_NAME}"

# --- PERCORSI ---
BIN_DIR="/usr/local/bin"
SELF_PATH="${BIN_DIR}/${SCRIPT_NAME}"
RUNNER_SCRIPT="/usr/local/bin/update-and-shutdown.sh"
CONFIG_FILE="/etc/update-shutdown.conf"
UNINSTALLER="/usr/local/bin/uninstall-update-shutdown.sh"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Questo comando richiede privilegi di root (sudo)." >&2
        exit 1
    fi
}

# --- Confronto versioni (semver semplice MAJOR.MINOR.PATCH) ---
# Ritorna 0 se $1 > $2, altrimenti 1.
version_gt() {
    local v1="$1" v2="$2"
    local IFS=.
    local -a a=($v1) b=($v2)
    local i
    for i in 0 1 2; do
        local n1="${a[$i]:-0}" n2="${b[$i]:-0}"
        if (( n1 > n2 )); then return 0; fi
        if (( n1 < n2 )); then return 1; fi
    done
    return 1
}

# --- Comandi di auto-update ---
check_update() {
    local remote
    remote=$(curl -fsSL --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' | head -n1)
    if [[ -z "$remote" ]]; then
        echo "ERRORE: impossibile leggere la versione remota dal repository." >&2
        return 1
    fi
    echo "Versione locale:  ${SCRIPT_VERSION}"
    echo "Versione remota:  ${remote}"
    if version_gt "$remote" "$SCRIPT_VERSION"; then
        echo "Aggiornamento disponibile."
        return 2
    else
        echo "Sei aggiornato all'ultima versione."
        return 0
    fi
}

do_update() {
    require_root
    if [[ ! -w "$SELF_PATH" ]]; then
        echo "ERRORE: lo script non e' installato in ${SELF_PATH}." >&2
        echo "Reinstalla con: curl -fsSL ${SCRIPT_RAW_URL} -o ${SELF_PATH} && sudo chmod +x ${SELF_PATH}" >&2
        exit 1
    fi
    local remote
    remote=$(curl -fsSL --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' | head -n1)
    if [[ -z "$remote" ]]; then
        echo "ERRORE: impossibile scaricare la versione remota." >&2
        exit 1
    fi
    if ! version_gt "$$remote" "$$SCRIPT_VERSION"; then
        echo "Sei gia' aggiornato (v${SCRIPT_VERSION})."
        exit 0
    fi
    echo "Aggiorno v$${SCRIPT_VERSION} -> v$${remote}..."
    local tmp
    tmp=$(mktemp)
    if ! curl -fsSL --max-time 30 "$$SCRIPT_RAW_URL" -o "$$tmp"; then
        echo "ERRORE: download fallito." >&2
        rm -f "$tmp"; exit 1
    fi
    if ! head -n1 "$tmp" | grep -q '^#!'; then
        echo "ERRORE: file scaricato non valido." >&2
        rm -f "$tmp"; exit 1
    fi
    mv "$$tmp" "$$SELF_PATH"
    chmod 755 "$SELF_PATH"
    echo "Aggiornato a v${remote}. Rilancia il comando se necessario."
}

# --- Script runner generato (esegue update + azione) ---
write_runner() {
    cat > "$RUNNER_SCRIPT" << 'RUNNER'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/update-shutdown.conf
HOSTNAME=$(hostname)

notify() {
    local subject="\$1"; local body="\$2"
    if [[ "$USE_NTFY" == true ]]; then
        local headers=(-H "Title: ${subject}" -H "Priority: high")
        [[ -n "$$NTFY_TAGS" ]] && headers+=(-H "Tags: $${NTFY_TAGS}")
        curl -s -o /dev/null -X POST "$${headers[@]}" -d "$$body" "${NTFY_TOPIC}"
    fi
    if [[ "$USE_EMAIL" == true ]]; then
        printf '%s\n' "$$body" | mail -s "$${subject} - $${HOSTNAME}" "$${EMAIL}"
    fi
}

apt update -y
apt upgrade -y

if dpkg --audit | grep -q .; then
    notify "Aggiornamento fallito" "Pacchetti in stato inconsistente su ${HOSTNAME}. Intervento manuale richiesto."
    exit 1
fi

case "$ACTION" in
    shutdown)
        notify "Aggiornamento completato" "Sistema ${HOSTNAME} aggiornato. Spegnimento in corso."
        /usr/sbin/shutdown -h now ;;
    reboot)
        notify "Aggiornamento completato" "Sistema ${HOSTNAME} aggiornato. Riavvio in corso."
        /usr/sbin/shutdown -r now ;;
    *)
        notify "Aggiornamento completato" "Sistema ${HOSTNAME} aggiornato correttamente." ;;
esac
RUNNER
    chmod 700 "$RUNNER_SCRIPT"
}

# --- Installazione ---
do_install() {
    require_root

    if ! command -v crontab >/dev/null 2>&1; then
        echo "ERRORE: 'crontab' non trovato. sudo apt install -y cron && sudo systemctl enable --now cron" >&2
        exit 1
    fi
    if ! systemctl is-active --quiet cron; then
        systemctl enable --now cron || { echo "ERRORE: impossibile avviare cron." >&2; exit 1; }
    fi

    generate_topic() {
        local rand
        if command -v openssl >/dev/null 2>&1; then
            rand=$(openssl rand -hex 8)
        else
            rand=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)
        fi
        echo "srv-${rand}"
    }

    echo "Configurazione notifiche:"
    echo ""
    read -rp "Attivare notifiche ntfy? [S/n]: " USE_NTFY
    if [[ "$$USE_NTFY" =~ ^[nN]$$ ]]; then
        USE_NTFY=false
    else
        USE_NTFY=true
        echo ""
        echo "Quale server ntfy usare?"
        echo "  1) Server di default (https://ntfy.sh)"
        echo "  2) Server privato"
        read -rp "Scelta [1/2] (default 1): " NTFY_SERVER_CHOICE
        NTFY_SERVER_CHOICE=${NTFY_SERVER_CHOICE:-1}
        if [[ "$NTFY_SERVER_CHOICE" == "2" ]]; then
            read -rp "URL server ntfy (es. https://ntfy.miodominio.com): " NTFY_BASE_URL
            NTFY_BASE_URL="${NTFY_BASE_URL%/}"
        else
            NTFY_BASE_URL="https://ntfy.sh"
        fi
        NTFY_TOPIC="$${NTFY_BASE_URL}/$$(generate_topic)"
        echo "  -> ntfy configurato: ${NTFY_TOPIC}"
    fi

    echo ""
    read -rp "Attivare notifiche email? [s/N]: " USE_EMAIL
    if [[ "$$USE_EMAIL" =~ ^[sS]$$ ]]; then
        USE_EMAIL=true
        read -rp "Indirizzo email di destinazione: " EMAIL
    else
        USE_EMAIL=false
    fi

    echo ""
    echo "Azione dopo l'aggiornamento:"
    echo "  1) Nessuna azione (solo aggiorna)"
    echo "  2) Spegnere il server"
    echo "  3) Riavviare il server"
    read -rp "Scelta [1/2/3] (default 1): " ACTION_CHOICE
    ACTION_CHOICE=${ACTION_CHOICE:-1}
    case "$ACTION_CHOICE" in
        2) ACTION="shutdown"; ACTION_LABEL="Spegnimento" ;;
        3) ACTION="reboot";   ACTION_LABEL="Riavvio" ;;
        *) ACTION="none";     ACTION_LABEL="Nessuna" ;;
    esac

    read -rp "Ora di esecuzione (HH:MM) [02:00]: " RUN_TIME
    RUN_TIME=${RUN_TIME:-02:00}
    local CRON_HOUR CRON_MIN
    CRON_HOUR=$$(echo "$$RUN_TIME" | cut -d: -f1 | sed 's/^0//')
    CRON_MIN=$$(echo "$$RUN_TIME" | cut -d: -f2 | sed 's/^0//')
    CRON_MIN=${CRON_MIN:-0}

    echo ""
    echo "=========================================="
    echo "  Riepilogo:"
    echo "    ntfy:        ${USE_NTFY}"
    echo "    email:       ${USE_EMAIL}"
    echo "    azione:      ${ACTION_LABEL}"
    echo "    orario:      ${RUN_TIME}"
    echo "=========================================="
    read -rp "Confermi? [S/n]: " CONFIRM
    if [[ "$$CONFIRM" =~ ^[nN]$$ ]]; then echo "Installazione annullata."; exit 0; fi

    echo ""
    echo "Installazione dipendenze..."
    apt install -y curl
    [[ "$USE_EMAIL" == true ]] && apt install -y mailutils
    if [[ "$USE_NTFY" == true ]]; then apt install -y qrencode || true; fi

    cat > "$CONFIG_FILE" << EOF
NTFY_TOPIC="${NTFY_TOPIC}"
EMAIL="${EMAIL}"
USE_NTFY=${USE_NTFY}
USE_EMAIL=${USE_EMAIL}
ACTION="${ACTION}"
EOF
    chmod 600 "$CONFIG_FILE"

    write_runner

    echo "Configurazione cron..."
    local CRON_JOB="$${CRON_MIN} $${CRON_HOUR} * * * ${RUNNER_SCRIPT}"
    ( crontab -l 2>/dev/null | grep -v "update-and-shutdown" ; echo "$CRON_JOB" ) | crontab -
    if crontab -l | grep -q "update-and-shutdown"; then
        echo "  -> Cron job scritto: ${CRON_JOB}"
    else
        echo "ERRORE: scrittura cron fallita. sudo crontab -e" >&2
        exit 1
    fi

    echo ""
    echo "Installazione completata! (v${SCRIPT_VERSION})"
    echo "  Runner: ${RUNNER_SCRIPT}"
    echo "  Config: ${CONFIG_FILE}"

    read -rp "Inviare notifica di TEST ora? [s/N]: " TEST
    if [[ "$$TEST" =~ ^[sS]$$ ]]; then
        source "$CONFIG_FILE"
        if [[ "$USE_NTFY" == true ]]; then
            curl -s -o /dev/null -X POST -H "Title: Test" -H "Priority: high" \
                -d "Notifica di test: il sistema funziona." "${NTFY_TOPIC}"
        fi
        echo "Notifica di test inviata (se ntfy attivo)."
    fi

    if [[ "$USE_NTFY" == true ]] && command -v qrencode >/dev/null 2>&1; then
        echo ""
        echo "Scansiona il QR con l'app ntfy (Aggiungi -> icona QR):"
        echo ""
        qrencode -t ANSIUTF8 "$NTFY_TOPIC"
        echo ""
        echo "  Indirizzo: ${NTFY_TOPIC}"
    fi
}

# --- Disinstallazione (in-line + script autonomo) ---
do_uninstall() {
    require_root
    echo "Verra' rimosso: job cron, runner, config, disinstaller."
    read -rp "Confermi la disinstallazione? [S/n]: " CONFIRM
    if [[ "$$CONFIRM" =~ ^[nN]$$ ]]; then echo "Annullata."; exit 0; fi

    if crontab -l 2>/dev/null | grep -q "update-and-shutdown"; then
        ( crontab -l 2>/dev/null | grep -v "update-and-shutdown" ) | crontab -
        echo "  -> Job cron rimosso."
    fi
    rm -f "$$RUNNER_SCRIPT" "$$CONFIG_FILE"
    echo "  -> Runner e config eliminati."
    if [[ -f "$$UNINSTALLER" ]]; then rm -f "$$UNINSTALLER"; echo "  -> Disinstaller rimosso."; fi
    echo "Disinstallazione completata. (Lo script ${SELF_PATH} resta: eliminalo a mano se vuoi.)"
    exit 0
}

# --- Script di disinstallazione autonomo ---
write_uninstaller() {
    require_root
    cat > "$UNINSTALLER" << 'UN'
#!/usr/bin/env bash
# Disinstaller autonomo per update-and-shutdown
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
if [[ $EUID -ne 0 ]]; then echo "Richiede root (sudo)."; exit 1; fi
if crontab -l 2>/dev/null | grep -q "update-and-shutdown"; then
    ( crontab -l 2>/dev/null | grep -v "update-and-shutdown" ) | crontab -
    echo "  -> Job cron rimosso."
fi
rm -f /usr/local/bin/update-and-shutdown.sh /etc/update-shutdown.conf
echo "  -> Runner e config eliminati."
rm -f /usr/local/bin/uninstall-update-shutdown.sh
echo "Disinstallazione completata."
UN
    chmod 755 "$UNINSTALLER"
    echo "Disinstaller scritto in ${UNINSTALLER}"
    echo "Per disinstallare: sudo ${UNINSTALLER}"
}

# --- Status ---
do_status() {
    echo "Script:      $${SCRIPT_NAME} v$${SCRIPT_VERSION}"
    echo "Runner:      $$([[ -f "$$RUNNER_SCRIPT" ]] && echo presente || echo assente)"
    echo "Config:      $$([[ -f "$$CONFIG_FILE" ]] && echo presente || echo assente)"
    echo "Job cron:"
    crontab -l 2>/dev/null | grep "update-and-shutdown" || echo "  (nessuno)"
}

usage() {
    cat << EOF
$${SCRIPT_NAME} v$${SCRIPT_VERSION}
Aggiornamento automatico del sistema con notifica e azione opzionale.

Uso: ${SCRIPT_NAME} <comando>

Comandi:
  install       Configura e installa job + runner + cron (interattivo)
  uninstall     Rimuove job cron, runner e config
  write-uninstaller  Crea lo script di disinstallazione autonomo
  update        Aggiorna questo script dal repository GitHub
  check-update  Verifica se esiste una versione piu' recente
  status        Mostra lo stato dell'installazione
  version       Mostra la versione
  help          Mostra questo aiuto
EOF
}

case "${1:-help}" in
    install)          do_install ;;
    uninstall)        do_uninstall ;;
    write-uninstaller) write_uninstaller ;;
    update)           do_update ;;
    check-update)     check_update ;;
    status)           do_status ;;
    version)          echo "${SCRIPT_VERSION}" ;;
    help|--help|-h)   usage ;;
    *) echo "Comando sconosciuto: \$1"; usage; exit 1 ;;
esac
