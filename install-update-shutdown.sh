#!/usr/bin/env bash
# install-update-shutdown.sh
# Aggiornamento automatico del sistema con notifiche ntfy/email (con dedup),
# e azione opzionale (spegnimento/riavvio) eseguita SOLO se l'aggiornamento
# e' riuscito. Installabile via curl, gestito da CLI, con auto-update.
#
# Installazione:
#   curl -fsSL https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/install-update-shutdown.sh \
#     -o /usr/local/bin/install-update-shutdown.sh && sudo chmod +x /usr/local/bin/install-update-shutdown.sh
#   sudo install-update-shutdown.sh install

set -euo pipefail

# --- METADATI (aggiorna SCRIPT_VERSION a ogni rilascio) ---
SCRIPT_NAME="install-update-shutdown.sh"
SCRIPT_VERSION="2.0.2"
SCRIPT_REPO_OWNER="xunil89"
SCRIPT_REPO_NAME="server-ubuntu-script"
SCRIPT_BRANCH="install-update-shutdown"
SCRIPT_RAW_URL="https://raw.githubusercontent.com/${SCRIPT_REPO_OWNER}/${SCRIPT_REPO_NAME}/${SCRIPT_BRANCH}/${SCRIPT_NAME}"

# --- PERCORSI ---
SELF_PATH="/usr/local/bin/${SCRIPT_NAME}"
UPDATE_SCRIPT="/usr/local/bin/update-check.sh"
POWER_SCRIPT="/usr/local/bin/power-action.sh"
WRAPPER_SCRIPT="/usr/local/bin/update-then-power.sh"
CONFIG_FILE="/etc/update-shutdown.conf"
STATE_DIR="/var/lib/update-shutdown"
STATE_FILE="${STATE_DIR}/state"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Questo comando richiede privilegi di root (sudo)." >&2
        exit 1
    fi
}

version_gt() {
    local v1="$1" v2="$2" IFS=.
    local -a a=($v1) b=($v2)
    local i
    for i in 0 1 2; do
        local n1="${a[$i]:-0}" n2="${b[$i]:-0}"
        (( n1 > n2 )) && return 0
        (( n1 < n2 )) && return 1
    done
    return 1
}

check_update() {
    local remote
    remote=$(curl -fsSL --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' | head -n1)
    if [[ -z "$remote" ]]; then
        echo "ERRORE: impossibile leggere la versione remota." >&2
        return 1
    fi
    echo "Versione locale:  ${SCRIPT_VERSION}"
    echo "Versione remota:  ${remote}"
    if version_gt "$remote" "$SCRIPT_VERSION"; then
        echo "Aggiornamento disponibile."; return 2
    else
        echo "Sei aggiornato."; return 0
    fi
}

do_update() {
    require_root
    if [[ ! -w "$SELF_PATH" ]]; then
        echo "ERRORE: script non installato in ${SELF_PATH}." >&2
        exit 1
    fi
    local remote
    remote=$(curl -fsSL --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' | head -n1)
    [[ -z "$remote" ]] && { echo "ERRORE: download versione remota fallito." >&2; exit 1; }
    if ! version_gt "$remote" "$SCRIPT_VERSION"; then
        echo "Sei gia' aggiornato (v${SCRIPT_VERSION})."; exit 0
    fi
    echo "Aggiorno v${SCRIPT_VERSION} -> v${remote}..."
    local tmp; tmp=$(mktemp)
    curl -fsSL --max-time 30 "$SCRIPT_RAW_URL" -o "$tmp" || { rm -f "$tmp"; exit 1; }
    head -n1 "$tmp" | grep -q '^#!' || { echo "ERRORE: file non valido." >&2; rm -f "$tmp"; exit 1; }
    mv "$tmp" "$SELF_PATH"; chmod 755 "$SELF_PATH"
    echo "Aggiornato a v${remote}."
}

# --- Genera i tre script runtime ---
write_scripts() {
    # 1) update-check.sh : controlla + aggiorna + notifica (dedup)
    cat > "$UPDATE_SCRIPT" << 'UPD'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/update-shutdown.conf
HOSTNAME=$(hostname)

tail_text() { printf '%s\n' "\$1" | tail -n 25; }

notify() {
    local key="\$1" subject="\$2" body="\$3"
    # Dedup: notifica solo se la chiave di stato e' cambiata
    if [[ "$NOTIFY_DEDUP" == true ]]; then
        mkdir -p "$STATE_DIR" 2>/dev/null
        if [[ -f "$STATE_FILE" ]] && [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "$key" ]]; then
            return 0
        fi
    fi
    if [[ "$USE_NTFY" == true ]]; then
        curl -s -o /dev/null -X POST \
            -H "Title: ${subject}" -H "Priority: ${NOTIFY_PRIORITY}" \
            -d "$body" "${NTFY_TOPIC}"
    fi
    if [[ "$USE_EMAIL" == true ]]; then
        printf '%s\n' "$body" | mail -s "${subject} - ${HOSTNAME}" "${EMAIL}"
    fi
    if [[ "$NOTIFY_DEDUP" == true ]]; then
        printf '%s' "$key" > "$STATE_FILE"
    fi
}

# --- Controllo disponibilita aggiornamenti ---
apt-get update -qq
COUNT=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst ')

if [[ "$COUNT" -eq 0 ]]; then
    notify "none" "Sistema aggiornato" "Nessun aggiornamento su ${HOSTNAME}."
    exit 0
fi

# --- Aggiornamento (cattura exit code) ---
set +e
update_out=$(apt update -y 2>&1); update_rc=$?
upgrade_out=$(apt upgrade -y 2>&1); upgrade_rc=$?
set -e

if [[ $update_rc -ne 0 ]]; then
    notify "fail_update" "Aggiornamento fallito (apt update)" \
        "apt update fallito su ${HOSTNAME} (exit ${update_rc}).\n\n$(tail_text "$update_out")"
    exit 1
fi
if [[ $upgrade_rc -ne 0 ]]; then
    notify "fail_upgrade" "Aggiornamento fallito (apt upgrade)" \
        "apt upgrade fallito su ${HOSTNAME} (exit ${upgrade_rc}).\n\n$(tail_text "$upgrade_out")"
    exit 1
fi

audit_out=$(dpkg --audit 2>&1)
if [[ -n "$audit_out" ]]; then
    notify "fail_dpkg" "Aggiornamento incompleto (dpkg)" \
        "Pacchetti inconsistenti su ${HOSTNAME}.\n\n$(tail_text "$audit_out")"
    exit 1
fi

notify "updated_${COUNT}" "Aggiornamento completato" \
    "${COUNT} aggiornamenti installati su ${HOSTNAME}."
exit 0
UPD
    chmod 700 "$UPDATE_SCRIPT"

    # 2) power-action.sh : esegue SOLO l'azione (se configurata)
    cat > "$POWER_SCRIPT" << 'POW'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
source /etc/update-shutdown.conf
HOSTNAME=$(hostname)

notify() {
    local subject="\$1" body="\$2"
    if [[ "$USE_NTFY" == true ]]; then
        curl -s -o /dev/null -X POST \
            -H "Title: ${subject}" -H "Priority: ${NOTIFY_PRIORITY}" \
            -d "$body" "${NTFY_TOPIC}"
    fi
    if [[ "$USE_EMAIL" == true ]]; then
        printf '%s\n' "$body" | mail -s "${subject} - ${HOSTNAME}" "${EMAIL}"
    fi
}

case "$ACTION" in
    shutdown)
        notify "Spegnimento" "Spegnimento di ${HOSTNAME} in corso."
        /usr/sbin/shutdown -h now ;;
    reboot)
        notify "Riavvio" "Riavvio di ${HOSTNAME} in corso."
        /usr/sbin/shutdown -r now ;;
    *)
        : ;;  # nessuna azione
esac
POW
    chmod 700 "$POWER_SCRIPT"

    # 3) wrapper : power SOLO se update esce 0
    cat > "$WRAPPER_SCRIPT" << 'WRAP'
#!/bin/bash
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# L'azione di potenza parte solo se l'aggiornamento e' riuscito (exit 0)
/usr/local/bin/update-check.sh && /usr/local/bin/power-action.sh
WRAP
    chmod 700 "$WRAPPER_SCRIPT"
}

# --- Configurazione (usata da install e settings) ---
collect_config() {
    # Default espliciti: evita "unbound variable" con set -u quando ntfy/email off
    NTFY_TOPIC=""
    EMAIL=""
    USE_NTFY=false
    USE_EMAIL=false

    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi

    echo "Configurazione notifiche:"
    echo ""
    local ans
    read -rp "Attivare notifiche ntfy? [S/n]: " ans
    if [[ "$ans" =~ ^[nN]$ ]]; then
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
        local rand
        if command -v openssl >/dev/null 2>&1; then
            rand=$(openssl rand -hex 8)
        else
            rand=$(tr -dc 'a-f0-9' < /dev/urandom | head -c 16)
        fi
        NTFY_TOPIC="${NTFY_BASE_URL}/srv-${rand}"
        echo "  -> ntfy configurato: ${NTFY_TOPIC}"
    fi

    echo ""
    read -rp "Attivare notifiche email? [s/N]: " ans
    if [[ "$ans" =~ ^[sS]$ ]]; then
        USE_EMAIL=true
        read -rp "Indirizzo email di destinazione: " EMAIL
    else
        USE_EMAIL=false
    fi

    echo ""
    echo "Notifiche: invia solo a stato cambiato (dedup)?"
    read -rp "Dedup notifiche? [S/n]: " ans
    if [[ "$ans" =~ ^[nN]$ ]]; then NOTIFY_DEDUP=false; else NOTIFY_DEDUP=true; fi
    read -rp "Priorita notifica ntfy (1=bassa..5=alta) [3]: " NOTIFY_PRIORITY
    NOTIFY_PRIORITY=${NOTIFY_PRIORITY:-3}

    echo ""
    echo "Azione dopo un aggiornamento riuscito:"
    echo "  1) Nessuna azione"
    echo "  2) Spegnere il server"
    echo "  3) Riavviare il server"
    read -rp "Scelta [1/2/3] (default 1): " ACTION_CHOICE
    ACTION_CHOICE=${ACTION_CHOICE:-1}
    case "$ACTION_CHOICE" in
        2) ACTION="shutdown"; ACTION_LABEL="Spegnimento" ;;
        3) ACTION="reboot";   ACTION_LABEL="Riavvio" ;;
        *) ACTION="none";     ACTION_LABEL="Nessuna" ;;
    esac

    echo ""
    read -rp "Ora di esecuzione (HH:MM) [02:00]: " RUN_TIME
    RUN_TIME=${RUN_TIME:-02:00}
    echo "Ogni quanto controllare la disponibilita aggiornamenti?"
    echo "  Esempi: 60 = ogni ora, 240 = ogni 4 ore, 1440 = ogni giorno"
    read -rp "Intervallo in minuti [240]: " CHECK_MINUTES
    CHECK_MINUTES=${CHECK_MINUTES:-240}
    if ! [[ "$CHECK_MINUTES" =~ ^[0-9]+$ ]] || [[ "$CHECK_MINUTES" -lt 1 ]]; then
        echo "ERRORE: intervallo non valido." >&2; return 1
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << EOF
NTFY_TOPIC="${NTFY_TOPIC}"
EMAIL="${EMAIL}"
USE_NTFY=${USE_NTFY}
USE_EMAIL=${USE_EMAIL}
NOTIFY_DEDUP=${NOTIFY_DEDUP}
NOTIFY_PRIORITY=${NOTIFY_PRIORITY}
ACTION="${ACTION}"
CHECK_MINUTES=${CHECK_MINUTES}
RUN_TIME="${RUN_TIME}"
EOF
    chmod 600 "$CONFIG_FILE"
}

build_cron() {
    local rt="${RUN_TIME:-02:00}"
    local CRON_HOUR CRON_MIN
    CRON_HOUR=$(echo "$rt" | cut -d: -f1)
    CRON_MIN=$(echo "$rt" | cut -d: -f2)
    # Normalizza: rimuove zeri iniziali ma mantiene almeno una cifra
    CRON_HOUR=$((10#$CRON_HOUR))
    CRON_MIN=$((10#$CRON_MIN))
    echo "${CRON_MIN} ${CRON_HOUR} * * * ${WRAPPER_SCRIPT}"
}

install_cron() {
    local job="$1"
    ( crontab -l 2>/dev/null | grep -v "update-then-power" | sed '/^$/d' ; echo "$job" ) | crontab -
    if crontab -l | grep -q "update-then-power"; then
        echo "  -> Cron job scritto: ${job}"
    else
        echo "ERRORE: scrittura cron fallita. sudo crontab -e" >&2
        return 1
    fi
}

do_install() {
    require_root
    if ! command -v crontab >/dev/null 2>&1; then
        echo "ERRORE: 'crontab' non trovato. sudo apt install -y cron && sudo systemctl enable --now cron" >&2
        exit 1
    fi
    if ! systemctl is-active --quiet cron; then
        systemctl enable --now cron || { echo "ERRORE: impossibile avviare cron." >&2; exit 1; }
    fi

    collect_config
    echo ""
    echo "=========================================="
    echo "  Riepilogo:"
    echo "    ntfy:        ${USE_NTFY}"
    echo "    email:       ${USE_EMAIL}"
    echo "    dedup:       ${NOTIFY_DEDUP}"
    echo "    priorita:    ${NOTIFY_PRIORITY}"
    echo "    azione:      ${ACTION_LABEL}"
    echo "    orario:      ${RUN_TIME}"
    echo "    intervallo:  ogni ${CHECK_MINUTES} minuti"
    echo "=========================================="
    read -rp "Confermi? [S/n]: " CONFIRM
    [[ "$CONFIRM" =~ ^[nN]$ ]] && { echo "Annullata."; exit 0; }

    echo ""
    echo "Installazione dipendenze..."
    apt install -y curl
    [[ "$USE_EMAIL" == true ]] && apt install -y mailutils
    [[ "$USE_NTFY" == true ]] && apt install -y qrencode || true

    mkdir -p "$STATE_DIR"
    save_config
    write_scripts
    install_cron "$(build_cron)"

    echo ""
    echo "Installazione completata! (v${SCRIPT_VERSION})"
    test_and_qr
}

do_settings() {
    require_root
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Nessuna installazione trovata. Lancia prima: install"; exit 1
    fi
    collect_config
    save_config
    write_scripts
    install_cron "$(build_cron)"
    rm -f "$STATE_FILE"   # reset dedup dopo riconfigurazione
    echo ""
    echo "Configurazione aggiornata."
}

test_and_qr() {
    read -rp "Inviare notifica di TEST ora? [s/N]: " TEST
    if [[ "$TEST" =~ ^[sS]$ ]]; then
        source "$CONFIG_FILE"
        if [[ "$USE_NTFY" == true ]]; then
            curl -s -o /dev/null -X POST -H "Title: Test" -H "Priority: ${NOTIFY_PRIORITY}" \
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

do_uninstall() {
    require_root
    echo "Verra' rimosso: job cron, update-check.sh, power-action.sh, wrapper, config, stato."
    read -rp "Confermi la disinstallazione? [S/n]: " CONFIRM
    [[ "$CONFIRM" =~ ^[nN]$ ]] && { echo "Annullata."; exit 0; }

    if crontab -l 2>/dev/null | grep -q "update-then-power"; then
        ( crontab -l 2>/dev/null | grep -v "update-then-power" ) | crontab -
        echo "  -> Job cron rimosso."
    fi
    rm -f "$UPDATE_SCRIPT" "$POWER_SCRIPT" "$WRAPPER_SCRIPT" "$CONFIG_FILE"
    rm -rf "$STATE_DIR"
    echo "  -> Script, config e stato rimossi."
    echo "Disinstallazione completata. (Lo script ${SELF_PATH} resta: eliminalo a mano se vuoi.)"
}

do_status() {
    echo "Script:  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    echo "Update:  $([[ -f "$UPDATE_SCRIPT" ]] && echo presente || echo assente)"
    echo "Power:   $([[ -f "$POWER_SCRIPT" ]] && echo presente || echo assente)"
    echo "Wrapper: $([[ -f "$WRAPPER_SCRIPT" ]] && echo presente || echo assente)"
    echo "Config:  $([[ -f "$CONFIG_FILE" ]] && echo presente || echo assente)"
    echo "Job cron:"
    crontab -l 2>/dev/null | grep "update-then-power" || echo "  (nessuno)"
}

usage() {
    cat << EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}
Aggiornamento automatico con notifica e azione opzionale (solo se update riuscito).

Uso: ${SCRIPT_NAME} <comando>

Comandi:
  install       Configura e installa (interattivo)
  settings      Modifica la configurazione dopo l'installazione
  uninstall     Rimuove cron, script, config e stato
  update        Aggiorna questo script dal repository GitHub
  check-update  Verifica se esiste una versione piu' recente
  status        Mostra lo stato dell'installazione
  version       Mostra la versione
  help          Mostra questo aiuto
EOF
}

case "${1:-help}" in
    install)      do_install ;;
    settings)     do_settings ;;
    uninstall)    do_uninstall ;;
    update)       do_update ;;
    check-update) check_update ;;
    status)       do_status ;;
    version)      echo "${SCRIPT_VERSION}" ;;
    help|--help|-h) usage ;;
    *) echo "Comando sconosciuto: \$1"; usage; exit 1 ;;
esac
