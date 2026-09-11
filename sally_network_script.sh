#!/bin/bash
set -euo pipefail

# ============================================================
# Post-Klon-Setup für Ubuntu-VM (Nutanix AHV)
# Setzt: Hostname, feste IP (Netplan), neue SSH-Host-Keys
#
# WICHTIG: Vor dem Ausführen die Variablen unten anpassen!
# ============================================================

# --- Konfiguration anpassen ---
NEW_HOSTNAME="civitascore-klon101"
NEW_IP="192.168.210.101/24"
GATEWAY="192.168.210.1"
DNS="8.8.8.8"
IFACE="ens3"
NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
# --------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen (sudo $0)" >&2
  exit 1
fi

echo "==> Setze Hostname auf '${NEW_HOSTNAME}' ..."
hostnamectl set-hostname "${NEW_HOSTNAME}"

# /etc/hosts aktualisieren (127.0.1.1-Zeile ersetzen oder anlegen)
if grep -q "^127.0.1.1" /etc/hosts; then
  sed -i "s/^127.0.1.1.*/127.0.1.1\t${NEW_HOSTNAME}/" /etc/hosts
else
  echo -e "127.0.1.1\t${NEW_HOSTNAME}" >> /etc/hosts
fi

echo "==> Schreibe Netplan-Konfiguration nach ${NETPLAN_FILE} ..."
cat > "${NETPLAN_FILE}" << EOF
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      addresses:
        - ${NEW_IP}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - ${DNS}
EOF

chmod 600 "${NETPLAN_FILE}"

echo "==> Wende Netzwerkkonfiguration an ..."
netplan apply

echo "==> Entferne alte SSH-Host-Keys und generiere neue ..."
rm -f /etc/ssh/ssh_host_*key*
ssh-keygen -A

echo "==> Prüfe SSH-Konfiguration ..."
sshd -t && echo "sshd-Konfiguration OK"

echo "==> Starte SSH-Dienst neu ..."
systemctl restart ssh
systemctl status ssh --no-pager

echo ""
echo "==> Fertig. Aktueller Stand:"
hostnamectl
ip a show "${IFACE}"

echo ""
echo "Hinweis: Falls dieser Host schon einmal unter einer anderen IP/Hostname"
echo "in known_hosts von Clients gespeichert war, ggf. dort bereinigen mit:"