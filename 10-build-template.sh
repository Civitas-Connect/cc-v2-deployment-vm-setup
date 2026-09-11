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
CIVITAS_TAG="${CIVITAS_TAG:-v2.0-rc2}"
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
  sshd -t || die "sshd-Konfiguration ist fehlerhaft, Abbruch bevor der Zugang kaputtgeht."
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

write-kubeconfig-mode: "0600"
kubelet-arg:
  - "image-gc-high-threshold=80"
  - "image-gc-low-threshold=70"
EOF

  INSTALL_ARGS=()
  if [[ -n "$K3S_VERSION" ]]; then
    export INSTALL_K3S_VERSION="$K3S_VERSION"
  else
    export INSTALL_K3S_CHANNEL="stable"
  fi
  curl -sfL https://get.k3s.io | sh -s - server "${INSTALL_ARGS[@]}"

  systemctl enable k3s
  log "Warte auf Node Ready"
  for _ in $(seq 1 60); do
    if "$KUBECTL" get node "$NODE_NAME" 2>/dev/null | grep -qw Ready; then break; fi
    sleep 5
  done
  "$KUBECTL" get node -o wide || die "k3s ist nicht hochgekommen. Logs: journalctl -u k3s -n 200"

  log "kubeconfig fuer ${ADMIN_USER} bereitstellen"
  install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0700 "${ADMIN_HOME}/.kube"
  install -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0600 /etc/rancher/k3s/k3s.yaml "${ADMIN_HOME}/.kube/config"
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >/etc/profile.d/kubeconfig.sh
  chmod 0644 /etc/profile.d/kubeconfig.sh
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
  cat >/etc/civitas/deploy.env.example <<'EOF'
# Von 30-deploy-civitas.sh gelesen. Kopie nach /etc/civitas/deploy.env anlegen.
# ACHTUNG: /etc/civitas/deploy.env enthaelt Zugangsdaten und wird vom Sysprep geloescht.

DOMAIN=demo.civitascore.de
INSTANCE_SLUG=demo
INITIAL_USER_EMAIL=admin@example.org
LETSENCRYPT_EMAIL=technik@example.org

# true = Let's-Encrypt-Staging (kein Rate Limit, Browser meckert). Zum Testen sinnvoll.
LETSENCRYPT_STAGING=false

# Node-IP; leer = automatisch ermitteln
NODE_IP=

SMTP_HOST=smtp.example.org
SMTP_PORT=587
SMTP_FROM=noreply@example.org
SMTP_USER=
SMTP_PASSWORD=

# Zusaetzliche Hostnamen fuer den CoreDNS-Split-Horizon (Leerzeichen-getrennt,
# ohne Domain-Suffix). Standard deckt die vier Kern-Hosts ab.
EXTRA_HOSTS=""
EOF
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
  3. sudo ./20-sysprep-template.sh    # danach VM herunterfahren und Snapshot/Template ziehen

Bewusst NICHT im Image: ClusterIssuer, Namespace, Secrets, CIVITAS-Release.
Die kommen pro Klon aus 30-deploy-civitas.sh.
------------------------------------------------------------------
EOF
