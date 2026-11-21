bash
Copia
#!/usr/bin/env bash
# uninstall-update-shutdown.sh
# Rimuove job cron, script runtime, configurazione e stato.
#   curl -fsSL https://raw.githubusercontent.com/xunil89/server-ubuntu-script/install-update-shutdown/uninstall-update-shutdown.sh \
#     -o /usr/local/bin/uninstall-update-shutdown.sh && sudo chmod +x /usr/local/bin/uninstall-update-shutdown.sh
#   sudo uninstall-update-shutdown.sh

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [[ $EUID -ne 0 ]]; then echo "Richiede root (sudo)." >&2; exit 1; fi

if crontab -l 2>/dev/null | grep -q "update-then-power"; then
    ( crontab -l 2>/dev/null | grep -v "update-then-power" ) | crontab -
    echo "  -> Job cron rimosso."
else
    echo "  -> Nessun job cron trovato."
fi

rm -f /usr/local/bin/update-check.sh \
      /usr/local/bin/power-action.sh \
      /usr/local/bin/update-then-power.sh \
      /etc/update-shutdown.conf
rm -rf /var/lib/update-shutdown
echo "  -> Script, config e stato rimossi."
echo "Disinstallazione completata."
