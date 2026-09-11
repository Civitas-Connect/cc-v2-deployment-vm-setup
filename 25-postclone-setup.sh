#!/usr/bin/env bash
#
# 25-postclone-setup.sh
#
# Gibt einem frisch geklonten Node seine Instanz-Identitaet:
#   - Hostname und /etc/hosts
#   - feste IP ueber netplan (oder bewusst DHCP)
#   - k3s auf die neue IP umstellen: Node-InternalIP und Serverzertifikat
#   - Kontrollausgabe aller Werte, die sich zwischen Instanzen unterscheiden muessen
#
# Idempotent: mehrfaches Ausfuehren ist unproblematisch, auch mit anderen Werten.
#
# Aufruf:
#   sudo ./25-postclone-setup.sh --hostname civitas-demo1 \
#        --ip 192.168.210.101/24 --gateway 192.168.210.1 --dns 192.168.210.10,1.1.1.1
#
#   sudo ./25-postclone-setup.sh --hostname civitas-demo1 --dhcp
#   sudo ./25-postclone-setup.sh --check          # nur pruefen, nichts aendern
#
# Interface wird automatisch ermittelt; mit --iface ens3 ueberschreibbar.
#

set -uo pipefail

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

NETPLAN_FILE=/etc/netplan/10-civitas-instance.yaml
FALLBACK_FILE=/etc/netplan/01-civitas-dhcp.yaml
KUBECTL=/usr/local/bin/kubectl
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

NEW_HOSTNAME=""
NEW_IP=""
GATEWAY=""
DNS=""
IFACE=""
USE_DHCP=false
CHECK_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --ip)       NEW_IP="${2:?}";       shift 2 ;;
    --gateway)  GATEWAY="${2:?}";      shift 2 ;;
    --dns)      DNS="${2:?}";          shift 2 ;;
    --iface)    IFACE="${2:?}";        shift 2 ;;
    --dhcp)     USE_DHCP=true;         shift ;;
    --check)    CHECK_ONLY=true;       shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *)          die "Unbekannte Option: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# 0 – Zustand pruefen
# ---------------------------------------------------------------------------

if [[ -e /etc/civitas/sealed ]]; then
  die "Diese VM ist noch versiegelt. civitas-firstboot.service laeuft beim naechsten Boot - erst neu starten, dann dieses Skript."
fi

detect_iface() {
  local i
  i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
  [[ -n "$i" ]] || i=$(ip -br link show 2>/dev/null | awk '$1 ~ /^e/ && $2 == "UP" {print $1; exit}')
  [[ -n "$i" ]] || i=$(ip -br link show 2>/dev/null | awk '$1 ~ /^e/ {print $1; exit}')
  echo "$i"
}
[[ -n "$IFACE" ]] || IFACE=$(detect_iface)
[[ -n "$IFACE" ]] || die "Kein Ethernet-Interface gefunden. Mit --iface angeben. Verfuegbar:
$(ip -br link show)"
ip link show "$IFACE" >/dev/null 2>&1 || die "Interface ${IFACE} existiert nicht. Verfuegbar:
$(ip -br link show)"

primary_ip() { ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }

show_state() {
  log "Aktueller Zustand"
  printf '  Hostname     : %s\n' "$(hostnamectl --static 2>/dev/null || cat /etc/hostname)"
  printf '  machine-id   : %s\n' "$(cat /etc/machine-id 2>/dev/null)"
  printf '  Interface    : %s\n' "$IFACE"
  printf '  IP           : %s\n' "$(primary_ip)"
  if [[ -f /etc/ssh/ssh_host_ed25519_key.pub ]]; then
    printf '  SSH-Host-Key : %s\n' "$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
  else
    printf '  SSH-Host-Key : %s\n' "(fehlt)"
  fi
  local nodeip
  nodeip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  printf '  k3s Node-IP  : %s\n' "${nodeip:-(Cluster nicht erreichbar)}"
  printf '  Zertifikat   : %s\n' "$(openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
      | openssl x509 -noout -ext subjectAltName 2>/dev/null \
      | grep -o 'IP Address:[0-9.]*' | cut -d: -f2 | tr '\n' ' ' || echo '?')"
}

if $CHECK_ONLY; then
  show_state
  exit 0
fi

# ---------------------------------------------------------------------------
# 1 – Eingaben pruefen
# ---------------------------------------------------------------------------

[[ -n "$NEW_HOSTNAME" ]] || die "--hostname fehlt."
[[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
  || die "Ungueltiger Hostname: ${NEW_HOSTNAME}"

if ! $USE_DHCP; then
  [[ -n "$NEW_IP" ]]   || die "--ip fehlt (oder --dhcp verwenden)."
  [[ -n "$GATEWAY" ]]  || die "--gateway fehlt."
  [[ "$NEW_IP" == */* ]] || die "--ip braucht eine Praefixlaenge, z.B. 192.168.210.101/24"
  [[ "${NEW_IP%%/*}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Ungueltige IP: ${NEW_IP}"
  [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]      || die "Ungueltiges Gateway: ${GATEWAY}"
  [[ -n "$DNS" ]] || { DNS="$GATEWAY"; warn "--dns nicht gesetzt, es wird ${GATEWAY} verwendet."; }

  TARGET_IP="${NEW_IP%%/*}"
  # IP-Konflikt vorab erkennen: antwortet die Adresse schon, gehoert sie jemand anderem.
  if [[ "$TARGET_IP" != "$(primary_ip)" ]] && ping -c1 -W1 "$TARGET_IP" >/dev/null 2>&1; then
    die "${TARGET_IP} antwortet bereits im Netz - vermutlich der Master oder ein anderer Klon."
  fi
else
  TARGET_IP=""
fi

OLD_IP=$(primary_ip)

# ---------------------------------------------------------------------------
# 2 – Hostname
# ---------------------------------------------------------------------------

log "Hostname auf ${NEW_HOSTNAME} setzen"
hostnamectl set-hostname "$NEW_HOSTNAME"
sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >>/etc/hosts
ok "gesetzt"

# ---------------------------------------------------------------------------
# 3 – Netzwerk
# ---------------------------------------------------------------------------

if $USE_DHCP; then
  log "Netzwerk auf DHCP belassen"
  rm -f "$NETPLAN_FILE"
  [[ -f "$FALLBACK_FILE" ]] || die "Weder Instanzkonfiguration noch DHCP-Fallback vorhanden."
else
  log "Netplan schreiben: ${IFACE} -> ${NEW_IP} via ${GATEWAY}"
  dns_list=""
  IFS=',' read -ra dns_arr <<<"$DNS"
  for d in "${dns_arr[@]}"; do
    d="${d// /}"
    [[ -n "$d" ]] || continue
    [[ -n "$dns_list" ]] && dns_list+=$'\n'
    dns_list+="          - ${d}"
  done

  cat >"$NETPLAN_FILE" <<EOF
# Von 25-postclone-setup.sh erzeugt. Wird von civitas-firstboot beim
# Klonen entfernt, damit kein IP-Konflikt entsteht.
network:
  version: 2
  ethernets:
    ${IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${NEW_IP}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
${dns_list}
EOF
  chmod 0600 "$NETPLAN_FILE"

  # Fallback entfernen, sonst wuerde er zusaetzlich eine DHCP-Adresse ziehen.
  rm -f "$FALLBACK_FILE"

  if ! netplan generate; then
    warn "netplan generate ist fehlgeschlagen - Konfiguration wird zurueckgenommen."
    rm -f "$NETPLAN_FILE"
    netplan generate || true
    die "Netplan-Konfiguration ungueltig, es wurde nichts angewendet."
  fi

  log "netplan apply"
  warn "Wenn du ueber SSH auf der alten IP (${OLD_IP:-?}) verbunden bist, bricht die Sitzung jetzt ab."
  netplan apply
  sleep 5

  for _ in $(seq 1 12); do
    [[ "$(primary_ip)" == "$TARGET_IP" ]] && break
    sleep 2
  done
  [[ "$(primary_ip)" == "$TARGET_IP" ]] \
    || die "IP wurde nicht uebernommen (aktuell: $(primary_ip)). Konsole pruefen: ip -br addr"
  ok "${TARGET_IP} aktiv"

  if ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
    ok "Gateway ${GATEWAY} erreichbar"
  else
    warn "Gateway ${GATEWAY} antwortet nicht auf ping - kann an einer Firewall liegen."
  fi
fi

CURRENT_IP=$(primary_ip)

# ---------------------------------------------------------------------------
# 4 – SSH-Host-Keys sicherstellen
# ---------------------------------------------------------------------------

log "SSH-Host-Keys pruefen"
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  ssh-keygen -A
  sshd -t || die "sshd-Konfiguration fehlerhaft."
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  ok "neu erzeugt"
else
  ok "vorhanden ($(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}'))"
fi

# ---------------------------------------------------------------------------
# 5 – k3s auf die neue IP umstellen
# ---------------------------------------------------------------------------

if systemctl list-unit-files k3s.service >/dev/null 2>&1; then
  log "k3s auf ${CURRENT_IP} umstellen"

  systemctl is-active --quiet k3s || systemctl start k3s

  wait_api() {
    for _ in $(seq 1 60); do
      "$KUBECTL" get --raw=/readyz >/dev/null 2>&1 && return 0
      sleep 5
    done
    return 1
  }
  wait_api || die "k3s-API nicht erreichbar. journalctl -u k3s -n 200"

  # Das dynamische Serverzertifikat behaelt alte IPs in den SANs. Verwerfen,
  # dann baut k3s es beim Start mit der aktuellen IP neu auf.
  "$KUBECTL" -n kube-system delete secret k3s-serving --ignore-not-found >/dev/null 2>&1 || true
  rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json

  systemctl restart k3s
  wait_api || die "k3s ist nach dem Neustart nicht zurueckgekommen. journalctl -u k3s -n 200"

  for _ in $(seq 1 36); do
    "$KUBECTL" get node --no-headers 2>/dev/null | grep -qw Ready && break
    sleep 5
  done

  node_ip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  if [[ "$node_ip" != "$CURRENT_IP" ]]; then
    warn "Node-InternalIP steht auf ${node_ip:-?}, erwartet ${CURRENT_IP}. Node-Objekt wird neu registriert."
    node_name=$("$KUBECTL" get node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo civitas-node)
    "$KUBECTL" delete node "$node_name" >/dev/null 2>&1 || true
    systemctl restart k3s
    wait_api || die "k3s ist nicht zurueckgekommen."
    for _ in $(seq 1 36); do
      "$KUBECTL" get node --no-headers 2>/dev/null | grep -qw Ready && break
      sleep 5
    done
    node_ip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  fi
  [[ "$node_ip" == "$CURRENT_IP" ]] && ok "Node-InternalIP ${node_ip}" \
    || warn "Node-InternalIP weiterhin ${node_ip:-?} - vor 30-deploy-civitas.sh klaeren."

  sans=$(openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
    | openssl x509 -noout -ext subjectAltName 2>/dev/null \
    | grep -o 'IP Address:[0-9.]*' | cut -d: -f2 | tr '\n' ' ')
  if grep -qw "$CURRENT_IP" <<<"$sans"; then
    ok "Zertifikat enthaelt ${CURRENT_IP} (SANs: ${sans})"
  else
    warn "Zertifikat enthaelt ${CURRENT_IP} nicht (SANs: ${sans})"
  fi

  # kubeconfig fuer den aufrufenden Benutzer auffrischen
  admin="${SUDO_USER:-}"
  if [[ -n "$admin" && "$admin" != "root" ]]; then
    home=$(getent passwd "$admin" | cut -d: -f6)
    if [[ -n "$home" ]]; then
      install -d -o "$admin" -g "$admin" -m 0700 "${home}/.kube"
      install -o "$admin" -g "$admin" -m 0600 /etc/rancher/k3s/k3s.yaml "${home}/.kube/config"
      ok "kubeconfig fuer ${admin} aktualisiert"
    fi
  fi
else
  warn "k3s ist nicht installiert - Cluster-Schritt uebersprungen."
fi

# ---------------------------------------------------------------------------
# 6 – Abschluss
# ---------------------------------------------------------------------------

show_state

cat <<EOF

------------------------------------------------------------------
Node ist personalisiert.

Gegenprobe zum Master oder anderen Klonen - diese Werte MUESSEN abweichen:
  Hostname, machine-id, SSH-Host-Key, IP, k3s Node-IP

Gleich sein DUERFEN und SOLLEN:
  Node-Name (civitas-node), Cluster-CA und Node-Token, Pod-CIDR, Image-Store

Weiter mit:
  sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
  sudo nano /etc/civitas/deploy.env
  sudo ./30-deploy-civitas.sh

DNS-A-Records auf ${CURRENT_IP} zeigen lassen: api, idm, portal, dashboard
------------------------------------------------------------------
EOF
