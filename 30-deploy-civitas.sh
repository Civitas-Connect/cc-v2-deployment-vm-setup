#!/usr/bin/env bash
#
# 30-deploy-civitas.sh
#
# Laeuft auf dem frisch geklonten Node und macht alles, was Domain oder IP kennt:
#   - ClusterIssuer (Let's Encrypt prod oder staging)
#   - CoreDNS-Split-Horizon ueber die coredns-custom ConfigMap
#   - Namespace, keycloak-smtp, custom-ca-cert
#   - global.yaml.gotmpl rendern und helmfile sync
#   - CoreDNS-Eintraege aus den tatsaechlichen Ingresses nachziehen
#
# Voraussetzung: /etc/civitas/deploy.env (Vorlage: /etc/civitas/deploy.env.example)
#                Node ist personalisiert (./25-postclone-setup.sh gelaufen)
#
# Aufruf:
#   sudo ./30-deploy-civitas.sh              # voller Rollout
#   sudo ./30-deploy-civitas.sh --diff       # nur Vorschau, aendert nichts am Release
#   sudo ./30-deploy-civitas.sh --reset      # Instanz loeschen und neu aufbauen
#   sudo ./30-deploy-civitas.sh --prepare    # nur Issuer/DNS/Namespace/Secrets
#

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECTL=/usr/local/bin/kubectl

MODE="deploy"
case "${1:-}" in
  --diff)    MODE="diff" ;;
  --reset)   MODE="reset" ;;
  --prepare) MODE="prepare" ;;
  "")        ;;
  *)         die "Unbekannte Option: $1" ;;
esac

# ---------------------------------------------------------------------------
# 1 – Konfiguration laden und pruefen
# ---------------------------------------------------------------------------

# Versiegeltes Image: civitas-firstboot hat noch nicht gelaufen. Ein Deployment
# wuerde beim naechsten Boot komplett neu personalisiert und damit zerlegt.
[[ -e /etc/civitas/sealed ]] \
  && die "Diese VM ist noch versiegelt (/etc/civitas/sealed). Erst neu starten, dann ./25-postclone-setup.sh, dann dieses Skript."

ENV_FILE=/etc/civitas/deploy.env
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE fehlt. Vorlage: cp /etc/civitas/deploy.env.example $ENV_FILE"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

: "${DOMAIN:?DOMAIN fehlt in $ENV_FILE}"
: "${INSTANCE_SLUG:?INSTANCE_SLUG fehlt in $ENV_FILE}"
: "${INITIAL_USER_EMAIL:?INITIAL_USER_EMAIL fehlt in $ENV_FILE}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL fehlt in $ENV_FILE}"
LETSENCRYPT_STAGING="${LETSENCRYPT_STAGING:-false}"
EXTRA_HOSTS="${EXTRA_HOSTS:-}"

NS="$INSTANCE_SLUG"
CIVITAS_DIR="${CIVITAS_DIR:-/opt/civitas/civitas-core-deployment}"
WORK_DIR="/opt/civitas/rendered"
ISRG_PEM="/opt/civitas/isrg-root-x1.pem"

if [[ -z "${NODE_IP:-}" ]]; then
  NODE_IP=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  [[ -n "$NODE_IP" ]] || NODE_IP=$(ip -4 route get 1.1.1.1 | awk '{print $7; exit}')
fi
[[ -n "$NODE_IP" ]] || die "Node-IP konnte nicht ermittelt werden. NODE_IP in $ENV_FILE setzen."

# Stimmt die Node-IP nicht mit der tatsaechlichen Adresse ueberein, hat k3s den
# IP-Wechsel nach dem Klonen nicht mitbekommen. Der CoreDNS-Split-Horizon
# weiter unten wuerde dann auf die alte Adresse zeigen.
HOST_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
if [[ -n "$HOST_IP" && "$HOST_IP" != "$NODE_IP" ]]; then
  die "k3s meldet Node-IP ${NODE_IP}, die Maschine hat aber ${HOST_IP}.
Erst korrigieren: sudo ./25-postclone-setup.sh --check
Danach: sudo ./25-postclone-setup.sh --hostname \$(hostname) --ip ${HOST_IP}/<praefix> --gateway <gw> --dns <dns>"
fi

CORE_HOSTS=(api idm portal dashboard)
for h in $EXTRA_HOSTS; do CORE_HOSTS+=("$h"); done

log "Konfiguration"
printf '  Domain          : %s\n' "$DOMAIN"
printf '  Instance / NS   : %s\n' "$INSTANCE_SLUG"
printf '  Node-IP         : %s\n' "$NODE_IP"
printf '  ACME            : %s\n' "$([[ "$LETSENCRYPT_STAGING" == "true" ]] && echo staging || echo production)"
printf '  Repo-Tag        : %s\n' "$(git -C "$CIVITAS_DIR" describe --tags --always 2>/dev/null || echo '?')"

# ---------------------------------------------------------------------------
# 2 – Cluster-Voraussetzungen pruefen
# ---------------------------------------------------------------------------

log "Cluster pruefen"
"$KUBECTL" get node >/dev/null 2>&1 || die "Kein erreichbarer Cluster. journalctl -u k3s -n 100"
"$KUBECTL" get node | grep -qw Ready || die "Node ist nicht Ready."

for check in "ingress-nginx:daemonset/ingress-nginx-controller" "cert-manager:deployment/cert-manager"; do
  ns="${check%%:*}"; obj="${check##*:}"
  "$KUBECTL" -n "$ns" get "$obj" >/dev/null 2>&1 \
    || die "$obj in $ns fehlt. Nach einem Sysprep mit --reset-cluster erst: ./10-build-template.sh --addons-only"
done
echo "  ingress-nginx und cert-manager sind vorhanden."

log "Oeffentliche DNS-Aufloesung pruefen"
dns_ok=true
for h in "${CORE_HOSTS[@]}"; do
  resolved=$(getent ahostsv4 "${h}.${DOMAIN}" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -z "$resolved" ]]; then
    warn "  ${h}.${DOMAIN} loest nicht auf"; dns_ok=false
  elif [[ "$resolved" != "$NODE_IP" ]]; then
    warn "  ${h}.${DOMAIN} -> ${resolved} (erwartet ${NODE_IP})"; dns_ok=false
  else
    echo "  ${h}.${DOMAIN} -> ${resolved}"
  fi
done
if ! $dns_ok; then
  warn "Solange DNS nicht stimmt, scheitert die HTTP-01-Challenge. Mit LETSENCRYPT_STAGING=true testen."
  read -r -p "Trotzdem fortfahren? [ja/NEIN] " a; [[ "$a" == "ja" ]] || exit 1
fi

# ---------------------------------------------------------------------------
# 3 – Reset (optional)
# ---------------------------------------------------------------------------

if [[ "$MODE" == "reset" ]]; then
  log "Instanz ${NS} zuruecksetzen"
  if [[ -d "${WORK_DIR}/deployment" ]]; then
    helmfile -f "${WORK_DIR}/deployment/helmfile.yaml" destroy -e production || warn "helmfile destroy mit Fehlern"
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
# 4 – ClusterIssuer
# ---------------------------------------------------------------------------

log "ClusterIssuer letsencrypt-prod"
if [[ "$LETSENCRYPT_STAGING" == "true" ]]; then
  ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
else
  ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
fi
# Der Name bleibt bewusst letsencrypt-prod, weil die CIVITAS-Ingresses ihn
# referenzieren. Nur der ACME-Endpunkt wechselt.
cat <<EOF | "$KUBECTL" apply -f -
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
"$KUBECTL" wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=120s \
  || warn "ClusterIssuer noch nicht Ready - kubectl describe clusterissuer letsencrypt-prod"

# ---------------------------------------------------------------------------
# 5 – CoreDNS Split-Horizon
# ---------------------------------------------------------------------------

apply_coredns_hosts() {  # $@ = FQDNs
  local entries=""
  for fqdn in "$@"; do
    entries+="        ${NODE_IP} ${fqdn}"$'\n'
  done
  # In k3s NICHT die coredns-ConfigMap editieren - die wird vom Auto-Deploy-
  # Controller beim Neustart ueberschrieben. Der vorgesehene Weg ist die
  # ConfigMap coredns-custom, die das Corefile per import einbindet.
  #
  # WICHTIG: Schluessel auf .server, nicht auf .override. Ein .override landet
  # im bestehenden .:53-Block, und dort steht bereits
  #   hosts /etc/coredns/NodeHosts
  # aus dem k3s-Standard-Corefile. CoreDNS bricht dann beim Start ab mit
  #   plugin/hosts: this plugin can only be used once per Server Block
  # Ein .server erzeugt stattdessen einen eigenen Server-Block fuer die Domain,
  # in dem hosts nur einmal vorkommt.
  #
  # fallthrough + forward sorgen dafuer, dass alle anderen Namen unter dieser
  # Domain weiterhin ueber den normalen Resolver aufgeloest werden.
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
  # Rueckstaende aus aelteren Laeufen entfernen, sonst wird weiterhin ein
  # zweiter hosts-Block in den .:53-Block importiert.
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

log "CoreDNS-Split-Horizon setzen"
fqdns=()
for h in "${CORE_HOSTS[@]}"; do fqdns+=("${h}.${DOMAIN}"); done
apply_coredns_hosts "${fqdns[@]}" || die "CoreDNS-Konfiguration fehlgeschlagen - siehe Hinweise oben."
printf '  %s\n' "${fqdns[@]}"

# ---------------------------------------------------------------------------
# 6 – Namespace und Secrets
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
[[ -f "$ISRG_PEM" ]] || curl -fsSL -o "$ISRG_PEM" https://letsencrypt.org/certs/isrgrootx1.pem
"$KUBECTL" create secret generic custom-ca-cert -n "$NS" --from-file=ca.crt="$ISRG_PEM" \
  --dry-run=client -o yaml | "$KUBECTL" apply -f - >/dev/null
echo "  gesetzt"

if [[ "$MODE" == "prepare" ]]; then
  log "Modus --prepare: Vorbereitung abgeschlossen, kein helmfile-Lauf."
  exit 0
fi

# ---------------------------------------------------------------------------
# 7 – Deployment-Verzeichnis rendern
# ---------------------------------------------------------------------------

log "Deployment-Verzeichnis unter ${WORK_DIR} aufbauen"
[[ -d "$CIVITAS_DIR" ]] || die "$CIVITAS_DIR fehlt - im Template wurde das Repo nicht geklont."
mkdir -p "$WORK_DIR"
rm -rf "${WORK_DIR}/deployment"
cp -r "${CIVITAS_DIR}/defaults/deployment" "${WORK_DIR}/deployment"

GLOBAL="${WORK_DIR}/deployment/environments/production/global.yaml.gotmpl"
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
EOF
echo "  global.yaml.gotmpl geschrieben"

HELMFILE_ARGS=(-f "${WORK_DIR}/deployment/helmfile.yaml")

# ---------------------------------------------------------------------------
# 8 – Rollout
# ---------------------------------------------------------------------------

if [[ "$MODE" == "diff" ]]; then
  log "helmfile diff (Vorschau)"
  helmfile "${HELMFILE_ARGS[@]}" diff -e production || true
  exit 0
fi

log "helmfile sync (dauert beim ersten Mal einige Minuten)"
helmfile "${HELMFILE_ARGS[@]}" sync -e production

# ---------------------------------------------------------------------------
# 9 – CoreDNS aus den echten Ingresses nachziehen
# ---------------------------------------------------------------------------

log "CoreDNS-Eintraege aus den tatsaechlichen Ingresses aktualisieren"
mapfile -t ing_hosts < <("$KUBECTL" get ingress -n "$NS" \
  -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' \
  2>/dev/null | grep -v '^$' | sort -u || true)
if (( ${#ing_hosts[@]} > 0 )); then
  apply_coredns_hosts "${ing_hosts[@]}"
  printf '  %s\n' "${ing_hosts[@]}"
else
  warn "Keine Ingress-Hosts gefunden - es bleiben die vier Standardnamen."
fi

# ---------------------------------------------------------------------------
# 10 – Verifikation
# ---------------------------------------------------------------------------

log "Warte auf Zertifikate (bis zu 10 Minuten)"
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

  Portal     https://portal.${DOMAIN}
  Keycloak   https://idm.${DOMAIN}      (Realm ${INSTANCE_SLUG})
  API        https://api.${DOMAIN}      (Routen unter /v1)
  Dashboards https://dashboard.${DOMAIN}

  Keycloak-Admin-Passwort: ${KC_PW:-<Secret keycloak-admin-user noch nicht vorhanden>}

Nuetzlich:
  kubectl get pods -n ${NS} -w
  kubectl get certificate,order,challenge -n ${NS}
  helmfile -f ${WORK_DIR}/deployment/helmfile.yaml apply -e production --selector component=keycloak
  sudo $0 --reset      # Instanz komplett neu aufbauen
------------------------------------------------------------------
EOF
