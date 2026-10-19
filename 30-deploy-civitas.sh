#!/usr/bin/env bash
#
# 30-deploy-civitas.sh
#
# Runs on the freshly cloned node and does everything that knows the domain or IP:
#   - optional: update the scripts under /opt/civitas/scripts from the Git repo
#   - render the release and derive the host names from it (no fixed list)
#   - ClusterIssuer (Let's Encrypt prod or staging)
#   - CoreDNS split horizon via the coredns-custom ConfigMap
#   - namespace, keycloak-smtp, custom-ca-cert
#   - render global.yaml.gotmpl, then helmfile-operators and helmfile-instance
#   - update CoreDNS entries from the actual ingresses
#
# Prerequisite: /etc/civitas/deploy.env (template: /etc/civitas/deploy.env.example)
#               node is personalized (./25-postclone-setup.sh has run)
#
# Usage:
#   sudo ./30-deploy-civitas.sh              # full rollout
#   sudo ./30-deploy-civitas.sh --diff       # preview only, does not change the release
#   sudo ./30-deploy-civitas.sh --reset      # delete the instance and rebuild it
#   sudo ./30-deploy-civitas.sh --prepare    # only issuer/DNS/namespace/secrets
#   sudo ./30-deploy-civitas.sh --no-update  # do not update the scripts from Git
#

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

# Change into a stable directory that this script is guaranteed not to touch.
# If the script was started from within /opt/civitas/rendered/... (e.g. because you
# cd'ed there for debugging), the later rm -rf/cp -a of the repo copy (step 7)
# pulls exactly this working directory out from under the running process.
# Every following getcwd() call - including in helmfile itself - then fails with
# "no such file or directory", even though a fresh directory already exists at the
# same path again (new inode, but the old cwd binding is dead).
cd /opt/civitas || die "cd /opt/civitas fehlgeschlagen"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL=/usr/local/bin/kubectl

MODE="deploy"
SELF_UPDATE=true
for arg in "$@"; do
  case "$arg" in
    --diff)      MODE="diff" ;;
    --reset)     MODE="reset" ;;
    --prepare)   MODE="prepare" ;;
    --no-update) SELF_UPDATE=false ;;
    *)           die "Unbekannte Option: $arg" ;;
  esac
done

# ---------------------------------------------------------------------------
# 1 – Load and validate configuration
# ---------------------------------------------------------------------------

# Sealed image: civitas-firstboot has not run yet. A deployment would be
# completely re-personalized on the next boot and thus broken.
[[ -e /etc/civitas/sealed ]] \
  && die "Diese VM ist noch versiegelt (/etc/civitas/sealed). Erst neu starten, dann ./25-postclone-setup.sh, dann dieses Skript."

ENV_FILE=/etc/civitas/deploy.env
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE fehlt. Vorlage: cp /etc/civitas/deploy.env.example $ENV_FILE"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

# ---------------------------------------------------------------------------
# 1a – Update scripts from Git (optional)
#
# This brings adjustments for new CIVITAS releases to existing clones
# without rebuilding the image. An empty SCRIPTS_REF disables it.
# ---------------------------------------------------------------------------

SCRIPTS_REPO="${SCRIPTS_REPO:-https://github.com/BronxHD/civitas-core-demo_clone_setup-.git}"
SCRIPTS_REF="${SCRIPTS_REF:-}"
SCRIPTS_DIR=/opt/civitas/scripts
SCRIPTS_SRC=/opt/civitas/scripts-src

update_scripts() {
  # No terminal prompt: an unreachable or private repo should
  # fail instead of waiting for a username.
  export GIT_TERMINAL_PROMPT=0
  if [[ -d "${SCRIPTS_SRC}/.git" ]]; then
    git -C "$SCRIPTS_SRC" remote set-url origin "$SCRIPTS_REPO"
    git -C "$SCRIPTS_SRC" fetch --tags --prune --quiet origin || return 1
  else
    rm -rf "$SCRIPTS_SRC"
    git clone --quiet "$SCRIPTS_REPO" "$SCRIPTS_SRC" || return 1
  fi

  local target="$SCRIPTS_REF" f name
  if git -C "$SCRIPTS_SRC" rev-parse --verify --quiet "refs/remotes/origin/${SCRIPTS_REF}" >/dev/null; then
    target="origin/${SCRIPTS_REF}"
  fi
  git -C "$SCRIPTS_SRC" checkout --quiet --detach "$target" || return 1

  # A broken version must not replace the working one.
  for f in "$SCRIPTS_SRC"/*.sh; do
    bash -n "$f" || { warn "  Syntaxfehler in $(basename "$f") - Aktualisierung verworfen"; return 1; }
  done
  [[ -f "${SCRIPTS_SRC}/30-deploy-civitas.sh" ]] || return 1

  # New file plus rename instead of overwriting: bash reads the running script
  # in chunks and would otherwise jump into the new version mid-run.
  install -d -m 0755 "$SCRIPTS_DIR"
  for f in "$SCRIPTS_SRC"/*.sh; do
    name=$(basename "$f")
    install -m 0755 "$f" "${SCRIPTS_DIR}/.${name}.new" && mv -f "${SCRIPTS_DIR}/.${name}.new" "${SCRIPTS_DIR}/${name}"
  done
  if [[ -f "${SCRIPTS_SRC}/deploy.env.example" ]]; then
    install -m 0644 "${SCRIPTS_SRC}/deploy.env.example" "${SCRIPTS_DIR}/deploy.env.example"
    install -m 0644 "${SCRIPTS_SRC}/deploy.env.example" /etc/civitas/deploy.env.example
  fi
}

if $SELF_UPDATE && [[ -n "$SCRIPTS_REF" && -z "${CIVITAS_SCRIPTS_UPDATED:-}" ]]; then
  log "Skripte auf ${SCRIPTS_REF} aktualisieren (${SCRIPTS_REPO})"
  if update_scripts; then
    echo "  Stand: $(git -C "$SCRIPTS_SRC" log -1 --format='%h %s')"
    # Start over with the fresh version. The marker prevents
    # a loop.
    exec env CIVITAS_SCRIPTS_UPDATED=1 bash "${SCRIPTS_DIR}/30-deploy-civitas.sh" "$@"
  fi
  warn "Aktualisierung fehlgeschlagen - es laeuft die lokale Fassung weiter."
  warn "Ist ${SCRIPTS_REPO} von hier aus ohne Anmeldung erreichbar?"
fi

: "${DOMAIN:?DOMAIN fehlt in $ENV_FILE}"
: "${INSTANCE_SLUG:?INSTANCE_SLUG fehlt in $ENV_FILE}"
: "${INITIAL_USER_EMAIL:?INITIAL_USER_EMAIL fehlt in $ENV_FILE}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL fehlt in $ENV_FILE}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
EXTRA_HOSTS="${EXTRA_HOSTS:-}"

NS="$INSTANCE_SLUG"
CIVITAS_DIR="${CIVITAS_DIR:-/opt/civitas/civitas-core-deployment}"
# Tag or branch to deploy from. Empty = use the revision checked out in the
# image. Otherwise the working copy is switched, the repo under
# CIVITAS_DIR stays untouched.
CIVITAS_REF="${CIVITAS_REF:-}"
# Public address the DNS names point to when the instance sits behind
# NAT. Empty = derived from DNS resolution.
PUBLIC_IP="${PUBLIC_IP:-}"
WORK_DIR="/opt/civitas/rendered"
# The whole repo is copied, not just defaults/deployment: helmfile-root.yaml.gotmpl
# lives in the repo root, and defaults/deployment/*.yaml(.gotmpl) reference it via
# '../helmfile-root.yaml.gotmpl' - that only works if the deployment directory sits
# ONE level directly below the repo root, not two (as defaults/deployment does).
# That is exactly why the official justfile (target "deploy") copies
# "defaults/deployment" to "deployment" in the repo root before every run - we mirror that below.
REPO_COPY="${WORK_DIR}/repo"
DEPLOY_DIR="${REPO_COPY}/deployment"
# Two entry points, in this order. helmfile.yaml in the same
# directory is NOT the right entry point - it refers to a
# helmfile-root.yaml.gotmpl that lives (only) in the repo root.
HELMFILE_OPERATORS="${DEPLOY_DIR}/helmfile-operators.yaml"
HELMFILE_INSTANCE="${DEPLOY_DIR}/helmfile-instance.yaml.gotmpl"
OPERATOR_NS="${OPERATOR_NS:-civitas-operators}"
ISRG_PEM="/opt/civitas/isrg-root-x1.pem"

if [[ -z "${NODE_IP:-}" ]]; then
  NODE_IP=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  [[ -n "$NODE_IP" ]] || NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
fi
[[ -n "$NODE_IP" ]] || die "Node-IP konnte nicht ermittelt werden. NODE_IP in $ENV_FILE setzen."

# If the node IP does not match the actual address, k3s missed the
# IP change after cloning. The CoreDNS split horizon further down
# would then point to the old address.
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
if [[ -n "$HOST_IP" && "$HOST_IP" != "$NODE_IP" ]]; then
  die "k3s meldet Node-IP ${NODE_IP}, die Maschine hat aber ${HOST_IP}.
Erst korrigieren: sudo ./25-postclone-setup.sh --check
Danach: sudo ./25-postclone-setup.sh --hostname \$(hostname) --ip ${HOST_IP}/<praefix> --gateway <gw> --dns <dns>"
fi

# The host names come from the rendered release (step 3), so that new
# hosts of future versions are checked automatically - like management,
# which was added in v2.0.0. This list only applies if that fails.
FALLBACK_HOSTS=(api idm portal dashboard management)

log "Konfiguration"
printf '  Domain          : %s\n' "$DOMAIN"
printf '  Instance / NS   : %s\n' "$INSTANCE_SLUG"
printf '  Node-IP         : %s\n' "$NODE_IP"
printf '  ACME            : %s\n' "$([[ "$LETSENCRYPT_STAGING" == "true" ]] && echo staging || echo production)"
printf '  Repo-Stand      : %s\n' "$(git -C "$CIVITAS_DIR" describe --tags --always 2>/dev/null || echo '?')"
printf '  Deploy-Ref      : %s\n' "${CIVITAS_REF:-<Stand im Image>}"
printf '  Oeffentliche IP : %s\n' "${PUBLIC_IP:-<aus DNS ableiten>}"
printf '  Skript-Stand    : %s\n' "$(git -C "$SCRIPTS_SRC" log -1 --format='%h %s' 2>/dev/null || echo '<aus dem Image>')"

# ---------------------------------------------------------------------------
# 2 – Check cluster prerequisites
# ---------------------------------------------------------------------------

# The rollout runs for many minutes without output. If the SSH session drops,
# helmfile dies mid-upgrade and leaves releases in
# pending-upgrade that block the next run.
if [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]]; then
  warn "Der Rollout haengt an dieser SSH-Sitzung und dauert viele Minuten ohne Ausgabe."
  warn "Empfehlung: abbrechen und in 'tmux' erneut starten - tmux new -s deploy"
  read -r -p "Trotzdem fortfahren? [ja/NEIN] " a
  [[ "$a" == "ja" ]] || die "Abgebrochen."
fi

log "Haengende Helm-Releases pruefen"
mapfile -t stuck < <(helm list -n "$NS" --pending -q 2>/dev/null || true)
if (( ${#stuck[@]} > 0 )); then
  warn "Diese Releases haengen in einem pending-Status: ${stuck[*]}"
  warn "Ein neuer Lauf scheitert daran. Aufloesen mit:"
  for r in "${stuck[@]}"; do
    warn "  helm rollback ${r} -n ${NS}   # oder: helm uninstall ${r} -n ${NS}"
  done
  die "Abbruch."
fi
echo "  keine haengenden Releases"

log "Cluster pruefen"
"$KUBECTL" get node >/dev/null 2>&1 || die "Kein erreichbarer Cluster. journalctl -u k3s -n 100"
"$KUBECTL" get node | grep -qw Ready || die "Node ist nicht Ready."

for check in "ingress-nginx:daemonset/ingress-nginx-controller" "cert-manager:deployment/cert-manager"; do
  ns="${check%%:*}"; obj="${check##*:}"
  "$KUBECTL" -n "$ns" get "$obj" >/dev/null 2>&1 \
    || die "$obj in $ns fehlt. Nach einem Sysprep mit --reset-cluster erst: ./10-build-template.sh --addons-only"
done
echo "  ingress-nginx und cert-manager sind vorhanden."

# Present does not mean ready. After cloning k3s restarts all pods;
# if the deployment starts too early, the API server rejects the ClusterIssuer:
#   failed calling webhook ... cert-manager-webhook ... no endpoints available
# The issuer is then not created, and the next step reports NotFound.
log "Warten, bis cert-manager und ingress-nginx bereit sind"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  "$KUBECTL" -n cert-manager rollout status "deployment/${d}" --timeout=300s >/dev/null 2>&1 \
    || warn "  ${d} ist nach 5 Minuten nicht Available"
done
"$KUBECTL" -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=300s >/dev/null 2>&1 \
  || warn "  ingress-nginx-controller ist nach 5 Minuten nicht bereit"

# What matters is the endpoint behind the webhook service, not the pod status:
# there are a few seconds between "Running" and "registered in the service".
webhook_ready=false
for _ in $(seq 1 60); do
  eps=$("$KUBECTL" -n cert-manager get endpoints cert-manager-webhook \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [[ -n "$eps" ]]; then webhook_ready=true; break; fi
  sleep 5
done
if $webhook_ready; then
  echo "  cert-manager-webhook bereit"
else
  warn "cert-manager-webhook hat nach 5 Minuten keine Endpoints."
  "$KUBECTL" -n cert-manager get pods 2>/dev/null | sed 's/^/    /'
  die "Ohne den Webhook kann der ClusterIssuer nicht angelegt werden.
Ursache ansehen:
  kubectl -n cert-manager describe pod -l app.kubernetes.io/name=webhook | tail -20"
fi

# ---------------------------------------------------------------------------
# 3 – Prepare and validate the release, derive host names
# ---------------------------------------------------------------------------

log "Deployment-Verzeichnis unter ${WORK_DIR} aufbauen"
[[ -d "$CIVITAS_DIR" ]] || die "$CIVITAS_DIR fehlt - im Template wurde das Repo nicht geklont."
mkdir -p "$WORK_DIR"
rm -rf "$REPO_COPY"
cp -a "$CIVITAS_DIR" "$REPO_COPY"

# Switch to a different tag or branch - only in the working copy.
if [[ -n "$CIVITAS_REF" ]]; then
  log "Auf ${CIVITAS_REF} umschalten"
  git config --global --add safe.directory "$REPO_COPY" 2>/dev/null || true

  if ! git -C "$REPO_COPY" rev-parse --verify --quiet "${CIVITAS_REF}^{commit}" >/dev/null; then
    echo "  ${CIVITAS_REF} liegt nicht lokal vor, hole vom Remote"
    git -C "$REPO_COPY" fetch --all --tags --prune --quiet \
      || die "git fetch fehlgeschlagen - ohne Netz kann ${CIVITAS_REF} nicht geholt werden."
  fi

  target="$CIVITAS_REF"
  # Resolve branch names to the remote state, otherwise you end up on a
  # stale local branch from the time the image was built.
  if git -C "$REPO_COPY" rev-parse --verify --quiet "refs/remotes/origin/${CIVITAS_REF}" >/dev/null; then
    target="origin/${CIVITAS_REF}"
  fi

  git -C "$REPO_COPY" checkout --quiet --detach "$target" \
    || die "Checkout von ${CIVITAS_REF} fehlgeschlagen. Verfuegbar:
$(git -C "$REPO_COPY" tag | tail -10 | sed 's/^/  /')
$(git -C "$REPO_COPY" branch -r | sed 's/^/  /')"

  echo "  jetzt auf: $(git -C "$REPO_COPY" describe --tags --always 2>/dev/null) ($(git -C "$REPO_COPY" log -1 --format=%h\ %s))"
fi

# As in the official justfile (target "deploy"): copy defaults/deployment to deployment/
# in the repo root, so that '../helmfile-root.yaml.gotmpl' in the helmfiles there
# points to the helmfile-root.yaml.gotmpl that actually exists in the repo root.
[[ -d "${REPO_COPY}/defaults/deployment" ]] \
  || die "${REPO_COPY}/defaults/deployment fehlt - die Repo-Struktur weicht von der erwarteten ab."
rm -rf "$DEPLOY_DIR"
cp -a "${REPO_COPY}/defaults/deployment" "$DEPLOY_DIR"

for f in "$HELMFILE_OPERATORS" "$HELMFILE_INSTANCE"; do
  [[ -f "$f" ]] || die "${f} fehlt - die Repo-Struktur weicht von der erwarteten ab.
Vorhanden in ${DEPLOY_DIR}:
$(ls -1 "$DEPLOY_DIR" 2>/dev/null | sed 's/^/  /')"
done

GLOBAL="${DEPLOY_DIR}/environments/production/global.yaml.gotmpl"
mkdir -p "$(dirname "$GLOBAL")"
cat >"$GLOBAL" <<EOF
---
global:
  profile: development
  domain: ${DOMAIN}
  instanceSlug: ${INSTANCE_SLUG}
  initialUserEmail: ${INITIAL_USER_EMAIL}
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
echo "  global.yaml.gotmpl geschrieben"

# Pre-check: the release must render with the installed tools
# BEFORE anything happens to the cluster (reset, issuer, namespace).
# If a future release and the tool versions in the image don't
# match, this is caught here and not in the middle of the rollout.
log "Release rendern (Vorabpruefung, laedt beim ersten Mal die Charts)"
RENDERED="${WORK_DIR}/instance-rendered.yaml"
RENDER_LOG="${WORK_DIR}/instance-render.log"
if ! helmfile -f "$HELMFILE_INSTANCE" template -e production >"$RENDERED" 2>"$RENDER_LOG"; then
  tail -20 "$RENDER_LOG" | sed 's/^/    /' >&2
  die "Das Release laesst sich nicht rendern - es wurde noch nichts am Cluster geaendert.
Vollstaendiges Log: ${RENDER_LOG}
Haeufige Ursachen: kein Netz zu den Chart-Repos, zu alte helmfile/helm-Version
im Image (helmfile --version, helm version), geaenderte Repo-Struktur."
fi
echo "  $(grep -c '^kind:' "$RENDERED") Objekte gerendert"

# All host names from the release's ingresses. They end up together in one
# certificate - if one is missing from DNS, the challenge fails for all of them.
mapfile -t HOST_FQDNS < <(awk '
  /^---/ { ing = 0; next }
  /^kind:[[:space:]]*Ingress[[:space:]]*$/ { ing = 1; next }
  ing && /^[[:space:]]*(-[[:space:]]*)?host:[[:space:]]*/ {
    h = $0
    sub(/^[[:space:]]*(-[[:space:]]*)?host:[[:space:]]*/, "", h)
    gsub(/["'"'"'[:space:]]/, "", h)
    if (h != "") print h
  }' "$RENDERED" | sort -u)
if (( ${#HOST_FQDNS[@]} == 0 )); then
  warn "Keine Ingress-Hosts im Release gefunden - es gilt die Standardliste."
  for h in "${FALLBACK_HOSTS[@]}"; do HOST_FQDNS+=("${h}.${DOMAIN}"); done
fi
for h in $EXTRA_HOSTS; do HOST_FQDNS+=("${h}.${DOMAIN}"); done
mapfile -t HOST_FQDNS < <(printf '%s\n' "${HOST_FQDNS[@]}" | sort -u)
echo "  Hostnamen dieses Releases:"
printf '    %s\n' "${HOST_FQDNS[@]}"

# ---------------------------------------------------------------------------
# 3b – Public DNS resolution
# ---------------------------------------------------------------------------

# Two valid modes:
#
#   direct  The names point to the node IP. Only possible if the VM itself
#           is reachable from the internet.
#   NAT     The names point to a public address that the hypervisor
#           or firewall maps to the private node IP. This is the
#           normal case in a data center network - and then a
#           mismatch with the node IP is NOT an error.
#
# All that matters for the HTTP-01 challenge is that all names consistently
# point to the same address and that port 80 reaches it from outside.
log "Oeffentliche DNS-Aufloesung pruefen"

declare -A seen=()
dns_missing=false
for fqdn in "${HOST_FQDNS[@]}"; do
  resolved=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -z "$resolved" ]]; then
    warn "  ${fqdn} loest nicht auf"
    dns_missing=true
  else
    echo "  ${fqdn} -> ${resolved}"
    seen["$resolved"]=1
  fi
done

dns_ok=true
if $dns_missing; then
  dns_ok=false
elif (( ${#seen[@]} > 1 )); then
  warn "Die Namen zeigen auf verschiedene Adressen: ${!seen[*]}"
  warn "Fuer die HTTP-01-Challenge muessen alle auf dieselbe Adresse zeigen."
  dns_ok=false
else
  TARGET_ADDR="${!seen[*]}"
  if [[ "$TARGET_ADDR" == "$NODE_IP" ]]; then
    echo "  Betriebsart: direkt (Namen zeigen auf die Node-IP)"
  elif [[ -n "$PUBLIC_IP" && "$TARGET_ADDR" == "$PUBLIC_IP" ]]; then
    echo "  Betriebsart: NAT ueber ${PUBLIC_IP} -> ${NODE_IP}, wie konfiguriert"
  elif [[ -n "$PUBLIC_IP" ]]; then
    warn "  Namen zeigen auf ${TARGET_ADDR}, in der deploy.env steht aber PUBLIC_IP=${PUBLIC_IP}"
    dns_ok=false
  else
    echo "  Betriebsart: NAT vermutet - ${TARGET_ADDR} bildet auf ${NODE_IP} ab"
    echo "  Fuer eine eindeutige Pruefung PUBLIC_IP=${TARGET_ADDR} in ${ENV_FILE} eintragen."
  fi
fi

if $dns_ok; then
  # The test runs from the VM and thus via hairpin NAT, which many
  # firewalls don't support. A failure here says little - so it is
  # only a hint, never a reason to abort.
  if [[ -n "${TARGET_ADDR:-}" && "$TARGET_ADDR" != "$NODE_IP" ]]; then
    if curl -sS -o /dev/null --max-time 10 "http://${TARGET_ADDR}/.well-known/acme-challenge/probe" 2>/dev/null; then
      echo "  Port 80 auf ${TARGET_ADDR} antwortet"
    else
      echo "  Port 80 auf ${TARGET_ADDR} von hier nicht pruefbar (Hairpin-NAT)."
      echo "  Von ausserhalb des Netzes testen:"
      echo "    curl -I --max-time 10 http://${TARGET_ADDR}/.well-known/acme-challenge/test"
      echo "  Ein 404 vom nginx ist die gute Antwort; ein Timeout heisst, dass"
      echo "  Let's Encrypt nicht validieren kann."
    fi
  fi
else
  warn "Solange DNS nicht stimmt, scheitert die HTTP-01-Challenge. Mit LETSENCRYPT_STAGING=true testen."
  read -r -p "Trotzdem fortfahren? [ja/NEIN] " a; [[ "$a" == "ja" ]] || exit 1
fi

# ---------------------------------------------------------------------------
# 4 – Reset (optional)
# ---------------------------------------------------------------------------

if [[ "$MODE" == "reset" ]]; then
  log "Instanz ${NS} zuruecksetzen"
  if [[ -f "$HELMFILE_INSTANCE" ]]; then
    helmfile -f "$HELMFILE_INSTANCE" destroy -e production || warn "helmfile destroy mit Fehlern"
  fi
  "$KUBECTL" delete namespace "$NS" --wait=false 2>/dev/null || true
  for _ in $(seq 1 30); do
    "$KUBECTL" get namespace "$NS" >/dev/null 2>&1 || break
    sleep 5
  done
  if "$KUBECTL" get namespace "$NS" >/dev/null 2>&1; then
    warn "Namespace haengt in Terminating - Finalizer werden geleert."
    "$KUBECTL" get namespace "$NS" -o json | jq '.spec.finalizers = []' \
      | "$KUBECTL" replace --raw "/api/v1/namespaces/${NS}/finalize" -f - >/dev/null
  fi
  "$KUBECTL" get pv -o json | jq -r --arg ns "$NS" \
    '.items[] | select(.spec.claimRef.namespace == $ns) | .metadata.name' \
    | xargs -r "$KUBECTL" delete pv
  echo "  Reset abgeschlossen, es wird jetzt neu aufgebaut."
fi

# ---------------------------------------------------------------------------
# 5 – ClusterIssuer
# ---------------------------------------------------------------------------

log "ClusterIssuer letsencrypt-prod"
apply_with_retry() {  # reads the manifest from stdin
  local manifest attempt
  manifest=$(cat)
  for attempt in 1 2 3; do
    if printf '%s\n' "$manifest" | "$KUBECTL" apply -f -; then return 0; fi
    warn "  Versuch ${attempt} fehlgeschlagen, neuer Versuch in 15 s"
    sleep 15
  done
  return 1
}
if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
  ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
else
  ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
fi
# The name deliberately stays letsencrypt-prod, because the CIVITAS ingresses
# reference it. Only the ACME endpoint changes.
cat <<EOF | apply_with_retry
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: ${ACME_SERVER}
    email: ${LETSENCRYPT_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
# apply_with_retry returns non-zero on failure - without an issuer any
# further rollout is pointless, because no certificate can be issued.
[[ $? -eq 0 ]] || die "ClusterIssuer konnte nicht angelegt werden.
Meist ist der cert-manager-Webhook nicht erreichbar:
  kubectl -n cert-manager get pods
  kubectl -n cert-manager get endpoints cert-manager-webhook"

"$KUBECTL" wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=120s \
  || warn "ClusterIssuer noch nicht Ready - kubectl describe clusterissuer letsencrypt-prod"

# ---------------------------------------------------------------------------
# 6 – CoreDNS split horizon
# ---------------------------------------------------------------------------

apply_coredns_hosts() {  # $@ = FQDNs
  local entries=""
  for fqdn in "$@"; do
    entries+="        ${NODE_IP} ${fqdn}"$'\n'
  done
  # In k3s do NOT edit the coredns ConfigMap - it is overwritten by the auto-deploy
  # controller on restart. The intended way is the
  # ConfigMap coredns-custom, which the Corefile pulls in via import.
  #
  # IMPORTANT: key ending in .server, not .override. An .override lands
  # in the existing .:53 block, which already contains
  #   hosts /etc/coredns/NodeHosts
  # from the k3s default Corefile. CoreDNS then aborts on start with
  #   plugin/hosts: this plugin can only be used once per Server Block
  # A .server instead creates a separate server block for the domain,
  # in which hosts appears only once.
  #
  # fallthrough + forward make sure all other names under this
  # domain are still resolved via the normal resolver.
  cat <<EOF | "$KUBECTL" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  civitas.server: |
    ${DOMAIN}:53 {
      errors
      cache 30
      hosts {
${entries}        fallthrough
      }
      forward . /etc/resolv.conf
    }
EOF
  # Remove leftovers from older runs, otherwise a second hosts block
  # keeps being imported into the .:53 block.
  "$KUBECTL" -n kube-system patch cm coredns-custom --type=json \
    -p='[{"op":"remove","path":"/data/civitas.override"}]' >/dev/null 2>&1 || true

  "$KUBECTL" -n kube-system rollout restart deployment coredns >/dev/null
  if ! "$KUBECTL" -n kube-system rollout status deployment coredns --timeout=120s >/dev/null; then
    warn "CoreDNS kommt nicht hoch. Ursache ansehen:"
    warn "  kubectl -n kube-system logs deploy/coredns --tail=20"
    warn "Notbremse: kubectl -n kube-system delete cm coredns-custom && kubectl -n kube-system rollout restart deployment coredns"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 5b – Switching between staging and production
#
# cert-manager does NOT renew a certificate just because the ACME endpoint
# changed - the existing secret is still formally valid. On a
# switch the TLS secrets therefore have to go, otherwise the old
# certificate stays and NiFi keeps failing on the truststore.
# ---------------------------------------------------------------------------

log "Vorhandene Zertifikate gegen den ACME-Modus pruefen"
stale=0
while read -r secret; do
  [[ -n "$secret" ]] || continue
  issuer=$("$KUBECTL" -n "$NS" get secret "$secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null \
    | base64 -d 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
  [[ -n "$issuer" ]] || continue
  is_staging=false
  grep -q "STAGING" <<<"$issuer" && is_staging=true
  if [[ "$is_staging" != "$LETSENCRYPT_STAGING" ]]; then
    echo "  ${secret}: Aussteller passt nicht zum Modus - wird verworfen"
    "$KUBECTL" -n "$NS" delete secret "$secret" >/dev/null 2>&1 || true
    stale=$((stale+1))
  fi
done < <("$KUBECTL" -n "$NS" get secret -l cert-manager.io/certificate-name \
          -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if (( stale > 0 )); then
  echo "  ${stale} Secret(s) entfernt, cert-manager stellt neu aus"
else
  echo "  nichts zu tun"
fi

log "CoreDNS-Split-Horizon setzen"
apply_coredns_hosts "${HOST_FQDNS[@]}" || die "CoreDNS-Konfiguration fehlgeschlagen - siehe Hinweise oben."
printf '  %s\n' "${HOST_FQDNS[@]}"

# ---------------------------------------------------------------------------
# 7 – Namespace and secrets
# ---------------------------------------------------------------------------

log "Namespace ${NS}"
"$KUBECTL" create namespace "$NS" --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null

log "Secret keycloak-smtp"
if [[ -n "${SMTP_HOST:-}" ]]; then
  "$KUBECTL" create secret generic keycloak-smtp -n "$NS" \
    --from-literal=host="${SMTP_HOST}" \
    --from-literal=port="${SMTP_PORT:-587}" \
    --from-literal=from="${SMTP_FROM:-}" \
    --from-literal=user="${SMTP_USER:-}" \
    --from-literal=password="${SMTP_PASSWORD:-}" \
    --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
  echo "  gesetzt (${SMTP_HOST})"
else
  warn "SMTP_HOST leer - Keycloak kann keine Einladungs- und Passwort-Mails versenden."
fi

log "Secret custom-ca-cert (Truststore fuer NiFi)"
# NiFi checks outgoing TLS connections against this truststore. If it contains
# the wrong root, the pod dies in CrashLoopBackOff with
#   SunCertPathBuilderException: unable to find valid certification path
# In staging mode certificates are not signed by ISRG but by the staging CA -
# its root then has to be added as well.
[[ -f "$ISRG_PEM" ]] || curl -fsSL -o "$ISRG_PEM" https://letsencrypt.org/certs/isrgrootx1.pem
CA_BUNDLE="$ISRG_PEM"
if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
  STG_PEM="/opt/civitas/letsencrypt-stg-root-x1.pem"
  [[ -f "$STG_PEM" ]] || curl -fsSL -o "$STG_PEM" https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem \
    || warn "Staging-Root nicht abrufbar - NiFi wird mit Staging-Zertifikaten scheitern."
  if [[ -s "$STG_PEM" ]]; then
    CA_BUNDLE="/opt/civitas/ca-bundle.pem"
    cat "$ISRG_PEM" "$STG_PEM" >"$CA_BUNDLE"
    echo "  Staging-Root ergaenzt"
  fi
fi
"$KUBECTL" create secret generic custom-ca-cert -n "$NS" --from-file=ca.crt="$CA_BUNDLE" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
echo "  gesetzt"

if [[ "$MODE" == "prepare" ]]; then
  log "Modus --prepare: Vorbereitung abgeschlossen, kein helmfile-Lauf."
  exit 0
fi

# ---------------------------------------------------------------------------
# 8 – Rollout
# ---------------------------------------------------------------------------

if [[ "$MODE" == "diff" ]]; then
  log "helmfile diff (Vorschau)"
  helmfile -f "$HELMFILE_OPERATORS" diff -e production || true
  helmfile -f "$HELMFILE_INSTANCE"  diff -e production || true
  exit 0
fi

log "Operatoren ausrollen (Namespace ${OPERATOR_NS})"
if ! helmfile -f "$HELMFILE_OPERATORS" sync -e production; then
  die "helmfile-operators ist fehlgeschlagen. Ursache ansehen:
  cd ${DEPLOY_DIR} && sudo helmfile -f helmfile-operators.yaml -e production --log-level debug sync"
fi

# The operators bring admission webhooks. If the instance part starts too
# early, the postgres-cluster release reproducibly fails with
#   failed calling webhook "mcluster.cnpg.io" ... context deadline exceeded
log "Warten, bis die Operator-Webhooks bereit sind"
if "$KUBECTL" -n "$OPERATOR_NS" wait --for=condition=Available deploy --all --timeout=300s >/dev/null 2>&1; then
  echo "  Operatoren bereit"
else
  warn "Nicht alle Operator-Deployments sind nach 5 Minuten Available:"
  "$KUBECTL" -n "$OPERATOR_NS" get pods 2>/dev/null | sed 's/^/    /'
  warn "Der naechste Schritt kann am CNPG-Webhook scheitern."
fi
sleep 15

log "Instanz ausrollen (dauert beim ersten Mal einige Minuten)"
if ! helmfile -f "$HELMFILE_INSTANCE" sync -e production; then
  die "helmfile-instance ist fehlgeschlagen. Ursache ansehen:
  cd ${DEPLOY_DIR} && sudo helmfile -f helmfile-instance.yaml.gotmpl -e production --log-level debug sync

Scheitert das Release postgres-cluster am Webhook mcluster.cnpg.io, ist der
CNPG-Operator noch nicht bereit. Pruefen mit:
  kubectl -n ${OPERATOR_NS} get pods
und danach dieses Skript erneut aufrufen."
fi

# helmfile also exits with 0 if it found no releases at all
# - e.g. with a different repo structure or the wrong environment.
releases=$(helm list -n "$NS" -q 2>/dev/null | wc -l)
if (( releases == 0 )); then
  warn "helmfile lief durch, aber im Namespace ${NS} existiert kein Release."
  warn "Was helmfile ueberhaupt sieht:"
  warn "  cd ${DEPLOY_DIR} && sudo helmfile -f helmfile-instance.yaml.gotmpl -e production list"
  die "Kein Rollout erfolgt - Abbruch."
fi
echo "  ${releases} Release(s) im Namespace ${NS}"

# ---------------------------------------------------------------------------
# 9 – Update CoreDNS from the actual ingresses
# ---------------------------------------------------------------------------

log "CoreDNS-Eintraege aus den tatsaechlichen Ingresses aktualisieren"
mapfile -t ing_hosts < <("$KUBECTL" get ingress -n "$NS" \
  -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' \
  2>/dev/null | grep -v '^$' | sort -u || true)
if (( ${#ing_hosts[@]} > 0 )); then
  apply_coredns_hosts "${ing_hosts[@]}"
  printf '  %s\n' "${ing_hosts[@]}"
else
  warn "Keine Ingress-Hosts gefunden - es bleiben die Standardnamen."
fi

# ---------------------------------------------------------------------------
# 10 – Verification
# ---------------------------------------------------------------------------

log "Warte auf Zertifikate (bis zu 10 Minuten)"
if [[ "$("$KUBECTL" get certificate -n "$NS" --no-headers 2>/dev/null | wc -l)" == "0" ]]; then
  warn "Es existiert kein einziges Certificate-Objekt - Warten waere sinnlos."
  warn "Pruefen: kubectl -n ${NS} get ingress && kubectl -n ${NS} get events --sort-by=.lastTimestamp | tail -20"
  die "Abbruch."
fi
deadline=$(( $(date +%s) + 600 ))
while (( $(date +%s) < deadline )); do
  total=$("$KUBECTL" get certificate -n "$NS" --no-headers 2>/dev/null | wc -l)
  ready=$("$KUBECTL" get certificate -n "$NS" -o json 2>/dev/null \
    | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
  printf '\r  %s/%s Certificates Ready' "${ready:-0}" "${total:-0}"
  [[ -n "${total:-}" && "${total:-0}" -gt 0 && "${ready:-0}" == "${total}" ]] && break
  sleep 15
done
echo

log "Status"
"$KUBECTL" get pods -n "$NS" --no-headers | awk '{print $3}' | sort | uniq -c
echo
"$KUBECTL" get certificate -n "$NS" 2>/dev/null || true

not_ready=$("$KUBECTL" get pods -n "$NS" --no-headers 2>/dev/null \
  | awk '$3 != "Running" && $3 != "Completed" {print "  " $1 " " $3}')
if [[ -n "$not_ready" ]]; then
  warn "Pods ohne Running/Completed:"
  echo "$not_ready"
fi

KC_PW=$("$KUBECTL" get secret keycloak-admin-user -n "$NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)

cat <<EOF

------------------------------------------------------------------
Deployment abgeschlossen.

$(printf '  https://%s\n' "${HOST_FQDNS[@]}")

  Keycloak-Realm: ${INSTANCE_SLUG} (https://idm.${DOMAIN})

  Keycloak-Admin-Passwort: ${KC_PW:-<Secret keycloak-admin-user noch nicht vorhanden>}

Nuetzlich:
  kubectl get pods -n ${NS} -w
  kubectl get certificate,order,challenge -n ${NS}
  helmfile -f "$HELMFILE_INSTANCE" apply -e production --selector component=keycloak
  sudo $0 --reset      # Instanz komplett neu aufbauen
------------------------------------------------------------------
EOF
