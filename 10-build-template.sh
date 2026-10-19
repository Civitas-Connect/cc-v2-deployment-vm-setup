#!/usr/bin/env bash
#
# 10-build-template.sh
#
# Turns an empty Ubuntu 24.04 VM into a clonable CIVITAS/CORE V2 base:
#   - hardening (unattended-upgrades, SSH, ufw, fail2ban)
#   - k3s as single-node cluster with a FIXED node name (survives hostname/IP changes)
#   - ingress-nginx (DaemonSet + hostNetwork) and cert-manager
#   - tooling (helm, helmfile, helm-diff, k9s, jq, git)
#   - civitas-core-deployment repo on a fixed tag + optional pre-pull of all images
#   - civitas-firstboot.service: on first boot, gives every clone a fresh
#     machine identity (machine-id, SSH host keys, k3s server certificate)
#   - civitas-clusterfix.service: afterwards recreates the pods whose
#     container names from the snapshot are still reserved in containerd
#   - DHCP fallback so a clone comes online without console access
#
# Deliberately creates NO ClusterIssuer, NO namespace and NO CIVITAS deployment.
# Everything domain- and IP-specific happens later in 30-deploy-civitas.sh after cloning.
#
# Usage:
#   sudo ./10-build-template.sh                 # full build
#   sudo ./10-build-template.sh --addons-only   # only ingress-nginx + cert-manager + StorageClasses
#                                               # (after a sysprep with --reset-cluster)
#


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Empty = current stable channel. For reproducible images, enter the version
# logged in /etc/civitas/template.env after the first build.
K3S_VERSION="${K3S_VERSION:-}"                     # e.g. "v1.33.4+k3s1"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-}"   # e.g. "v1.17.2", empty = latest
INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-}"  # e.g. "4.12.1", empty = latest
HELMFILE_VERSION="${HELMFILE_VERSION:-1.7.2}"

# Fixed node name: decouples the cluster identity from the hostname.
# Without it every clone registers as a new node and the old one stays
# in the datastore as NotReady.
NODE_NAME="${NODE_NAME:-civitas-node}"

# Pod/service CIDR of k3s (defaults). Must be allowed in the firewall.
POD_CIDR="10.42.0.0/16"
SVC_CIDR="10.43.0.0/16"

# CIVITAS deployment repo
CIVITAS_REPO="${CIVITAS_REPO:-https://gitlab.com/civitas-connect/civitas-core/civitas-core-v2/civitas-core-deployment.git}"
CIVITAS_TAG="${CIVITAS_TAG:-v2.0.0}"
CIVITAS_DIR="/opt/civitas/civitas-core-deployment"

# Pre-pull the CIVITAS stack images into the template. Biggest time saver
# after cloning, and makes the deployment independent of registry rate limits.
PREPULL_IMAGES="${PREPULL_IMAGES:-true}"

# Optional: external kubectl access on port 6443 for exactly one IP.
# Leave empty = 6443 stays fully closed (recommended).
API_ALLOW_FROM="${API_ALLOW_FROM:-}"

# SSH port (if different, change it here AND in the hoster firewall)
SSH_PORT="${SSH_PORT:-22}"

ADDONS_ONLY=false
[[ "${1:-}" == "--addons-only" ]] && ADDONS_ONLY=true

# ---------------------------------------------------------------------------
# Helpers
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
# 1 – Base system
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  # Depending on the update backlog, apt-get upgrade runs for many minutes without output.
# If the SSH session drops meanwhile, dpkg is left half-way.
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
# 2 – Hardening (goes entirely into the image, the clone has nothing left to do)
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
  # Prefix 00-: in sshd the first value read wins. cloud-init writes
  # 50-cloud-init.conf with PasswordAuthentication yes - that would win otherwise.
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
  # /run is a tmpfs and empty after every boot. sshd creates the
  # privilege separation directory itself on start - if the service has
  # never started since boot (after civitas-firstboot the host keys are
  # missing, and sshd won't start without them), it does not exist and
  # "sshd -t" fails with "Missing privilege separation directory".
  install -d -m 0755 -o root -g root /run/sshd
  ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A

  /usr/sbin/sshd -t || die "sshd-Konfiguration ist fehlerhaft, Abbruch bevor der Zugang kaputtgeht."
  systemctl restart ssh

  if [[ ! -s "${ADMIN_HOME}/.ssh/authorized_keys" && "$ADMIN_USER" != "root" ]]; then
    warn "Keine authorized_keys fuer ${ADMIN_USER} gefunden. Vor dem Sysprep unbedingt einen Key hinterlegen."
  fi

  log "Firewall (ufw)"
  apt-get install -y -qq ufw
  # Required for Kubernetes: otherwise ufw sets FORWARD to DROP and pod traffic
  # dies. Typical symptom: admission webhooks run into "context deadline exceeded".
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
# 2b – Clone automation
#
# The image carries everything a clone needs to bring itself up:
#   - DHCP fallback so every clone comes online without a console
#   - cloud-init no longer writes a network config (depending on the template,
#     Nutanix AHV ships one that would otherwise clash with 25-postclone-setup.sh)
#   - civitas-firstboot.service creates a fresh machine identity on the first
#     boot of a sealed image and then reboots
#
# Because of this, 20-sysprep-template.sh does NOT need to delete the identity -
# which is exactly why the master can keep running and be snapshotted live.
# ---------------------------------------------------------------------------

if ! $ADDONS_ONLY; then
  log "Netz-Fallback fuer Klone (DHCP)"
  # Low number = loses against the instance config from
  # 25-postclone-setup.sh (10-civitas-instance.yaml) and against cloud-init (50-).
  # Nothing changes on the build VM, no netplan apply is
  # executed.
  cat >/etc/netplan/01-civitas-dhcp.yaml <<'EOF'
# Fallback from the CIVITAS template. Only applies if no instance
# configuration exists - i.e. right after cloning.
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
  # Without a reliable clock, k3s in the clone creates certificates with a NotBefore
  # in the future. Once NTP moves the clock back, the cluster is dead.
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
# Runs very early during boot, before sshd and k3s start, and only if
# /etc/civitas/sealed exists - i.e. on the first boot of a freshly
# cloned (or freshly sealed) image.
#
# Job: delete everything that must be unique per machine. The following
# reboot lets systemd, sshd and k3s regenerate the values cleanly.
# Deleting them early while running (classic sysprep) is not possible
# here, because the master has to keep running for the snapshot.
#
set -uo pipefail

SEAL=/etc/civitas/sealed
[[ -e "$SEAL" ]] || exit 0

say() { echo "civitas-firstboot: $*" >&2; }
say "versiegeltes Image erkannt, Maschinenidentitaet wird neu erzeugt"

# --- SSH host keys ---------------------------------------------------------
rm -f /etc/ssh/ssh_host_*

# --- machine-id ------------------------------------------------------------
# Empty file: systemd generates a new ID on the next boot.
: >/etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# --- Network and hostname --------------------------------------------------
# The master's instance config must not end up in the clone, otherwise there
# is an IP conflict. The DHCP fallback (01-) stays in place.
rm -f /etc/netplan/10-civitas-instance.yaml /etc/netplan/50-cloud-init.yaml
echo civitas-unconfigured >/etc/hostname
if [[ -w /etc/hosts ]]; then
  sed -i '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
  printf '127.0.1.1\tcivitas-unconfigured\n' >>/etc/hosts
fi

# --- k3s -------------------------------------------------------------------
# The dynamic server certificate carries the old node IP in its SANs.
# After deleting it, k3s rebuilds it on start.
rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
rm -rf /var/log/pods/* /var/log/containers/*

# --- cloud-init ------------------------------------------------------------
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init clean --logs >/dev/null 2>&1 || true
fi
rm -rf /var/lib/cloud/instances/* /var/lib/cloud/data/* 2>/dev/null || true

# Without DHCP in the segment the clone boots without an address. So that
# whoever sits at the hypervisor console doesn't have to search, the
# required command is shown right above the login prompt.
cat >/etc/issue <<'ISSUE'

  CIVITAS-Klon, noch nicht personalisiert.

  Netzwerk und Hostname setzen:
    sudo bash /opt/civitas/scripts/25-postclone-setup.sh          --hostname <name> --ip <adresse>/24 --gateway <gw> --dns <resolver>

  Alles in EINER Zeile eingeben.

ISSUE

# On the next boot civitas-clusterfix cleans up the pods that came from the
# snapshot. Their container names are still reserved in containerd by the old
# instance, otherwise the kubelet fails endlessly with
#   failed to reserve container name ... is reserved for <container-id>
# and the pod stays stuck in CreateContainerError.
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
# Deliberately very early: before sshd (old host keys) and before k3s (old node IP).
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
# Runs once on the first boot of a clone, after civitas-firstboot has
# renewed the identity and k3s is running again.
#
# Job: remove pods that came from the snapshot. Sysprep stops k3s, but the
# containerd metadata of the containers running at that time is carried
# into the image. In the clone the old pod object then collides with the
# still-reserved container name, and the kubelet retries endlessly:
#   Error: failed to reserve container name "..."; check if another
#   CreateContainer request is in progress: name "..." is reserved for "..."
# Deleting the pod creates a new UID and thus a new name.
#
set -uo pipefail

MARKER=/etc/civitas/clusterfix-pending
[[ -e "$MARKER" ]] || exit 0

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL=/usr/local/bin/kubectl
say() { echo "civitas-clusterfix: $*" >&2; }

# Wait for the API - on first boot startup takes longer than usual.
ready=false
for _ in $(seq 1 120); do
  "$KUBECTL" get --raw=/readyz >/dev/null 2>&1 && { ready=true; break; }
  sleep 5
done
if ! $ready; then
  say "k3s-API nach 10 Minuten nicht erreichbar, Marke bleibt fuer den naechsten Boot"
  exit 0
fi

# Give the pods a fair chance to come up on their own.
sleep 60

fixed=0
for ns in kube-system cert-manager ingress-nginx; do
  while read -r pod phase ready_state; do
    [[ -n "$pod" ]] || continue
    # Touch everything that is not running or not ready. Running,
    # healthy pods are left alone - deleting everything would be
    # needlessly expensive.
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

  # helmfile needs helm-diff - for root AND the admin user,
  # because plugins live per user in HELM_DATA_HOME.
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

  # Deliberately WITHOUT --cluster-init: the embedded SQLite datastore holds
  # no node IP. etcd would pin the IP and break the clone.
  cat >/etc/rancher/k3s/config.yaml <<EOF
# Fixed node name -> the clone's hostname can be chosen freely
node-name: "${NODE_NAME}"

# Traefik out: CIVITAS expects ingressClass nginx
# servicelb out: ingress-nginx runs as DaemonSet with hostNetwork
disable:
  - traefik
  - servicelb

# NetworkPolicies are disabled in the V2 deployment
disable-network-policy: true

# 0640 plus group instead of 0600: group members can use kubectl without
# sudo, without making the file world-readable. k3s resets mode and
# group on every start - this also survives a certificate rotation,
# unlike a copy under ~/.kube/config.
write-kubeconfig-mode: "0640"
write-kubeconfig-group: "civitas"
kubelet-arg:
  - "image-gc-high-threshold=80"
  - "image-gc-low-threshold=70"
EOF

  INSTALL_ARGS=()
  # On an already installed instance, the changed config.yaml only takes
  # effect after a service restart.
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

# An old copy would work against the group approach: after a certificate
# rotation its CA no longer matches, and the error message is
# misleading.
if [[ -f "${ADMIN_HOME}/.kube/config" ]]; then
  mv "${ADMIN_HOME}/.kube/config" "${ADMIN_HOME}/.kube/config.bak-$(date +%Y%m%d)"
  echo "  veraltete ~/.kube/config nach .bak verschoben"
fi

# ---------------------------------------------------------------------------
# 5 – Addons: StorageClasses, ingress-nginx, cert-manager
# ---------------------------------------------------------------------------

log "StorageClasses"
# k3s already ships local-path as default. The aliases rwo/rwx/loc
# exist so that a global.yaml which sets explicit StorageClass names
# also works (as in the Nutanix instance).
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

# No ClusterIssuer here - it needs an e-mail address and is created per
# instance in 30-deploy-civitas.sh.

# ---------------------------------------------------------------------------
# 6 – CIVITAS repo and image pre-pull
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
# deploy.env.example  –  configuration of a CIVITAS/CORE V2 instance
# =============================================================================
#
# Read by 30-deploy-civitas.sh. Copy and fill in on the clone:
#
#   sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
#   sudo nano /etc/civitas/deploy.env
#   sudo chmod 600 /etc/civitas/deploy.env
#
# Prerequisite: the node has already been personalized
# (sudo bash 25-postclone-setup.sh --hostname ... --ip ...).
#
# WARNING: /etc/civitas/deploy.env contains credentials. The file is deleted by
# 20-sysprep-template.sh and belongs neither in the image nor in the
# Git repo.
#
# Syntax: KEY=value, one assignment per line, no spaces around the =.
# Put values containing special characters in double quotes.
# =============================================================================


# -----------------------------------------------------------------------------
# Required
# -----------------------------------------------------------------------------

# Base domain of the instance. Easiest is a wildcard record *.<DOMAIN>.
# Which names are needed exactly depends on the release (v2.0.0: api, idm,
# portal, dashboard, management). 30-deploy-civitas.sh reads the list from the
# rendered release and checks every name up front via getent.
DOMAIN=demo.civitascore.de

# Short name of the instance. Used both as Kubernetes namespace and as
# Keycloak realm. Lowercase letters, digits and hyphens only.
# Must differ between instances, otherwise the realms collide.
INSTANCE_SLUG=demo

# First user in the Keycloak realm. Receives the invitation mail and with it
# admin rights in the portal. Without working SMTP this mail never arrives -
# in that case set the password later via the Keycloak console.
INITIAL_USER_EMAIL=admin@example.org

# Contact address for Let's Encrypt. Goes to the ACME account, not to users.
# Expiry warnings are sent here if a certificate is not renewed.
LETSENCRYPT_EMAIL=technik@example.org


# -----------------------------------------------------------------------------
# Certificates
# -----------------------------------------------------------------------------

# true  = Let's Encrypt staging. No rate limit, but the browser complains.
#         Recommended for every first run on a new domain.
# false = Production. Caution: 5 failed validations per account and
#         hour, after that the domain is locked for one hour.
#
# The ClusterIssuer is called letsencrypt-prod in both cases, because the
# CIVITAS ingresses reference it by that name. Only the ACME endpoint changes.
# After switching from staging to prod, delete the certificate secrets:
#   kubectl -n <slug> delete secret -l cert-manager.io/certificate-name
LETSENCRYPT_STAGING=true


# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------

# Node IP for the CoreDNS split horizon. Leave empty = taken from the
# Kubernetes node object, falling back to the default route.
#
# Only set it if auto-detection picks the wrong address, e.g. with
# multiple interfaces. If the value differs from the actual address,
# 30-deploy-civitas.sh aborts and points to 25-postclone-setup.sh.
NODE_IP=

# Public address the DNS names point to when the instance sits behind
# NAT - i.e. the address under which Let's Encrypt reaches the instance.
#
# Leaving it empty is allowed: if all names consistently point to the same
# address that is not the node IP, the script detects the NAT setup and
# accepts it. Setting it only makes the check stricter - it then also
# catches a record that accidentally points to the wrong instance.
#
# Example: PUBLIC_IP=93.88.227.82
PUBLIC_IP=

# Additional host names for the split horizon, without domain suffix,
# separated by spaces. Hosts from the release are detected automatically
# and do not need to be listed here.
# Example for an instance with its own NiFi and MinIO ingress:
#   EXTRA_HOSTS="nifi s3"
EXTRA_HOSTS=""


# -----------------------------------------------------------------------------
# SMTP  (Keycloak: invitations, password reset, verification mails)
# -----------------------------------------------------------------------------
#
# Stored in the secret keycloak-smtp in the instance namespace. If SMTP_HOST
# stays empty, the deployment still succeeds, but Keycloak cannot send mail -
# the initial user then gets no invitation.
#
# On port 587 Keycloak expects STARTTLS, on 465 implicit SSL.

SMTP_HOST=smtp.example.org
SMTP_PORT=587
SMTP_FROM=noreply@example.org
SMTP_USER=
SMTP_PASSWORD=


# -----------------------------------------------------------------------------
# Optional
# -----------------------------------------------------------------------------

# Tag or branch to deploy from.
#
# Empty or commented out = the revision checked out in the image
# (v2.0.0 for this template). This is the normal case and the fastest
# path, because the matching container images are already on the node.
#
# A different value ONLY switches the working copy under
# /opt/civitas/rendered/repo; the repo under /opt/civitas/civitas-core-deployment
# stays untouched. If the ref is not available locally, it is fetched from the
# remote - this requires network access to GitLab.
#
# Examples:
#   CIVITAS_REF=v2.0-rc2     # different tag
#   CIVITAS_REF=main         # branch, resolved to origin/main
#   CIVITAS_REF=a1b2c3d      # single commit
#
# Caution: with a different revision, repo structure and image versions may
# differ. Test with LETSENCRYPT_STAGING=true first.
#CIVITAS_REF=

# Path to the checked-out civitas-core-deployment repo. Only change it if a
# different location was used in the template.
#CIVITAS_DIR=/opt/civitas/civitas-core-deployment

# Update the scripts from Git before every deploy. 30-deploy-civitas.sh fetches
# SCRIPTS_REF from SCRIPTS_REPO, installs the scripts to /opt/civitas/scripts and
# restarts itself with the new version. This brings adjustments for new
# CIVITAS releases to existing clones without rebuilding the image.
#
# Empty = off, the version from the image runs. Skip once:
#   sudo bash /opt/civitas/scripts/30-deploy-civitas.sh --no-update
#
# The repo must be reachable without authentication. The scripts run as root -
# to be on the safe side, set a tag here instead of a branch.
SCRIPTS_REF=main
#SCRIPTS_REPO=
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
# 7 – Log the build
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
