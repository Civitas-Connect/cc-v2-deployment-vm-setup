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
SKIP_K3S=false

# Teilschritte duerfen scheitern, ohne den Rest zu verhindern.
SSH_BROKEN=false
K3S_BROKEN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname) NEW_HOSTNAME="${2:?}"; shift 2 ;;
    --ip)       NEW_IP="${2:?}";       shift 2 ;;
    --gateway)  GATEWAY="${2:?}";      shift 2 ;;
    --dns)      DNS="${2:?}";          shift 2 ;;
    --iface)    IFACE="${2:?}";        shift 2 ;;
    --dhcp)     USE_DHCP=true;         shift ;;
    --check)    CHECK_ONLY=true;       shift ;;
    --skip-k3s) SKIP_K3S=true;         shift ;;
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

log "SSH pruefen"

# /run liegt auf tmpfs und ist nach jedem Boot leer. sshd legt das
# Privilege-Separation-Verzeichnis beim Start selbst an - wurde der Dienst
# nach dem Klonen aber noch nie gestartet (civitas-firstboot entfernt die
# Host-Keys, ohne sie fehlt sshd der Start), existiert es nicht, und
# "sshd -t" bricht mit "Missing privilege separation directory" ab.
install -d -m 0755 -o root -g root /run/sshd

if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  ssh-keygen -A
  ok "Host-Keys neu erzeugt"
else
  ok "Host-Keys vorhanden ($(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}'))"
fi

if /usr/sbin/sshd -t 2>/tmp/sshd-test.log; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet ssh || systemctl is-active --quiet sshd; then
    ok "sshd laeuft"
  else
    warn "sshd laeuft nicht: systemctl status ssh"
    SSH_BROKEN=true
  fi
else
  warn "sshd-Konfiguration fehlerhaft:"
  sed 's/^/      /' /tmp/sshd-test.log >&2
  SSH_BROKEN=true
fi
rm -f /tmp/sshd-test.log

# ---------------------------------------------------------------------------
# 5 – k3s auf die neue IP umstellen
# ---------------------------------------------------------------------------

k3s_diagnose() {
  warn "Haeufige Ursachen, in dieser Reihenfolge pruefen:"
  echo
  echo "  Uhrzeit  - nach einem Snapshot-Restore laeuft die Uhr oft falsch."
  echo "             k3s lehnt dann die eigenen Zertifikate ab."
  timedatectl 2>/dev/null | sed 's/^/      /'
  echo "      Zertifikat gueltig ab: $(openssl x509 -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt -noout -startdate 2>/dev/null | cut -d= -f2)"
  echo "      Reparatur bei Zukunftsdatum: sudo k3s certificate rotate"
  echo
  echo "  Platte   - ist / voll, startet kein Pod mehr."
  df -h / 2>/dev/null | sed 's/^/      /'
  echo
  echo "  Pakete   - ein abgebrochenes apt-Upgrade blockiert dpkg."
  echo "             sudo dpkg --configure -a"
  echo
  echo "  Dienst   - $(systemctl is-enabled k3s 2>/dev/null || echo unbekannt) / $(systemctl is-active k3s 2>/dev/null || echo inaktiv)"
  echo
  echo "  Letzte Meldungen:"
  journalctl -u k3s -n 25 --no-pager 2>/dev/null | sed 's/^/      /'
  echo
}

wait_api() {
  local tries=${1:-60}
  for _ in $(seq 1 "$tries"); do
    "$KUBECTL" get --raw=/readyz >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

wait_ready() {
  for _ in $(seq 1 60); do
    "$KUBECTL" get node --no-headers 2>/dev/null | grep -qw Ready && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# 5a – Systemzeit
#
# Der kritischste Schritt vor allem, was mit k3s zu tun hat. Ein Klon startet
# haeufig mit falsch gehender Uhr (Snapshot-Restore, RTC der VM). Erzeugt k3s
# in diesem Zustand Zertifikate, bekommen sie ein NotBefore in der Zukunft -
# und sobald NTP die Uhr zurueckzieht, ist der Cluster tot mit
# "certificate has expired or is not yet valid".
# ---------------------------------------------------------------------------

sync_time() {
  log "Systemzeit pruefen"
  timedatectl set-ntp true >/dev/null 2>&1 || true
  systemctl restart systemd-timesyncd >/dev/null 2>&1 || true

  for _ in $(seq 1 24); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
    sleep 5
  done

  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    ok "Uhr synchronisiert: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    return 0
  fi
  warn "Uhr ist nach 2 Minuten nicht synchronisiert ($(date -u '+%Y-%m-%d %H:%M:%S UTC'))."
  warn "Ohne korrekte Zeit erzeugt k3s unbrauchbare Zertifikate. Zeitquelle pruefen:"
  warn "  timedatectl && systemctl status systemd-timesyncd"
  return 1
}

# Liegt das NotBefore eines k3s-Zertifikats in der Zukunft, wurde es bei
# falscher Uhr erzeugt. Nur ein Rotieren hilft, ein Neustart nicht.
certs_from_the_future() {
  local crt=/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
  [[ -f "$crt" ]] || return 1
  local nb
  nb=$(openssl x509 -in "$crt" -noout -startdate 2>/dev/null | cut -d= -f2) || return 1
  [[ -n "$nb" ]] || return 1
  (( $(date -d "$nb" +%s 2>/dev/null || echo 0) > $(date +%s) ))
}

rotate_certs() {
  log "k3s-Zertifikate neu ausstellen"
  systemctl stop k3s 2>/dev/null || true
  [[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
  sleep 3
  rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
  rm -f /var/lib/rancher/k3s/agent/client-*.crt /var/lib/rancher/k3s/agent/client-*.key
  k3s certificate rotate >/dev/null 2>&1 || warn "k3s certificate rotate meldete einen Fehler."
  systemctl start k3s
  ok "rotiert"
}

if $SKIP_K3S; then
  warn "Cluster-Schritt uebersprungen (--skip-k3s)."
elif ! systemctl list-unit-files k3s.service >/dev/null 2>&1; then
  warn "k3s ist nicht installiert - Cluster-Schritt uebersprungen."
else
  sync_time || K3S_BROKEN=true

  if certs_from_the_future; then
    warn "k3s-Zertifikate wurden bei falsch gehender Uhr erzeugt und sind noch nicht gueltig."
    rotate_certs
  fi

  log "k3s auf ${CURRENT_IP} umstellen"
  echo "  Das dauert nach dem Klonen typischerweise 2-5 Minuten."

  # 20-sysprep-template.sh stoppt k3s. Ohne aktivierten Dienst kaeme der
  # Cluster nach dem Boot gar nicht hoch.
  systemctl is-enabled --quiet k3s || { systemctl enable k3s >/dev/null 2>&1 && ok "k3s-Dienst aktiviert"; }
  systemctl is-active --quiet k3s || systemctl start k3s

  if ! wait_api 60; then
    warn "k3s-API nach 5 Minuten nicht erreichbar."
    k3s_diagnose
    K3S_BROKEN=true
  else
    # Das dynamische Serverzertifikat behaelt alte IPs in den SANs. Verwerfen,
    # dann baut k3s es beim Start mit der aktuellen IP neu auf.
    "$KUBECTL" -n kube-system delete secret k3s-serving --ignore-not-found >/dev/null 2>&1 || true
    rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json

    systemctl restart k3s
    if ! wait_api 60; then
      # Haeufigster Grund an dieser Stelle: das eben neu ausgestellte
      # Serverzertifikat traegt wieder ein NotBefore aus der Zukunft.
      if certs_from_the_future; then
        rotate_certs
        wait_api 60 || true
      fi
    fi
    if ! "$KUBECTL" get --raw=/readyz >/dev/null 2>&1; then
      warn "k3s ist nach dem Neustart nicht zurueckgekommen."
      k3s_diagnose
      K3S_BROKEN=true
    else
      wait_ready || warn "Node meldet nach 5 Minuten kein Ready - kubectl describe node"

      # Pods aus dem Snapshot: ihre Container-Namen sind in containerd noch von
      # der alten Instanz reserviert, das Kubelet bleibt in CreateContainerError
      # haengen. Normalerweise erledigt das civitas-clusterfix.service beim
      # ersten Boot; auf aelteren Images gibt es den Dienst nicht.
      broken=0
      for sns in kube-system cert-manager ingress-nginx; do
        while read -r pod phase pready; do
          [[ -n "$pod" ]] || continue
          if [[ "$phase" != "Running" || "$pready" != "true" ]]; then
            echo "  ${sns}/${pod} neu erzeugen (${phase}, ready=${pready})"
            "$KUBECTL" -n "$sns" delete pod "$pod" --wait=false >/dev/null 2>&1 && broken=$((broken+1))
          fi
        done < <("$KUBECTL" -n "$sns" get pods --no-headers \
                   -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready \
                   2>/dev/null || true)
      done
      (( broken > 0 )) && ok "${broken} Pod(s) neu erzeugt" || ok "alle System-Pods laufen"

      node_ip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
      if [[ "$node_ip" != "$CURRENT_IP" ]]; then
        warn "Node-InternalIP steht auf ${node_ip:-?}, erwartet ${CURRENT_IP}. Node-Objekt wird neu registriert."
        node_name=$("$KUBECTL" get node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo civitas-node)
        "$KUBECTL" delete node "$node_name" >/dev/null 2>&1 || true
        systemctl restart k3s
        wait_api 60 && wait_ready || true
        node_ip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
      fi

      if [[ "$node_ip" == "$CURRENT_IP" ]]; then
        ok "Node-InternalIP ${node_ip}"
      else
        warn "Node-InternalIP weiterhin ${node_ip:-?} - vor 30-deploy-civitas.sh klaeren."
        K3S_BROKEN=true
      fi

      sans=$(openssl s_client -connect 127.0.0.1:6443 </dev/null 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -o 'IP Address:[0-9.]*' | cut -d: -f2 | tr '\n' ' ')
      if grep -qw "$CURRENT_IP" <<<"$sans"; then
        ok "Zertifikat enthaelt ${CURRENT_IP} (SANs: ${sans})"
      else
        warn "Zertifikat enthaelt ${CURRENT_IP} nicht (SANs: ${sans})"
      fi
    fi
  fi

  # kubectl ohne sudo: Gruppenmitgliedschaft statt Kopie. k3s setzt Modus und
  # Gruppe der kubeconfig bei jedem Start neu, das ueberlebt eine
  # Zertifikatsrotation - eine Kopie unter ~/.kube/config nicht.
  KUBE_GROUP="${KUBE_GROUP:-civitas}"
  admin="${SUDO_USER:-}"
  if [[ -n "$admin" && "$admin" != "root" ]]; then
    getent group "$KUBE_GROUP" >/dev/null || groupadd --system "$KUBE_GROUP"
    if ! id -nG "$admin" | tr ' ' '\n' | grep -qx "$KUBE_GROUP"; then
      usermod -aG "$KUBE_GROUP" "$admin"
      warn "${admin} zur Gruppe ${KUBE_GROUP} hinzugefuegt - erst nach neuer Anmeldung wirksam."
    fi
    perms=$(stat -c '%a %G' /etc/rancher/k3s/k3s.yaml 2>/dev/null || echo '?')
    if [[ "$perms" == "640 ${KUBE_GROUP}" ]]; then
      ok "kubectl ohne sudo nutzbar (kubeconfig ${perms})"
    else
      warn "kubeconfig steht auf ${perms}, erwartet 640 ${KUBE_GROUP}."
      warn "Das Image stammt aus einer aelteren Version von 10-build-template.sh."
      warn "Nachziehen: in /etc/rancher/k3s/config.yaml write-kubeconfig-mode 0640 und"
      warn "write-kubeconfig-group ${KUBE_GROUP} setzen, dann systemctl restart k3s"
    fi
    if [[ -f "$(getent passwd "$admin" | cut -d: -f6)/.kube/config" ]]; then
      warn "Es existiert noch ~/.kube/config - nach einer Rotation passt dessen CA nicht mehr."
      warn "Entfernen mit: rm ~/.kube/config"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 6 – Abschluss
# ---------------------------------------------------------------------------

show_state

echo
echo "------------------------------------------------------------------"

if $SSH_BROKEN || $K3S_BROKEN; then
  warn "Netzwerk und Hostname sind gesetzt und bleiben nach einem Neustart erhalten."
  $SSH_BROKEN && echo "  Offen: sshd. Pruefen mit: sudo systemctl status ssh"
  $K3S_BROKEN && echo "  Offen: k3s.  Pruefen mit: sudo journalctl -u k3s -n 200 --no-pager"
  echo
  echo "  Nach der Behebung dieses Skript einfach erneut aufrufen - es ist"
  echo "  idempotent und wiederholt nur, was noch fehlt."
  echo "------------------------------------------------------------------"
  exit 1
fi

cat <<EOF
Node ist personalisiert.

Gegenprobe zum Master oder anderen Klonen - diese Werte MUESSEN abweichen:
  Hostname, machine-id, SSH-Host-Key, IP, k3s Node-IP

Gleich sein DUERFEN und SOLLEN:
  Node-Name (civitas-node), Cluster-CA und Node-Token, Pod-CIDR, Image-Store

Weiter mit:
  sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
  sudo nano /etc/civitas/deploy.env
  sudo bash 30-deploy-civitas.sh

DNS-A-Records auf ${CURRENT_IP} zeigen lassen: api, idm, portal, dashboard
------------------------------------------------------------------
EOF
