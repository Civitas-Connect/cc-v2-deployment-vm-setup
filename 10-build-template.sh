#!/usr/bin/env bash
#
# 10-build-template.sh
#
# Baut aus einer leeren Ubuntu-24.04-VM eine geklont-fähige CIVITAS/CORE-V2-Basis:
#   - Härtung (unattended-upgrades, SSH, ufw, fail2ban)
#   - k3s als Single-Node-Cluster mit FESTEM Node-Namen (überlebt Hostname-/IP-Wechsel)
#   - ingress-nginx (DaemonSet + hostNetwork) und cert-manager
#   - Tooling (helm, helmfile, helm-diff, k9s, jq, git)
#   - civitas-core-deployment-Repo auf festem Tag + optionales Vorziehen aller Images
#   - civitas-firstboot.service: erzeugt in jedem Klon beim ersten Boot eine
#     frische Maschinenidentitaet (machine-id, SSH-Host-Keys, k3s-Serverzertifikat)
#   - civitas-clusterfix.service: erzeugt danach die Pods neu, deren
#     Container-Namen aus dem Snapshot noch in containerd reserviert sind
#   - DHCP-Fallback im Netz, damit ein Klon ohne Konsolenzugriff online kommt
#
# Es wird bewusst KEIN ClusterIssuer, KEIN Namespace und KEIN CIVITAS-Deployment angelegt.
# Alles Domain- und IP-abhängige passiert erst in 30-deploy-civitas.sh nach dem Klonen.
#
# Aufruf:
#   sudo ./10-build-template.sh                 # kompletter Build
#   sudo ./10-build-template.sh --addons-only   # nur ingress-nginx + cert-manager + StorageClasses
#                                               # (nach einem Sysprep mit --reset-cluster)
#


# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

# Leer lassen = aktueller stable-Channel. Fuer reproduzierbare Images nach dem
# ersten Build die in /etc/civitas/template.env protokollierte Version eintragen.
K3S_VERSION="${K3S_VERSION:-}"                     # z.B. "v1.33.4+k3s1"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-}"   # z.B. "v1.17.2", leer = latest
INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-}"  # z.B. "4.12.1", leer = latest
HELMFILE_VERSION="${HELMFILE_VERSION:-1.7.2}"

# Fester Node-Name: entkoppelt die Cluster-Identitaet vom Hostnamen.
# Ohne das registriert sich jeder Klon als neuer Node und der alte bleibt als
# NotReady im Datastore liegen.
NODE_NAME="${NODE_NAME:-civitas-node}"

# Pod-/Service-CIDR von k3s (Defaults). Muessen in der Firewall freigegeben werden.
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"

# CIVITAS-Deployment-Repo
CIVITAS_REPO="${CIVITAS_REPO:-https://gitlab.com/civitas-connect/civitas-core/civitas-core-v2/civitas-core-deployment.git}"
CIVITAS_TAG="${CIVITAS_TAG:-v2.0.0}"
CIVITAS_DIR="/opt/civitas/civitas-core-deployment"

# Images des CIVITAS-Stacks schon im Template vorziehen. Groesster Zeitgewinn
# nach dem Klonen, macht das Deployment unabhaengig von Registry-Rate-Limits.
PREPULL_IMAGES="${PREPULL_IMAGES:-true}"

# Optional: kubectl-Zugriff von aussen auf Port 6443 fuer genau eine IP.
# Leer lassen = 6443 bleibt komplett zu (empfohlen).
API_ALLOW_FROM="${API_ALLOW_FROM:-}"

# SSH-Port (falls abweichend, hier UND in der Hoster-Firewall anpassen)
SSH_PORT="${SSH_PORT:-22}"

ADDONS_ONLY=false
[[ "${1:-}" == "--addons-only" ]] && ADDONS_ONLY=true

# ---------------------------------------------------------------------------
# Helfer
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

KUBE_GROUP="${KUBE_GROUP:-civitas}"
ADMIN_USER="${SUDO_USER:-root}"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
[[ -n "$ADMIN_HOME" ]] || die "Home-Verzeichnis von $ADMIN_USER nicht gefunden."

KUBECTL="/usr/local/bin/kubectl"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

wait_for_rollout() {  # ns, kind/name, timeout
  "$KUBECTL" -n "$1" rollout status "$2" --timeout="${3:-300s}"
}

# ---------------------------------------------------------------------------
# 0 – Preflight
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "Preflight"
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Nicht-Ubuntu-System erkannt (${ID:-?}), Skript ist auf 24.04 ausgelegt."
  [[ "${VERSION_ID:-}" == "24.04" ]] || warn "Erwartet wurde Ubuntu 24.04, gefunden ${VERSION_ID:-?}."
  [[ "$(uname -m)" == "x86_64" || "$(uname -m)" == "aarch64" ]] || die "Nicht unterstuetzte Architektur."

  mem_gb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  (( mem_gb >= 15 )) || warn "Nur ${mem_gb} GB RAM. Fuer den vollen V2-Stack sind >= 16 GB noetig."

  disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  (( disk_gb >= 40 )) || warn "Nur ${disk_gb} GB frei auf /. Mit vorgezogenen Images werden ~25 GB gebraucht."

  timedatectl show -p NTPSynchronized --value | grep -q yes \
    || warn "Zeit ist nicht per NTP synchronisiert - das bricht spaeter TLS und Token-Validierung."
fi

# ---------------------------------------------------------------------------
# 1 – Grundsystem
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  # apt-get upgrade laeuft je nach Update-Rueckstand viele Minuten ohne Ausgabe.
# Reisst dabei die SSH-Sitzung ab, bleibt dpkg auf halbem Weg stehen.
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]]; then
  warn "Der Lauf haengt an dieser SSH-Sitzung. Reisst sie ab, bleibt dpkg auf halbem Weg stehen."
  warn "Empfehlung: abbrechen und in 'tmux' oder 'screen' erneut starten."
  read -r -p "Trotzdem fortfahren? [ja/NEIN] " a
  [[ "$a" == "ja" ]] || die "Abgebrochen."
fi

log "Gruppe ${KUBE_GROUP} fuer kubectl-Zugriff"
getent group "$KUBE_GROUP" >/dev/null || groupadd --system "$KUBE_GROUP"
if [[ "$ADMIN_USER" != "root" ]] && ! id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx "$KUBE_GROUP"; then
  usermod -aG "$KUBE_GROUP" "$ADMIN_USER"
  warn "${ADMIN_USER} wurde der Gruppe ${KUBE_GROUP} hinzugefuegt - erst nach einer neuen Anmeldung wirksam."
fi
echo "  ${KUBE_GROUP}: $(getent group "$KUBE_GROUP" | cut -d: -f4)"

log "Grundsystem und Basis-Pakete"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get upgrade -y -qq
  apt-get install -y -qq \
    ca-certificates curl wget gnupg jq git tar unzip \
    apt-transport-https software-properties-common \
    open-iscsi nfs-common

  log "Swap deaktivieren"
  swapoff -a || true
  sed -i.bak '/\sswap\s/ s/^\([^#]\)/#\1/' /etc/fstab

  log "Kernel-Module und sysctl"
  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay || true
  modprobe br_netfilter || true

  cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
fs.inotify.max_user_instances       = 512
fs.inotify.max_user_watches         = 524288
vm.max_map_count                    = 262144
EOF
  sysctl --system >/dev/null
fi

# ---------------------------------------------------------------------------
# 2 – Haertung (wandert vollstaendig ins Image, der Klon muss nichts mehr tun)
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "Automatische Sicherheitsupdates"
  apt-get install -y -qq unattended-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >/etc/apt/apt.conf.d/51-civitas-unattended <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:30";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  systemctl enable --now unattended-upgrades

  log "SSH haerten"
  # Praefix 00-: in sshd gewinnt der zuerst gelesene Wert. cloud-init schreibt
  # 50-cloud-init.conf mit PasswordAuthentication yes - das wuerde sonst gewinnen.
  cat >/etc/ssh/sshd_config.d/00-civitas-hardening.conf <<EOF
Port ${SSH_PORT}
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  # /run liegt auf tmpfs und ist nach jedem Boot leer. sshd legt das
  # Privilege-Separation-Verzeichnis beim Start selbst an - wurde der Dienst
  # seit dem Boot nie gestartet (nach civitas-firstboot fehlen die Host-Keys,
  # ohne sie startet sshd nicht), existiert es nicht, und "sshd -t" bricht mit
  # "Missing privilege separation directory" ab.
  install -d -m 0755 -o root -g root /run/sshd
  ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A

  /usr/sbin/sshd -t || die "sshd-Konfiguration ist fehlerhaft, Abbruch bevor der Zugang kaputtgeht."
  systemctl restart ssh

  if [[ ! -s "${ADMIN_HOME}/.ssh/authorized_keys" && "$ADMIN_USER" != "root" ]]; then
    warn "Keine authorized_keys fuer ${ADMIN_USER} gefunden. Vor dem Sysprep unbedingt einen Key hinterlegen."
  fi

  log "Firewall (ufw)"
  apt-get install -y -qq ufw
  # Pflicht fuer Kubernetes: ufw setzt FORWARD sonst auf DROP und der Pod-Traffic
  # stirbt. Typisches Symptom: Admission-Webhooks laufen in "context deadline exceeded".
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${SSH_PORT}"/tcp comment 'SSH'
  ufw allow 80/tcp   comment 'HTTP / ACME HTTP-01'
  ufw allow 443/tcp  comment 'HTTPS'
  ufw allow from "$POD_CIDR" comment 'k3s pods'
  ufw allow from "$SVC_CIDR" comment 'k3s services'
  ufw allow in on cni0 comment 'k3s CNI'
  if [[ -n "$API_ALLOW_FROM" ]]; then
    ufw allow from "$API_ALLOW_FROM" to any port 6443 proto tcp comment 'kube-apiserver (eingeschraenkt)'
  fi
  ufw --force enable

  log "fail2ban"
  apt-get install -y -qq fail2ban
  cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 ${POD_CIDR} ${SVC_CIDR}

[sshd]
enabled  = true
backend  = systemd
port     = ${SSH_PORT}
maxretry = 5
bantime  = 1h
findtime = 10m

[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
bantime   = 1w
findtime  = 1d
maxretry  = 3
EOF
  systemctl enable --now fail2ban
fi

# ---------------------------------------------------------------------------
# 2b – Klon-Automatik
#
# Das Image traegt alles, was ein Klon zum Selbststart braucht:
#   - DHCP-Fallback, damit jeder Klon ohne Konsole online kommt
#   - cloud-init schreibt keine Netzwerkkonfiguration mehr (Nutanix AHV liefert
#     je nach Vorlage eine aus, die sonst mit 25-postclone-setup.sh kollidiert)
#   - civitas-firstboot.service erzeugt beim ersten Boot eines versiegelten
#     Images eine frische Maschinenidentitaet und startet danach neu
#
# Dadurch muss 20-sysprep-template.sh die Identitaet NICHT mehr loeschen -
# und genau deshalb darf der Master weiterlaufen und live gesnapshottet werden.
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "Netz-Fallback fuer Klone (DHCP)"
  # Niedrige Nummer = verliert gegen die Instanzkonfiguration aus
  # 25-postclone-setup.sh (10-civitas-instance.yaml) und gegen cloud-init (50-).
  # Auf der Build-VM aendert sich dadurch nichts, es wird kein netplan apply
  # ausgefuehrt.
  cat >/etc/netplan/01-civitas-dhcp.yaml <<'EOF'
# Fallback aus dem CIVITAS-Template. Greift nur, wenn keine Instanz-
# konfiguration vorhanden ist - also unmittelbar nach dem Klonen.
network:
  version: 2
  ethernets:
    civitas-fallback:
      match:
        name: "e*"
      dhcp4: true
      dhcp6: false
      optional: true
EOF
  chmod 0600 /etc/netplan/01-civitas-dhcp.yaml
  netplan generate || warn "netplan generate meldet Fehler - 01-civitas-dhcp.yaml pruefen."

  log "Zeitsynchronisation sicherstellen"
  # Ohne verlaessliche Uhr erzeugt k3s im Klon Zertifikate mit einem NotBefore
  # in der Zukunft. Zieht NTP die Uhr spaeter zurueck, ist der Cluster tot.
  systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
  timedatectl set-ntp true >/dev/null 2>&1 || true
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    echo "  Uhr synchronisiert: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  else
    warn "Uhr ist nicht synchronisiert. Vor dem Versiegeln klaeren, sonst erben alle Klone das Problem."
  fi

  log "cloud-init-Netzwerkkonfiguration abschalten"
  mkdir -p /etc/cloud/cloud.cfg.d
  echo 'network: {config: disabled}' >/etc/cloud/cloud.cfg.d/99-civitas-disable-network.cfg

  log "civitas-firstboot installieren"
  mkdir -p /etc/civitas
  cat >/usr/local/sbin/civitas-firstboot.sh <<'EOF'
#!/usr/bin/env bash
#
# Laeuft sehr frueh im Boot, bevor sshd und k3s starten, und nur dann, wenn
# /etc/civitas/sealed existiert - also beim ersten Boot eines frisch
# geklonten (oder frisch versiegelten) Images.
#
# Aufgabe: alles loeschen, was pro Maschine einzigartig sein muss. Der
# anschliessende Neustart laesst systemd, sshd und k3s die Werte sauber neu
# erzeugen. Ein fruehes Loeschen im laufenden Betrieb (klassischer Sysprep)
# waere hier nicht moeglich, weil der Master fuer den Snapshot laufen muss.
#
set -uo pipefail

SEAL=/etc/civitas/sealed
[[ -e "$SEAL" ]] || exit 0

say() { echo "civitas-firstboot: $*" >&2; }
say "versiegeltes Image erkannt, Maschinenidentitaet wird neu erzeugt"

# --- SSH-Host-Keys ---------------------------------------------------------
rm -f /etc/ssh/ssh_host_*

# --- machine-id ------------------------------------------------------------
# Leere Datei: systemd erzeugt beim naechsten Boot eine neue ID.
: >/etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# --- Netz und Hostname -----------------------------------------------------
# Die Instanzkonfiguration des Masters darf nicht mit in den Klon, sonst gibt
# es einen IP-Konflikt. Der DHCP-Fallback (01-) bleibt liegen.
rm -f /etc/netplan/10-civitas-instance.yaml /etc/netplan/50-cloud-init.yaml
echo civitas-unconfigured >/etc/hostname
if [[ -w /etc/hosts ]]; then
  sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
  printf '127.0.1.1\tcivitas-unconfigured\n' >>/etc/hosts
fi

# --- k3s -------------------------------------------------------------------
# Das dynamische Serverzertifikat traegt die alte Node-IP in den SANs.
# Nach dem Loeschen baut k3s es beim Start neu auf.
rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
rm -rf /var/log/pods/* /var/log/containers/*

# --- cloud-init ------------------------------------------------------------
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init clean --logs >/dev/null 2>&1 || true
fi
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/* 2>/dev/null || true

# Ohne DHCP im Segment steht der Klon nach dem Boot ohne Adresse da. Damit
# derjenige an der Hypervisor-Konsole nicht suchen muss, steht der noetige
# Befehl direkt ueber dem Login-Prompt.
cat >/etc/issue <<'ISSUE'

  CIVITAS-Klon, noch nicht personalisiert.

  Netzwerk und Hostname setzen:
    sudo bash /opt/civitas/scripts/25-postclone-setup.sh          --hostname <name> --ip <adresse>/24 --gateway <gw> --dns <resolver>

  Alles in EINER Zeile eingeben.

ISSUE

# Beim naechsten Boot raeumt civitas-clusterfix die Pods auf, die aus dem
# Snapshot stammen. Ihre Container-Namen sind in containerd noch von der alten
# Instanz reserviert, das Kubelet scheitert sonst endlos mit
#   failed to reserve container name ... is reserved for <container-id>
# und der Pod bleibt in CreateContainerError haengen.
touch /etc/civitas/clusterfix-pending

rm -f "$SEAL"
say "fertig, Neustart"
systemctl reboot
EOF
  chmod 0755 /usr/local/sbin/civitas-firstboot.sh

  cat >/etc/systemd/system/civitas-firstboot.service <<'EOF'
[Unit]
Description=CIVITAS: Erstboot nach dem Klonen (Maschinenidentitaet neu erzeugen)
Documentation=file:///usr/local/sbin/civitas-firstboot.sh
ConditionPathExists=/etc/civitas/sealed
# Bewusst sehr frueh: vor sshd (alte Host-Keys) und vor k3s (alte Node-IP).
DefaultDependencies=no
After=systemd-remount-fs.service
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/civitas-firstboot.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=sysinit.target
EOF
  cat >/usr/local/sbin/civitas-clusterfix.sh <<'EOF'
#!/usr/bin/env bash
#
# Laeuft einmalig beim ersten Boot eines Klons, nachdem civitas-firstboot die
# Identitaet erneuert hat und k3s wieder gestartet ist.
#
# Aufgabe: Pods entfernen, die aus dem Snapshot stammen. Der Sysprep stoppt
# k3s, aber die containerd-Metadaten der damals laufenden Container wandern mit
# ins Image. Im Klon kollidiert dann das alte Pod-Objekt mit der noch
# reservierten Container-Namensvergabe, und das Kubelet versucht endlos:
#   Error: failed to reserve container name "..."; check if another
#   CreateContainer request is in progress: name "..." is reserved for "..."
# Ein Loeschen des Pods erzeugt eine neue UID und damit einen neuen Namen.
#
set -uo pipefail

MARKER=/etc/civitas/clusterfix-pending
[[ -e "$MARKER" ]] || exit 0

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL=/usr/local/bin/kubectl
say() { echo "civitas-clusterfix: $*" >&2; }

# Auf die API warten - beim ersten Boot dauert der Start laenger als sonst.
ready=false
for _ in $(seq 1 120); do
  "$KUBECTL" get --raw=/readyz >/dev/null 2>&1 && { ready=true; break; }
  sleep 5
done
if ! $ready; then
  say "k3s-API nach 10 Minuten nicht erreichbar, Marke bleibt fuer den naechsten Boot"
  exit 0
fi

# Den Pods eine faire Chance geben, von selbst hochzukommen.
sleep 60

fixed=0
for ns in kube-system cert-manager ingress-nginx; do
  while read -r pod phase ready_state; do
    [[ -n "$pod" ]] || continue
    # Alles anfassen, was nicht laeuft oder nicht bereit ist. Laufende,
    # gesunde Pods bleiben unberuehrt - ein pauschales Loeschen waere
    # unnoetig teuer.
    if [[ "$phase" != "Running" || "$ready_state" != "true" ]]; then
      say "loesche ${ns}/${pod} (${phase}, ready=${ready_state})"
      "$KUBECTL" -n "$ns" delete pod "$pod" --wait=false >/dev/null 2>&1 && fixed=$((fixed+1))
    fi
  done < <("$KUBECTL" -n "$ns" get pods --no-headers              -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready              2>/dev/null || true)
done

say "${fixed} Pod(s) neu erzeugt"
rm -f "$MARKER"
EOF
  chmod 0755 /usr/local/sbin/civitas-clusterfix.sh

  cat >/etc/systemd/system/civitas-clusterfix.service <<'EOF'
[Unit]
Description=CIVITAS: Pods aus dem Snapshot nach dem Klonen neu erzeugen
Documentation=file:///usr/local/sbin/civitas-clusterfix.sh
ConditionPathExists=/etc/civitas/clusterfix-pending
After=k3s.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/civitas-clusterfix.sh
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable civitas-firstboot.service >/dev/null
  systemctl enable civitas-clusterfix.service >/dev/null
  echo "  civitas-firstboot.service aktiviert (greift nur bei /etc/civitas/sealed)"
  echo "  civitas-clusterfix.service aktiviert (greift beim ersten Boot danach)"
fi

# ---------------------------------------------------------------------------
# 3 – Tooling
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "helm, helmfile, helm-diff, k9s"
  ARCH=$([[ "$(uname -m)" == "aarch64" ]] && echo arm64 || echo amd64)

  if ! command -v helm >/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  if ! command -v helmfile >/dev/null; then
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/hf.tgz" \
      "https://github.com/helmfile/helmfile/releases/download/v${HELMFILE_VERSION}/helmfile_${HELMFILE_VERSION}_linux_${ARCH}.tar.gz"
    tar -xzf "$tmp/hf.tgz" -C "$tmp" helmfile
    install -m 0755 "$tmp/helmfile" /usr/local/bin/helmfile
    rm -rf "$tmp"
  fi

  # helm-diff wird von helmfile benoetigt - fuer root UND den Admin-User,
  # weil Plugins pro Benutzer im HELM_DATA_HOME liegen.
  for u in root "$ADMIN_USER"; do
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -n "$home" ]] || continue
    if [[ ! -d "${home}/.local/share/helm/plugins/helm-diff" ]]; then
      sudo -u "$u" -H helm plugin install https://github.com/databus23/helm-diff >/dev/null 2>&1 || \
        warn "helm-diff konnte fuer ${u} nicht installiert werden."
    fi
  done

  if ! command -v k9s >/dev/null; then
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/k9s.deb" \
      "https://github.com/derailed/k9s/releases/latest/download/k9s_linux_${ARCH}.deb" \
      && apt-get install -y -qq "$tmp/k9s.deb" || warn "k9s-Installation uebersprungen."
    rm -rf "$tmp"
  fi
fi

# ---------------------------------------------------------------------------
# 4 – k3s
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "k3s installieren"
  mkdir -p /etc/rancher/k3s

  # Bewusst OHNE --cluster-init: der eingebettete SQLite-Datastore enthaelt
  # keine Node-IP. etcd wuerde die IP festschreiben und den Klon zerlegen.
  cat >/etc/rancher/k3s/config.yaml <<EOF
# Fester Node-Name -> Hostname des Klons ist frei waehlbar
node-name: "${NODE_NAME}"

# Traefik raus: CIVITAS erwartet ingressClass nginx
# servicelb raus: ingress-nginx laeuft als DaemonSet mit hostNetwork
disable:
  - traefik
  - servicelb

# NetworkPolicies sind im V2-Deployment deaktiviert
disable-network-policy: true

# 0640 plus Gruppe statt 0600: Mitglieder der Gruppe koennen kubectl ohne
# sudo benutzen, ohne dass die Datei fuer alle lesbar wird. k3s setzt Modus
# und Gruppe bei jedem Start neu - das ueberlebt auch eine Zertifikatsrotation,
# anders als eine Kopie unter ~/.kube/config.
write-kubeconfig-mode: "0640"
write-kubeconfig-group: "civitas"
kubelet-arg:
  - "image-gc-high-threshold=80"
  - "image-gc-low-threshold=70"
EOF

  INSTALL_ARGS=()
  # Bei einer bereits installierten Instanz greift die geaenderte config.yaml
  # erst nach einem Neustart des Dienstes.
  NEEDS_K3S_RESTART=false
  systemctl is-active --quiet k3s && NEEDS_K3S_RESTART=true
  if [[ -n "$K3S_VERSION" ]]; then
    export INSTALL_K3S_VERSION="$K3S_VERSION"
  else
    export INSTALL_K3S_CHANNEL="stable"
  fi
  curl -sfL https://get.k3s.io | sh -s - server "${INSTALL_ARGS[@]}"
  if $NEEDS_K3S_RESTART; then
    systemctl restart k3s
    for _ in $(seq 1 60); do
      [[ "$(stat -c '%a %G' /etc/rancher/k3s/k3s.yaml 2>/dev/null)" == "640 ${KUBE_GROUP}" ]] && break
      sleep 5
    done
  fi
  echo "  kubeconfig: $(stat -c '%a %U:%G' /etc/rancher/k3s/k3s.yaml 2>/dev/null)"

  systemctl enable k3s
  log "Warte auf Node Ready"
  for _ in $(seq 1 60); do
    if "$KUBECTL" get node "$NODE_NAME" 2>/dev/null | grep -qw Ready; then break; fi
    sleep 5
  done
  "$KUBECTL" get node -o wide || die "k3s ist nicht hochgekommen. Logs: journalctl -u k3s -n 200"

  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >/etc/profile.d/kubeconfig.sh
  chmod 0644 /etc/profile.d/kubeconfig.sh
fi

# Eine alte Kopie wuerde gegen die Gruppenloesung arbeiten: nach einer
# Zertifikatsrotation passt ihre CA nicht mehr, und die Fehlermeldung fuehrt
# in die Irre.
if [[ -f "${ADMIN_HOME}/.kube/config" ]]; then
  mv "${ADMIN_HOME}/.kube/config" "${ADMIN_HOME}/.kube/config.bak-$(date +%Y%m%d)"
  echo "  veraltete ~/.kube/config nach .bak verschoben"
fi

# ---------------------------------------------------------------------------
# 5 – Addons: StorageClasses, ingress-nginx, cert-manager
# ---------------------------------------------------------------------------

log "StorageClasses"
# k3s bringt local-path bereits als Default mit. Die Aliase rwo/rwx/loc
# existieren, damit auch eine global.yaml funktioniert, die explizite
# StorageClass-Namen setzt (wie in der Nutanix-Instanz).
for sc in rwo rwx loc; do
  cat <<EOF | "$KUBECTL" apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${sc}
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
done
"$KUBECTL" get storageclass

log "ingress-nginx"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null
ING_ARGS=()
[[ -n "$INGRESS_NGINX_CHART_VERSION" ]] && ING_ARGS+=(--version "$INGRESS_NGINX_CHART_VERSION")
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  "${ING_ARGS[@]}" \
  --set controller.kind=DaemonSet \
  --set controller.hostNetwork=true \
  --set controller.service.type=ClusterIP \
  --set controller.dnsPolicy=ClusterFirstWithHostNet \
  --set controller.ingressClassResource.default=true \
  --set controller.config.use-forwarded-headers=true \
  --set controller.admissionWebhooks.enabled=true \
  --wait --timeout 10m
wait_for_rollout ingress-nginx daemonset/ingress-nginx-controller 300s

log "cert-manager"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
CM_ARGS=()
[[ -n "$CERT_MANAGER_VERSION" ]] && CM_ARGS+=(--version "$CERT_MANAGER_VERSION")
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  "${CM_ARGS[@]}" \
  --set crds.enabled=true \
  --wait --timeout 10m
wait_for_rollout cert-manager deployment/cert-manager 300s

# Kein ClusterIssuer hier - der braucht eine E-Mail-Adresse und wird pro
# Instanz in 30-deploy-civitas.sh angelegt.

# ---------------------------------------------------------------------------
# 6 – CIVITAS-Repo und Images vorziehen
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "civitas-core-deployment auf Tag ${CIVITAS_TAG} klonen"
  mkdir -p /opt/civitas
  if [[ -d "$CIVITAS_DIR/.git" ]]; then
    git -C "$CIVITAS_DIR" fetch --all --tags --quiet
  else
    git clone --quiet "$CIVITAS_REPO" "$CIVITAS_DIR"
    git -C "$CIVITAS_DIR" fetch --all --tags --quiet
  fi
  git -C "$CIVITAS_DIR" checkout --quiet "$CIVITAS_TAG"

  log "ISRG Root X1 ablegen (Truststore fuer NiFi)"
  curl -fsSL -o /opt/civitas/isrg-root-x1.pem https://letsencrypt.org/certs/isrgrootx1.pem \
    || warn "ISRG-Root konnte nicht geladen werden - vor dem Deployment nachholen."

  log "Vorlage fuer die Deployment-Konfiguration"
  mkdir -p /etc/civitas
  cat >/etc/civitas/deploy.env.example <<'CIVITASENV'
# =============================================================================
# deploy.env.example  –  Konfiguration einer CIVITAS/CORE-V2-Instanz
# =============================================================================
#
# Wird von 30-deploy-civitas.sh gelesen. Auf dem Klon kopieren und ausfuellen:
#
#   sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
#   sudo nano /etc/civitas/deploy.env
#   sudo chmod 600 /etc/civitas/deploy.env
#
# Voraussetzung: der Node ist bereits personalisiert
# (sudo bash 25-postclone-setup.sh --hostname ... --ip ...).
#
# ACHTUNG: /etc/civitas/deploy.env enthaelt Zugangsdaten. Die Datei wird von
# 20-sysprep-template.sh geloescht und gehoert nicht ins Image und nicht ins
# Git-Repo.
#
# Syntax: KEY=wert, eine Zuweisung pro Zeile, keine Leerzeichen um das =.
# Werte mit Sonderzeichen in doppelte Anfuehrungszeichen setzen.
# =============================================================================


# -----------------------------------------------------------------------------
# Pflicht
# -----------------------------------------------------------------------------

# Basis-Domain der Instanz. Darunter muessen mindestens diese A-Records auf die
# Node-IP zeigen:  api, idm, portal, dashboard, management
# 30-deploy-civitas.sh prueft das vorab per getent und warnt bei Abweichungen.
DOMAIN=demo.civitascore.de

# Kurzname der Instanz. Wird gleichzeitig als Kubernetes-Namespace und als
# Keycloak-Realm verwendet. Nur Kleinbuchstaben, Ziffern und Bindestriche.
# Muss sich zwischen Instanzen unterscheiden, sonst kollidieren die Realms.
INSTANCE_SLUG=demo

# Erster Benutzer im Keycloak-Realm. Bekommt die Einladungsmail und damit die
# Administrationsrechte im Portal. Ohne funktionierendes SMTP kommt diese Mail
# nicht an - dann das Passwort spaeter ueber die Keycloak-Konsole setzen.
INITIAL_USER_EMAIL=admin@example.org

# Kontaktadresse fuer Let's Encrypt. Geht an den ACME-Account, nicht an Nutzer.
# Hierhin laufen Ablaufwarnungen, wenn ein Zertifikat nicht erneuert wird.
LETSENCRYPT_EMAIL=technik@example.org


# -----------------------------------------------------------------------------
# Zertifikate
# -----------------------------------------------------------------------------

# true  = Let's-Encrypt-Staging. Kein Rate Limit, aber der Browser meckert.
#         Fuer jeden ersten Durchlauf auf einer neuen Domain empfohlen.
# false = Produktion. Achtung: 5 fehlgeschlagene Validierungen pro Konto und
#         Stunde, danach ist die Domain fuer eine Stunde gesperrt.
#
# Der ClusterIssuer heisst in beiden Faellen letsencrypt-prod, weil die
# CIVITAS-Ingresses ihn so referenzieren. Nur der ACME-Endpunkt wechselt.
# Nach dem Wechsel von staging auf prod die Secrets der Zertifikate loeschen:
#   kubectl -n <slug> delete secret -l cert-manager.io/certificate-name
LETSENCRYPT_STAGING=true


# -----------------------------------------------------------------------------
# Netzwerk
# -----------------------------------------------------------------------------

# Node-IP fuer den CoreDNS-Split-Horizon. Leer lassen = wird aus dem
# Kubernetes-Node-Objekt ermittelt, ersatzweise aus der Default-Route.
#
# Nur setzen, wenn die automatische Ermittlung die falsche Adresse liefert,
# etwa bei mehreren Interfaces. Weicht der Wert von der tatsaechlichen Adresse
# ab, bricht 30-deploy-civitas.sh mit einem Hinweis auf 25-postclone-setup.sh ab.
NODE_IP=

# Oeffentliche Adresse, auf die die DNS-Namen zeigen, wenn die Instanz hinter
# NAT steht - also die Adresse, unter der Let's Encrypt die Instanz erreicht.
#
# Leer lassen ist erlaubt: zeigen alle Namen einheitlich auf dieselbe
# Adresse, die nicht die Node-IP ist, erkennt das Skript die NAT-Situation und
# akzeptiert sie. Eintragen macht die Pruefung nur eindeutiger - dann faellt
# auch auf, wenn ein Record versehentlich auf die falsche Instanz zeigt.
#
# Beispiel: PUBLIC_IP=93.88.227.82
PUBLIC_IP=

# Zusaetzliche Hostnamen fuer den Split-Horizon, ohne Domain-Suffix, durch
# Leerzeichen getrennt. Die Kern-Hosts (api, idm, portal, dashboard, management) sind
# immer dabei und muessen hier nicht stehen.
# Beispiel fuer eine Instanz mit eigenem NiFi- und MinIO-Ingress:
#   EXTRA_HOSTS="nifi s3"
EXTRA_HOSTS=""


# -----------------------------------------------------------------------------
# SMTP  (Keycloak: Einladungen, Passwort-Reset, Verifikationsmails)
# -----------------------------------------------------------------------------
#
# Landet im Secret keycloak-smtp im Namespace der Instanz. Bleibt SMTP_HOST
# leer, laeuft das Deployment durch, aber Keycloak kann keine Mails versenden -
# der initiale Benutzer bekommt dann keine Einladung.
#
# Auf Port 587 erwartet Keycloak STARTTLS, auf 465 implizites SSL.

SMTP_HOST=smtp.example.org
SMTP_PORT=587
SMTP_FROM=noreply@example.org
SMTP_USER=
SMTP_PASSWORD=


# -----------------------------------------------------------------------------
# Optional
# -----------------------------------------------------------------------------

# Tag oder Branch, von dem deployt wird.
#
# Leer oder auskommentiert = der Stand, der im Image ausgecheckt ist
# (bei diesem Template v2.0.0). Das ist der Normalfall und der schnellste
# Weg, weil die Container-Images dazu bereits im Node liegen.
#
# Ein abweichender Wert schaltet NUR die Arbeitskopie unter
# /opt/civitas/rendered/repo um; das Repo unter /opt/civitas/civitas-core-deployment
# bleibt unangetastet. Liegt die Referenz nicht lokal vor, wird sie vom Remote
# geholt - dafuer braucht die VM Netzzugang zum GitLab.
#
# Beispiele:
#   CIVITAS_REF=v2.0-rc2     # anderer Tag
#   CIVITAS_REF=main         # Branch, wird auf origin/main aufgeloest
#   CIVITAS_REF=a1b2c3d      # einzelner Commit
#
# Achtung: Bei einem anderen Stand koennen Repo-Struktur und Image-Versionen
# abweichen. Erst mit LETSENCRYPT_STAGING=true testen.
#CIVITAS_REF=

# Pfad zum ausgecheckten civitas-core-deployment-Repo. Nur aendern, wenn im
# Template ein abweichender Ort verwendet wurde.
#CIVITAS_DIR=/opt/civitas/civitas-core-deployment
CIVITASENV
  chmod 0644 /etc/civitas/deploy.env.example

  if [[ "$PREPULL_IMAGES" == "true" ]]; then
    log "CIVITAS-Images vorziehen (dauert, ist aber der groesste Zeitgewinn beim Klon)"
    render=$(mktemp -d)
    cp -r "${CIVITAS_DIR}/defaults/deployment" "${render}/deployment" 2>/dev/null || true
    if [[ -f "${render}/deployment/helmfile.yaml" ]]; then
      cat >"${render}/deployment/environments/production/global.yaml.gotmpl" <<'EOF'
---
global:
  profile: development
  domain: prepull.invalid
  instanceSlug: prepull
  initialUserEmail: prepull@invalid
  createNamespaces: true
  singleNamespace: true
  runtimePolicies:
    enabled: false
  serviceMesh:
    enable: false
  ingress:
    clusterIssuer: 'letsencrypt-prod'
    ingressClass: 'nginx'
    controller: 'nginx'
EOF
      images=$(helmfile -f "${render}/deployment/helmfile.yaml" template -e production 2>/dev/null \
        | grep -Ei '^[[:space:]]*image:[[:space:]]' \
        | sed -E 's/.*image:[[:space:]]*"?([^"'"'"' ]+)"?.*/\1/' \
        | grep -E '^[a-z0-9]' | sort -u || true)
      if [[ -n "$images" ]]; then
        count=$(wc -l <<<"$images")
        echo "$count Images gefunden."
        i=0
        while read -r img; do
          i=$((i+1))
          printf '  [%d/%d] %s\n' "$i" "$count" "$img"
          /usr/local/bin/k3s ctr images pull "$img" >/dev/null 2>&1 \
            || warn "    konnte nicht geladen werden (privat oder nicht existent)"
        done <<<"$images"
        echo "$images" >/etc/civitas/prepulled-images.txt
      else
        warn "helmfile template lieferte keine Images - Prepull uebersprungen."
      fi
    else
      warn "Kein defaults/deployment im Repo gefunden - Prepull uebersprungen."
    fi
    rm -rf "$render"
  fi
fi

# ---------------------------------------------------------------------------
# 7 – Build protokollieren
# ---------------------------------------------------------------------------

log "Build protokollieren"
mkdir -p /etc/civitas
{
  echo "TEMPLATE_BUILD_DATE=$(date -Iseconds)"
  echo "TEMPLATE_OS=$(. /etc/os-release && echo "$PRETTY_NAME")"
  echo "K3S_VERSION=$(k3s --version | head -1 | awk '{print $3}')"
  echo "NODE_NAME=${NODE_NAME}"
  echo "HELM_VERSION=$(helm version --short 2>/dev/null || true)"
  echo "HELMFILE_VERSION=${HELMFILE_VERSION}"
  echo "CERT_MANAGER_VERSION=$(helm -n cert-manager list -o json 2>/dev/null | jq -r '.[0].app_version // "?"')"
  echo "INGRESS_NGINX_VERSION=$(helm -n ingress-nginx list -o json 2>/dev/null | jq -r '.[0].app_version // "?"')"
  echo "CIVITAS_TAG=${CIVITAS_TAG}"
} >/etc/civitas/template.env
chmod 0644 /etc/civitas/template.env
cat /etc/civitas/template.env

cat <<EOF

------------------------------------------------------------------
Template-Basis steht.

Naechste Schritte:
  1. Kurz gegenpruefen:
       kubectl get nodes -o wide
       kubectl get pods -A
       curl -I http://127.0.0.1        # 404 von nginx = Ingress erreichbar
  2. SSH-Key fuer ${ADMIN_USER} hinterlegen, falls noch nicht geschehen.
  3. sudo ./20-sysprep-template.sh    # versiegelt das Image; die VM LAEUFT weiter
  4. Im Hypervisor einen Snapshot der laufenden VM ziehen.

Bewusst NICHT im Image: ClusterIssuer, Namespace, Secrets, CIVITAS-Release.
Die kommen pro Klon aus 30-deploy-civitas.sh.

Der Klon fuehrt beim ersten Boot civitas-firstboot.service aus, erzeugt eine
neue machine-id samt SSH-Host-Keys und startet einmal selbstaendig neu. Danach:
  sudo ./25-postclone-setup.sh --hostname ... --ip ... --gateway ... --dns ...
  sudo ./30-deploy-civitas.sh
------------------------------------------------------------------
EOF
