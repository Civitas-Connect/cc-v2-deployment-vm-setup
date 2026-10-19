#!/usr/bin/env bash
#
# 20-sysprep-template.sh
#
# Seals the running master VM for a snapshot.
#
# Difference to the classic approach: NOTHING the running machine needs right
# now is deleted. machine-id, SSH host keys, hostname and network
# configuration stay untouched. Instead a marker (/etc/civitas/sealed) is set,
# which civitas-firstboot.service evaluates on the next boot - in every clone
# and, after its next reboot, in the master as well.
#
# This means: the master does NOT have to be shut down for the snapshot.
# Which is exactly what hypervisors like Nutanix AHV expect.
#
# What still happens here:
#   - k3s is stopped so the SQLite datastore in the snapshot is consistent
#   - credentials and instance artifacts are removed
#   - logs, caches and shell history are cleared
#   - fstrim returns free space, making the snapshot smaller
#
# Usage:
#   sudo ./20-sysprep-template.sh                   # cluster stays in the image (recommended)
#   sudo ./20-sysprep-template.sh --reset-cluster   # discard cluster state
#   sudo ./20-sysprep-template.sh --reboot          # reboot after sealing
#
# Normal order:
#   1. sudo ./20-sysprep-template.sh
#   2. take a snapshot of the RUNNING VM in the hypervisor
#   3. sudo reboot            -> the master re-personalizes itself
#   4. sudo ./25-postclone-setup.sh ...   -> restore hostname and static IP
#

set -uo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

RESET_CLUSTER=false
REBOOT_AFTER=false
for arg in "$@"; do
  case "$arg" in
    --reset-cluster) RESET_CLUSTER=true ;;
    --reboot)        REBOOT_AFTER=true ;;
    *)               die "Unbekannte Option: $arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# 0 – Prerequisites
# ---------------------------------------------------------------------------

[[ -x /usr/local/sbin/civitas-firstboot.sh ]] \
  || die "civitas-firstboot.sh fehlt. Das Image stammt aus einer aelteren Version von 10-build-template.sh - dort zuerst neu bauen."

systemctl is-enabled civitas-firstboot.service >/dev/null 2>&1 \
  || die "civitas-firstboot.service ist nicht aktiviert. Ohne den Dienst waeren alle Klone identisch."

systemctl is-enabled civitas-clusterfix.service >/dev/null 2>&1 \
  || warn "civitas-clusterfix.service ist nicht aktiviert. Klone koennen dann Pods in CreateContainerError haben (Container-Namen aus dem Snapshot). 10-build-template.sh erneut laufen lassen."

[[ -f /etc/netplan/01-civitas-dhcp.yaml ]] \
  || warn "Kein DHCP-Fallback unter /etc/netplan/01-civitas-dhcp.yaml. Klone kommen dann nur ueber die Konsole ans Netz."

# After a snapshot restore a VM's clock is often wrong. k3s then rejects
# its own certificates. Better to notice now than in the clone.
if ! timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  warn "Systemzeit ist nicht synchronisiert. Klone koennen dadurch k3s-Zertifikatsfehler bekommen."
  warn "Vorher pruefen: timedatectl && systemctl restart systemd-timesyncd"
fi

avail=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9')
[[ -n "$avail" && "$avail" -lt 10 ]] && warn "Nur ${avail}G frei auf / - Klone laufen damit schnell voll."

found_key=false
for home in /root /home/*; do
  [[ -s "${home}/.ssh/authorized_keys" ]] && found_key=true
done
$found_key || warn "In keinem Home liegt eine authorized_keys - Passwort-Login ist aus, der Klon waere unerreichbar!"

cat <<EOF

Dieses Skript versiegelt die laufende VM fuer einen Snapshot.

  - k3s wird gestoppt und laeuft bis zum naechsten Reboot nicht mehr
  - Zugangsdaten in /etc/civitas/deploy.env werden geloescht
  - Beim naechsten Boot erzeugt diese VM eine neue Identitaet und startet
    dabei ein zweites Mal - Hostname und feste IP sind danach weg und
    muessen mit 25-postclone-setup.sh neu gesetzt werden

  Cluster-Reset: ${RESET_CLUSTER}
EOF
read -r -p "Fortfahren? [ja/NEIN] " answer
[[ "$answer" == "ja" ]] || die "Abgebrochen."

# ---------------------------------------------------------------------------
# 1 – Back up the master's network configuration
# ---------------------------------------------------------------------------

BACKUP="/root/civitas-master-netz-$(date +%Y%m%d-%H%M%S)"
log "Netzkonfiguration des Masters nach ${BACKUP} sichern"
mkdir -p "$BACKUP"
cp -a /etc/netplan/. "$BACKUP/" 2>/dev/null || true
hostnamectl --static >"$BACKUP/hostname" 2>/dev/null || true
ip -4 -br addr show scope global >"$BACKUP/adressen.txt" 2>/dev/null || true
echo "  gesichert: $(ls -1 "$BACKUP" | tr '\n' ' ')"
echo "  Diese Dateien liegen NUR im Master und wandern mit in den Snapshot -"
echo "  civitas-firstboot loescht sie im Klon nicht, sie sind aber auch nicht aktiv."

# ---------------------------------------------------------------------------
# 2 – Stop the cluster cleanly
# ---------------------------------------------------------------------------

log "k3s stoppen"
# The service must STAY enabled, otherwise the cluster never comes up after
# the clone boots and 25-postclone-setup.sh waits forever.
systemctl enable k3s >/dev/null 2>&1 || true
systemctl stop k3s 2>/dev/null || true
[[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
sleep 3

if $RESET_CLUSTER; then
  log "Cluster-State verwerfen (Klon baut beim ersten Boot neu auf)"
  rm -rf /var/lib/rancher/k3s/server
  rm -rf /var/lib/rancher/k3s/agent/client-* \
         /var/lib/rancher/k3s/agent/server-* \
         /var/lib/rancher/k3s/agent/*.kubeconfig \
         /var/lib/rancher/k3s/agent/kubelet \
         /var/lib/rancher/k3s/agent/pod-manifests
  rm -f  /etc/rancher/k3s/k3s.yaml
  rm -rf /etc/rancher/node
  rm -rf /var/lib/kubelet 2>/dev/null || true
  warn "Nach dem Klonen zusaetzlich noetig: sudo ./10-build-template.sh --addons-only"
else
  log "Cluster bleibt im Image - nur fluechtige Reste raeumen"
  rm -rf /var/log/pods/* /var/log/containers/* 2>/dev/null || true
fi

# The image store is kept in both cases - it is node-independent
# and the actual reason why the template is fast.

# ---------------------------------------------------------------------------
# 3 – Remove instance-specific artifacts
# ---------------------------------------------------------------------------

log "Deployment-Konfiguration mit Zugangsdaten entfernen"
rm -f /etc/civitas/deploy.env
rm -rf /opt/civitas/rendered

# ---------------------------------------------------------------------------
# 4 – Logs, caches, history
# ---------------------------------------------------------------------------

log "Logs und Caches leeren"
systemctl stop fail2ban 2>/dev/null || true
rm -f /var/lib/fail2ban/fail2ban.sqlite3
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete 2>/dev/null || true
for f in /var/log/syslog /var/log/auth.log /var/log/kern.log /var/log/ufw.log \
         /var/log/fail2ban.log /var/log/wtmp /var/log/btmp /var/log/lastlog; do
  [[ -f "$f" ]] && : >"$f"
done

apt-get clean
rm -rf /var/lib/apt/lists/*

for home in /root /home/*; do
  rm -f "${home}/.bash_history" "${home}/.wget-hsts" "${home}/.lesshst"
  rm -rf "${home}/.cache/helm/repository/"*.tgz 2>/dev/null || true
done
history -c 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5 – Seal
# ---------------------------------------------------------------------------

log "Image versiegeln"
mkdir -p /etc/civitas
{
  echo "SEALED_AT=$(date -Iseconds)"
  echo "SEALED_BY=${SUDO_USER:-root}"
  echo "RESET_CLUSTER=${RESET_CLUSTER}"
} >/etc/civitas/sealed
chmod 0644 /etc/civitas/sealed
systemctl enable civitas-firstboot.service >/dev/null 2>&1 || true
echo "  /etc/civitas/sealed gesetzt - civitas-firstboot greift beim naechsten Boot"

# ---------------------------------------------------------------------------
# 6 – Return free space and flush buffers to disk
# ---------------------------------------------------------------------------

# Otherwise a certificate dated in the future ends up in the image and breaks
# every clone as soon as NTP corrects the clock.
crt=/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
if [[ -f "$crt" ]]; then
  nb=$(openssl x509 -in "$crt" -noout -startdate 2>/dev/null | cut -d= -f2)
  if [[ -n "$nb" ]] && (( $(date -d "$nb" +%s 2>/dev/null || echo 0) > $(date +%s) )); then
    warn "k3s-Zertifikat ist erst ab ${nb} gueltig - es wurde bei falscher Uhr erzeugt."
    warn "Vor dem Snapshot beheben: timedatectl set-ntp true && sudo k3s certificate rotate"
  fi
fi

log "fstrim"
fstrim -av 2>/dev/null || warn "fstrim nicht moeglich (kein TRIM-faehiges Volume)."

log "Dateisystem-Puffer schreiben"
# A live snapshot is only crash-consistent. sync reduces the risk of
# half-written blocks ending up in the snapshot.
sync; sync
echo 3 >/proc/sys/vm/drop_caches 2>/dev/null || true

# ---------------------------------------------------------------------------

cat <<EOF

------------------------------------------------------------------
Image versiegelt. Die VM laeuft weiter und kann jetzt gesnapshottet werden.

JETZT:
  Snapshot bzw. Template der LAUFENDEN VM im Hypervisor erzeugen.
  Kein poweroff noetig - und k3s ist gestoppt, der Datastore also konsistent.

DANACH, auf dem Master:
  sudo reboot
  # civitas-firstboot erzeugt eine neue Identitaet und startet nochmals neu
  sudo ./25-postclone-setup.sh --hostname <name> --ip <ip/cidr> --gateway <gw> --dns <dns>

AUF JEDEM KLON:
  # startet automatisch zweimal, danach haengt er per DHCP im Netz
  sudo ./25-postclone-setup.sh --hostname <name> --ip <ip/cidr> --gateway <gw> --dns <dns>
$( $RESET_CLUSTER && echo "  sudo ./10-build-template.sh --addons-only" )
  sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env && sudo nano /etc/civitas/deploy.env
  sudo ./30-deploy-civitas.sh

Die gesicherte Netzkonfiguration des Masters liegt unter:
  ${BACKUP}
------------------------------------------------------------------
EOF

if $REBOOT_AFTER; then
  warn "Neustart in 10 Sekunden - der Snapshot muss VORHER gezogen worden sein. Abbruch mit Strg-C."
  sleep 10
  systemctl reboot
fi
