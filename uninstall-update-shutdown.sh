#!/usr/bin/env bash
# uninstall-update-shutdown.sh
# Rimuove job cron, runner e configurazione di update-and-shutdown.
# Installazione:
#   curl -fsSL https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/uninstall-update-shutdown.sh \
#     -o /usr/local/bin/uninstall-update-shutdown.sh && sudo chmod +x /usr/local/bin/uninstall-update-shutdown.sh
#   sudo uninstall-update-shutdown.sh

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ $EUID -ne 0 ]]; then
    echo "Richiede privilegi di root (sudo)." >&2
    exit 1
fi

if crontab -l 2>/dev/null | grep -q "update-and-shutdown"; then
    ( crontab -l 2>/dev/null | grep -v "update-and-shutdown" ) | crontab -
    echo "  -> Job cron rimosso."
else
    echo "  -> Nessun job cron trovato."
fi

rm -f /usr/local/bin/update-and-shutdown.sh
echo "  -> Runner rimosso."
rm -f /etc/update-shutdown.conf
echo "  -> Configurazione rimossa."

echo "Disinstallazione completata."
