#!/usr/bin/env bash
#
# 20-sysprep-template.sh
#
# Entfernt alles, was pro VM einzigartig sein muss, und faehrt die VM in einen
# Zustand, aus dem sauber geklont werden kann.
#
# Aufruf:
#   sudo ./20-sysprep-template.sh                  # Cluster bleibt im Image (empfohlen)
#   sudo ./20-sysprep-template.sh --reset-cluster  # Cluster-State wird verworfen,
#                                                  # der Klon baut beim ersten Boot
#                                                  # einen frischen Cluster auf
#
# Nach dem Lauf: sofort "sudo poweroff" und dann Snapshot/Template ziehen.
# Die VM NICHT noch einmal booten - beim naechsten Boot werden machine-id und
# SSH-Host-Keys neu erzeugt und waeren dann wieder im Image.
#

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

RESET_CLUSTER=false
[[ "${1:-}" == "--reset-cluster" ]] && RESET_CLUSTER=true

# ---------------------------------------------------------------------------
# 0 – Sicherheitsabfrage
# ---------------------------------------------------------------------------

cat <<EOF
Dieses Skript macht die VM klonbar und danach nicht mehr sinnvoll weiterbenutzbar,
bis sie neu gebootet wurde. Cluster-Reset: ${RESET_CLUSTER}
EOF
read -r -p "Fortfahren? [ja/NEIN] " answer
[[ "$answer" == "ja" ]] || die "Abgebrochen."

# ---------------------------------------------------------------------------
# 1 – Warnung bei fehlendem SSH-Key
# ---------------------------------------------------------------------------

found_key=false
for home in /root /home/*; do
  [[ -s "${home}/.ssh/authorized_keys" ]] && found_key=true
done
$found_key || warn "In keinem Home liegt eine authorized_keys - Passwort-Login ist aus, der Klon waere unerreichbar!"

# ---------------------------------------------------------------------------
# 2 – Cluster sauber anhalten
# ---------------------------------------------------------------------------

log "k3s stoppen"
systemctl stop k3s || true
# Raeumt Container-Shims, Mounts und CNI-Interfaces ab. Ohne das riskiert man
# eine inkonsistente Datastore-Datei im Snapshot.
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

# Der Image-Store bleibt in beiden Faellen erhalten - er ist node-unabhaengig
# und der eigentliche Grund, warum das Template schnell ist.

# ---------------------------------------------------------------------------
# 3 – Instanzspezifische Konfiguration entfernen
# ---------------------------------------------------------------------------

log "Deployment-Konfiguration mit Zugangsdaten entfernen"
rm -f /etc/civitas/deploy.env
rm -rf /opt/civitas/rendered

log "Netzwerk-Identitaet zuruecksetzen"
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/netplan/50-cloud-init.yaml
: >/etc/hostname
hostnamectl set-hostname localhost 2>/dev/null || true

log "cloud-init zuruecksetzen"
if command -v cloud-init >/dev/null; then
  cloud-init clean --logs --seed 2>/dev/null || cloud-init clean --logs || true
fi
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/*

# ---------------------------------------------------------------------------
# 4 – Logs, Caches, Historie
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
# 5 – Freien Speicher zurueckgeben (macht den Snapshot kleiner)
# ---------------------------------------------------------------------------

log "fstrim"
fstrim -av 2>/dev/null || warn "fstrim nicht moeglich (kein TRIM-faehiges Volume)."

# ---------------------------------------------------------------------------

cat <<EOF

------------------------------------------------------------------
Sysprep abgeschlossen.

JETZT:
  sudo poweroff
und danach im Hypervisor Snapshot bzw. Template erzeugen.

NICHT mehr booten - sonst landen machine-id und SSH-Host-Keys wieder im Image.

Nach dem Klonen:
  - Hostname und IP ueber cloud-init / Hypervisor setzen
  - DNS-A-Records auf die neue IP zeigen lassen
$( $RESET_CLUSTER && echo "  - sudo ./10-build-template.sh --addons-only" )
  - sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env && sudo nano /etc/civitas/deploy.env
  - sudo ./30-deploy-civitas.sh
------------------------------------------------------------------
EOF
