#!/usr/bin/env bash
# install-update-shutdown.sh
# Aggiornamento automatico Ubuntu/Debian con notifiche ntfy/email
# e azione opzionale: nessuna, spegnimento o riavvio.

set -euo pipefail

# --- METADATI ---
SCRIPT_NAME="install-update-shutdown.sh"
SCRIPT_VERSION="1.0.1"
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

# Ritorna 0 se la prima versione è maggiore della seconda.
version_gt() {
    local v1="$1" v2="$2"
    local IFS=.
    local -a a=($v1) b=($v2)

    for i in 0 1 2; do
        local n1="${a[$i]:-0}" n2="${b[$i]:-0}"
        n1=$((10#$n1))
        n2=$((10#$n2))

        if (( n1 > n2 )); then return 0; fi
        if (( n1 < n2 )); then return 1; fi
    done

    return 1
}

get_remote_version() {
    curl -fsSL --max-time 15 "$SCRIPT_RAW_URL" 2>/dev/null \
        | sed -n 's/^SCRIPT_VERSION="\([^"]*\)".*/\1/p' \
        | head -n 1
}

check_update() {
    local remote
    remote=$(get_remote_version)

    if [[ -z "$remote" ]]; then
        echo "ERRORE: impossibile leggere la versione remota dal repository." >&2
        return 1
    fi

    echo "Versione locale:  ${SCRIPT_VERSION}"
    echo "Versione remota:  ${remote}"

    if version_gt "$remote" "$SCRIPT_VERSION"; then
        echo "Aggiornamento disponibile."
        return 2
    fi

    echo "Sei aggiornato all'ultima versione."
    return 0
}

do_update() {
    require_root

    if [[ ! -w "$SELF_PATH" ]]; then
        echo "ERRORE: lo script non è installato in ${SELF_PATH}." >&2
        exit 1
    fi

    local remote tmp
    remote=$(get_remote_version)

    if [[ -z "$remote" ]]; then
        echo "ERRORE: impossibile leggere la versione remota." >&2
        exit 1
    fi

    if ! version_gt "$remote" "$SCRIPT_VERSION"; then
        echo "Sei già aggiornato (v${SCRIPT_VERSION})."
        exit 0
    fi

    echo "Aggiorno v${SCRIPT_VERSION} -> v${remote}..."
    tmp=$(mktemp)

    if ! curl -fsSL --max-time 30 "$SCRIPT_RAW_URL" -o "$tmp"; then
        echo "ERRORE: download fallito." >&2
        rm -f "$tmp"
        exit 1
    fi

    if ! head -n 1 "$tmp" | grep -q '^#!'; then
        echo "ERRORE: il file scaricato non sembra uno script valido." >&2
        rm -f "$tmp"
        exit 1
    fi

    install -m 755 "$tmp" "$SELF_PATH"
    rm -f "$tmp"
    echo "Aggiornato a v${remote}."
}

write_runner() {
    cat > "$RUNNER_SCRIPT" <<'RUNNER'
#!/usr/bin/env bash
set -u

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

source /etc/update-shutdown.conf

NTFY_TAGS="${NTFY_TAGS:-}"
HOSTNAME="$(hostname)"

notify() {
    local subject="$1"
    local body="$2"

    if [[ "${USE_NTFY:-false}" == true && -n "${NTFY_TOPIC:-}" ]]; then
        local headers=(-H "Title: ${subject}" -H "Priority: high")

        if [[ -n "$NTFY_TAGS" ]]; then
            headers+=(-H "Tags: ${NTFY_TAGS}")
        fi

        curl -fsS -o /dev/null -X POST \
            "${headers[@]}" \
            -d "$body" \
            "$NTFY_TOPIC" || true
    fi

    if [[ "${USE_EMAIL:-false}" == true && -n "${EMAIL:-}" ]]; then
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$body" \
                | mail -s "${subject} - ${HOSTNAME}" "$EMAIL" || true
        fi
    fi
}

if ! apt-get update; then
    notify "Aggiornamento fallito" "apt-get update non riuscito su ${HOSTNAME}."
    exit 1
fi

if ! apt-get upgrade -y; then
    notify "Aggiornamento fallito" "apt-get upgrade non riuscito su ${HOSTNAME}."
    exit 1
fi

if dpkg --audit | grep -q .; then
    notify "Aggiornamento fallito" \
        "Pacchetti in stato inconsistente su ${HOSTNAME}. Intervento manuale richiesto."
    exit 1
fi

case "${ACTION:-none}" in
    shutdown)
        notify "Aggiornamento completato" \
            "Sistema ${HOSTNAME} aggiornato. Spegnimento in corso."
        /usr/sbin/shutdown -h now
        ;;
    reboot)
        notify "Aggiornamento completato" \
            "Sistema ${HOSTNAME} aggiornato. Riavvio in corso."
        /usr/sbin/shutdown -r now
        ;;
    *)
        notify "Aggiornamento completato" \
            "Sistema ${HOSTNAME} aggiornato correttamente."
        ;;
esac
RUNNER

    chmod 700 "$RUNNER_SCRIPT"
}

do_install() {
    require_root

    if ! command -v crontab >/dev/null 2>&1; then
        echo "ERRORE: crontab non trovato. Installa cron con:" >&2
        echo "  apt install cron && systemctl enable --now cron" >&2
        exit 1
    fi

    if ! systemctl is-active --quiet cron; then
        systemctl enable --now cron || {
            echo "ERRORE: impossibile avviare cron." >&2
            exit 1
        }
    fi

    # Valori predefiniti: evitano errori con set -u quando un'opzione è disattivata.
    USE_NTFY=false
    USE_EMAIL=false
    NTFY_TOPIC=""
    NTFY_TAGS=""
    EMAIL=""
    NTFY_BASE_URL="https://ntfy.sh"

    generate_topic() {
        local rand
        if command -v openssl >/dev/null 2>&1; then
            rand=$(openssl rand -hex 8)
        else
            rand=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
        fi
        printf 'srv-%s\n' "$rand"
    }

    echo "Configurazione notifiche"
    read -rp "Attivare notifiche ntfy? [S/n]: " answer

    if [[ ! "$answer" =~ ^[nN]$ ]]; then
        USE_NTFY=true

        echo
        echo "Quale server ntfy usare?"
        echo "  1) Server predefinito (https://ntfy.sh)"
        echo "  2) Server privato"
        read -rp "Scelta [1/2] (predefinito 1): " NTFY_SERVER_CHOICE
        NTFY_SERVER_CHOICE="${NTFY_SERVER_CHOICE:-1}"

        if [[ "$NTFY_SERVER_CHOICE" == "2" ]]; then
            read -rp "URL del server ntfy: " NTFY_BASE_URL
            NTFY_BASE_URL="${NTFY_BASE_URL%/}"
        fi

        NTFY_TOPIC="${NTFY_BASE_URL}/$(generate_topic)"
        echo "ntfy configurato: ${NTFY_TOPIC}"
    fi

    echo
    read -rp "Attivare notifiche email? [s/N]: " answer

    if [[ "$answer" =~ ^[sS]$ ]]; then
        USE_EMAIL=true
        read -rp "Indirizzo email di destinazione: " EMAIL
    fi

    echo
    echo "Azione dopo l'aggiornamento:"
    echo "  1) Nessuna azione"
    echo "  2) Spegnere il server"
    echo "  3) Riavviare il server"
    read -rp "Scelta [1/2/3] (predefinito 1): " ACTION_CHOICE
    ACTION_CHOICE="${ACTION_CHOICE:-1}"

    case "$ACTION_CHOICE" in
        2) ACTION="shutdown"; ACTION_LABEL="Spegnimento" ;;
        3) ACTION="reboot"; ACTION_LABEL="Riavvio" ;;
        *) ACTION="none"; ACTION_LABEL="Nessuna" ;;
    esac

    read -rp "Ora di esecuzione (HH:MM) [02:00]: " RUN_TIME
    RUN_TIME="${RUN_TIME:-02:00}"

    if [[ ! "$RUN_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo "ERRORE: formato orario non valido. Usa HH:MM, per esempio 02:00." >&2
        exit 1
    fi

    local CRON_HOUR CRON_MIN
    CRON_HOUR=$((10#${RUN_TIME%%:*}))
    CRON_MIN=$((10#${RUN_TIME##*:}))

    echo
    echo "Riepilogo:"
    echo "  ntfy:   ${USE_NTFY}"
    echo "  email:  ${USE_EMAIL}"
    echo "  azione: ${ACTION_LABEL}"
    echo "  orario: ${RUN_TIME}"
    read -rp "Confermi? [S/n]: " CONFIRM

    if [[ "$CONFIRM" =~ ^[nN]$ ]]; then
        echo "Installazione annullata."
        exit 0
    fi

    echo
    echo "Installazione dipendenze..."
    apt-get update
    apt-get install -y curl

    if [[ "$USE_EMAIL" == true ]]; then
        apt-get install -y mailutils
    fi

    if [[ "$USE_NTFY" == true ]]; then
        apt-get install -y qrencode
    fi

    cat > "$CONFIG_FILE" <<EOF
NTFY_TOPIC="${NTFY_TOPIC}"
NTFY_TAGS="${NTFY_TAGS}"
EMAIL="${EMAIL}"
USE_NTFY=${USE_NTFY}
USE_EMAIL=${USE_EMAIL}
ACTION="${ACTION}"
EOF
    chmod 600 "$CONFIG_FILE"

    write_runner

    local CRON_JOB="${CRON_MIN} ${CRON_HOUR} * * * ${RUNNER_SCRIPT}"
    local CRON_TMP
    CRON_TMP=$(mktemp)

    crontab -l 2>/dev/null \
        | grep -v "update-and-shutdown" > "$CRON_TMP" || true
    echo "$CRON_JOB" >> "$CRON_TMP"
    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"

    echo
    echo "Installazione completata (v${SCRIPT_VERSION})."
    echo "Runner: ${RUNNER_SCRIPT}"
    echo "Config: ${CONFIG_FILE}"
    echo "Cron:   ${CRON_JOB}"

    if [[ "$USE_NTFY" == true ]] && command -v qrencode >/dev/null 2>&1; then
        echo
        echo "Scansiona il QR code con l'app ntfy:"
        echo
        qrencode -t ANSIUTF8 "$NTFY_TOPIC"
        echo
        echo "Indirizzo: ${NTFY_TOPIC}"
    fi
}

do_uninstall() {
    require_root

    echo "Verranno rimossi il job cron, il runner, la configurazione e il disinstaller."
    read -rp "Confermi la disinstallazione? [S/n]: " CONFIRM

    if [[ "$CONFIRM" =~ ^[nN]$ ]]; then
        echo "Disinstallazione annullata."
        exit 0
    fi

    local CRON_TMP
    CRON_TMP=$(mktemp)
    crontab -l 2>/dev/null \
        | grep -v "update-and-shutdown" > "$CRON_TMP" || true
    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"

    rm -f "$RUNNER_SCRIPT" "$CONFIG_FILE" "$UNINSTALLER"
    echo "Disinstallazione completata."
    echo "Lo script principale ${SELF_PATH} non è stato rimosso."
}

write_uninstaller() {
    require_root

    cat > "$UNINSTALLER" <<'UN'
#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ $EUID -ne 0 ]]; then
    echo "Esegui questo script con sudo." >&2
    exit 1
fi

tmp=$(mktemp)
crontab -l 2>/dev/null | grep -v "update-and-shutdown" > "$tmp" || true
crontab "$tmp"
rm -f "$tmp"

rm -f /usr/local/bin/update-and-shutdown.sh
rm -f /etc/update-shutdown.conf
rm -f /usr/local/bin/uninstall-update-shutdown.sh

echo "Disinstallazione completata."
UN

    chmod 755 "$UNINSTALLER"
    echo "Disinstaller creato: ${UNINSTALLER}"
}

do_status() {
    echo "Script:  ${SCRIPT_NAME} v${SCRIPT_VERSION}"
    [[ -f "$RUNNER_SCRIPT" ]] && echo "Runner:  presente" || echo "Runner:  assente"
    [[ -f "$CONFIG_FILE" ]] && echo "Config:  presente" || echo "Config:  assente"
    echo "Job cron:"
    crontab -l 2>/dev/null | grep "update-and-shutdown" || echo "  (nessuno)"
}

usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Uso: ${SCRIPT_NAME} <comando>

Comandi:
  install            Configura notifiche, runner e cron
  uninstall          Rimuove job cron, runner e configurazione
  write-uninstaller  Crea un disinstaller autonomo
  update             Aggiorna lo script dal repository GitHub
  check-update       Verifica se esiste una versione più recente
  status             Mostra lo stato dell'installazione
  version            Mostra la versione
  help               Mostra questo aiuto
EOF
}

case "${1:-help}" in
    install)          do_install ;;
    uninstall)        do_uninstall ;;
    write-uninstaller) write_uninstaller ;;
    update)           do_update ;;
    check-update)     check_update ;;
    status)           do_status ;;
    version)          echo "$SCRIPT_VERSION" ;;
    help|--help|-h)   usage ;;
    *)
        echo "Comando sconosciuto: $1" >&2
        usage
        exit 1
        ;;
esac
