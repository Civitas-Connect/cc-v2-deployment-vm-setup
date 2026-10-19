#!/usr/bin/env bash
#
# 40-verify-civitas.sh
#
# Checks a deployed CIVITAS/CORE V2 instance from the bottom up:
# node, system services, operators, Helm releases, pods, PVCs, ingresses,
# certificates, DNS and actual HTTPS reachability.
#
# Changes nothing. Can run at any time, even while a deployment is still
# in progress - the findings are then incomplete accordingly.
#
# Usage:
#   bash ./40-verify-civitas.sh              # reads /etc/civitas/deploy.env
#   bash ./40-verify-civitas.sh --ns demo    # set the namespace directly
#   bash ./40-verify-civitas.sh --quiet      # only problems and summary
#
# Exit code: 0 = all green, 1 = warnings, 2 = errors.
# This makes it usable in monitoring or a pipeline.
#

set -uo pipefail

# ---------------------------------------------------------------------------

BOLD=$'\033[1m'; RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'
BLU=$'\033[1;34m'; OFF=$'\033[0m'

FAILS=0
WARNS=0
QUIET=false

section() { printf '\n%s== %s ==%s\n' "$BLU" "$*" "$OFF"; }
pass()    { $QUIET || printf '  %s[ok]%s   %s\n' "$GRN" "$OFF" "$*"; }
warn()    { printf '  %s[warn]%s %s\n' "$YEL" "$OFF" "$*"; WARNS=$((WARNS+1)); }
fail()    { printf '  %s[FAIL]%s %s\n' "$RED" "$OFF" "$*"; FAILS=$((FAILS+1)); }
info()    { $QUIET || printf '  %s\n' "$*"; }
hint()    { $QUIET || printf '         %s-> %s%s\n' "$BOLD" "$*" "$OFF"; }

# ---------------------------------------------------------------------------
# Parameters and configuration
# ---------------------------------------------------------------------------

NS=""
ENV_FILE="${ENV_FILE:-/etc/civitas/deploy.env}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ns)     NS="${2:?}"; shift 2 ;;
    --env)    ENV_FILE="${2:?}"; shift 2 ;;
    --quiet)  QUIET=true; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

KUBECTL=/usr/local/bin/kubectl
[[ -x "$KUBECTL" ]] || KUBECTL=$(command -v kubectl 2>/dev/null || echo kubectl)
[[ -n "${KUBECONFIG:-}" ]] || export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

DOMAIN=""; PUBLIC_IP=""; LETSENCRYPT_STAGING=""
if [[ -r "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  [[ -n "$NS" ]] || NS="${INSTANCE_SLUG:-}"
fi

[[ -n "$NS" ]] || { echo "Namespace unknown. Pass --ns or make ${ENV_FILE} readable." >&2; exit 2; }

OPERATOR_NS="${OPERATOR_NS:-civitas-operators}"
# Only used if the namespace has no ingresses yet. Otherwise the host names
# come from the actual ingresses, so hosts added in future releases are
# checked automatically (like management in v2.0.0).
FALLBACK_HOSTS=(api idm portal dashboard management)

printf '%sCIVITAS/CORE – verification%s\n' "$BOLD" "$OFF"
printf '  Namespace : %s\n' "$NS"
printf '  Domain    : %s\n' "${DOMAIN:-<unknown>}"
printf '  ACME      : %s\n' "$([[ "${LETSENCRYPT_STAGING:-}" == "true" ]] && echo staging || echo production)"
printf '  Time      : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ---------------------------------------------------------------------------
section "1 – Cluster and node"
# ---------------------------------------------------------------------------

if ! "$KUBECTL" get --raw=/readyz >/dev/null 2>&1; then
  fail "k3s API not reachable"
  hint "journalctl -u k3s -n 100 --no-pager"
  printf '\nAborting: no further checks are possible without the API.\n'
  exit 2
fi
pass "k3s API reachable"

node_line=$("$KUBECTL" get node --no-headers 2>/dev/null | head -1)
node_name=$(awk '{print $1}' <<<"$node_line")
node_stat=$(awk '{print $2}' <<<"$node_line")
node_ip=$("$KUBECTL" get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
host_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

[[ "$node_stat" == "Ready" ]] && pass "Node ${node_name}: Ready" || fail "Node ${node_name}: ${node_stat}"

if [[ -n "$host_ip" && "$node_ip" != "$host_ip" ]]; then
  fail "Node InternalIP ${node_ip} differs from the machine address ${host_ip}"
  hint "sudo bash 25-postclone-setup.sh --check"
else
  pass "Node IP ${node_ip}"
fi

# Certificates dated in the future are the most common killer after cloning.
crt=/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
if [[ -r "$crt" ]]; then
  nb=$(openssl x509 -in "$crt" -noout -startdate 2>/dev/null | cut -d= -f2)
  if [[ -n "$nb" ]] && (( $(date -d "$nb" +%s 2>/dev/null || echo 0) > $(date +%s) )); then
    fail "k3s certificate only valid from ${nb} (clock was wrong at boot)"
    hint "systemctl stop k3s && k3s certificate rotate && systemctl start k3s"
  else
    pass "k3s certificate valid since ${nb}"
  fi
fi

[[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] \
  && pass "System time synchronized" \
  || warn "System time not synchronized"

avail=$(df --output=avail -BG / 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$avail" ]]; then
  (( avail < 10 )) && warn "only ${avail}G free on /" || pass "${avail}G free on /"
fi

# ---------------------------------------------------------------------------
section "2 – Base services"
# ---------------------------------------------------------------------------

for chk in "cert-manager:deployment/cert-manager" \
           "cert-manager:deployment/cert-manager-webhook" \
           "cert-manager:deployment/cert-manager-cainjector" \
           "ingress-nginx:daemonset/ingress-nginx-controller"; do
  ns="${chk%%:*}"; obj="${chk##*:}"
  if ! "$KUBECTL" -n "$ns" get "$obj" >/dev/null 2>&1; then
    fail "${obj} missing in ${ns}"
    continue
  fi
  if "$KUBECTL" -n "$ns" rollout status "$obj" --timeout=10s >/dev/null 2>&1; then
    pass "${obj}"
  else
    fail "${obj} not ready"
    hint "kubectl -n ${ns} get pods"
  fi
done

eps=$("$KUBECTL" -n cert-manager get endpoints cert-manager-webhook \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
[[ -n "$eps" ]] && pass "cert-manager-webhook has endpoints" \
  || fail "cert-manager-webhook has no endpoints - ClusterIssuer cannot be created"

if "$KUBECTL" get clusterissuer letsencrypt-prod >/dev/null 2>&1; then
  ready=$("$KUBECTL" get clusterissuer letsencrypt-prod \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  server=$("$KUBECTL" get clusterissuer letsencrypt-prod -o jsonpath='{.spec.acme.server}' 2>/dev/null)
  mode=$(grep -q staging <<<"$server" && echo staging || echo production)
  [[ "$ready" == "True" ]] && pass "ClusterIssuer letsencrypt-prod Ready (${mode})" \
    || fail "ClusterIssuer not Ready (${mode})"
  if [[ -n "${LETSENCRYPT_STAGING:-}" ]]; then
    want=$([[ "$LETSENCRYPT_STAGING" == "true" ]] && echo staging || echo production)
    [[ "$mode" == "$want" ]] || warn "Issuer is set to ${mode}, deploy.env says ${want}"
  fi
else
  fail "ClusterIssuer letsencrypt-prod missing"
fi

# CoreDNS split horizon
if "$KUBECTL" -n kube-system get cm coredns-custom >/dev/null 2>&1; then
  keys=$("$KUBECTL" -n kube-system get cm coredns-custom -o jsonpath='{range .data.*}{@}{end}' >/dev/null 2>&1; \
         "$KUBECTL" -n kube-system get cm coredns-custom -o jsonpath='{.data}' 2>/dev/null)
  if grep -q 'override' <<<"$keys"; then
    fail "coredns-custom uses an .override key - CoreDNS aborts with it"
    hint "key must end in .server (separate server block)"
  else
    pass "coredns-custom present"
  fi
  if "$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=10s >/dev/null 2>&1; then
    pass "CoreDNS running"
  else
    fail "CoreDNS not ready"
    hint "kubectl -n kube-system logs deploy/coredns --tail=20"
  fi
else
  warn "coredns-custom missing - no split horizon, pods resolve the hosts via the public IP"
fi

# ---------------------------------------------------------------------------
section "3 – Operators"
# ---------------------------------------------------------------------------

if "$KUBECTL" get ns "$OPERATOR_NS" >/dev/null 2>&1; then
  # Via jsonpath instead of the READY column: awk has no
  # backreferences, so "1/1" could not be checked cleanly otherwise.
  not_ready=$("$KUBECTL" -n "$OPERATOR_NS" get deploy \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.readyReplicas}{" "}{.spec.replicas}{"\n"}{end}' \
    2>/dev/null | awk '$2 != $3 || $2 == "" {print $1}')
  if [[ -z "$not_ready" ]]; then
    pass "all deployments in ${OPERATOR_NS} ready"
  else
    fail "not ready in ${OPERATOR_NS}: $(tr '\n' ' ' <<<"$not_ready")"
  fi
  # The CNPG webhook is where postgres-cluster reproducibly fails.
  cnpg=$("$KUBECTL" -n "$OPERATOR_NS" get endpoints -o name 2>/dev/null | grep -i cnpg | head -1)
  if [[ -n "$cnpg" ]]; then
    cnpg_eps=$("$KUBECTL" -n "$OPERATOR_NS" get "$cnpg" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    [[ -n "$cnpg_eps" ]] && pass "CNPG webhook has endpoints" || fail "CNPG webhook has no endpoints"
  fi
else
  warn "Namespace ${OPERATOR_NS} does not exist"
fi

# ---------------------------------------------------------------------------
section "4 – Helm releases"
# ---------------------------------------------------------------------------

if ! command -v helm >/dev/null 2>&1; then
  warn "helm not found, release check skipped"
else
  mapfile -t rel < <(helm list -n "$NS" --no-headers 2>/dev/null | awk '{print $1" "$8}')
  if (( ${#rel[@]} == 0 )); then
    fail "no Helm release in namespace ${NS} - nothing has been rolled out"
    hint "cd /opt/civitas/rendered/repo/deployment && sudo helmfile -f helmfile-instance.yaml.gotmpl -e production list"
  else
    bad=0
    for r in "${rel[@]}"; do
      name="${r%% *}"; status="${r##* }"
      [[ "$status" == "deployed" ]] || { fail "Release ${name}: ${status}"; bad=$((bad+1)); }
    done
    (( bad == 0 )) && pass "${#rel[@]} release(s), all deployed"
    pend=$(helm list -n "$NS" --pending -q 2>/dev/null | tr '\n' ' ')
    [[ -n "${pend// }" ]] && fail "stuck: ${pend}" && hint "helm rollback <release> -n ${NS}"
  fi
fi

# ---------------------------------------------------------------------------
section "5 – Pods and storage"
# ---------------------------------------------------------------------------

if ! "$KUBECTL" get ns "$NS" >/dev/null 2>&1; then
  fail "Namespace ${NS} does not exist"
else
  total=0; bad=0
  while read -r pod phase ready; do
    [[ -n "$pod" ]] || continue
    total=$((total+1))
    # Jobs run to completion and stay in Succeeded - that is fine.
    [[ "$phase" == "Succeeded" ]] && continue
    if [[ "$phase" != "Running" || "$ready" != "true" ]]; then
      fail "Pod ${pod}: ${phase}, ready=${ready}"
      bad=$((bad+1))
    fi
  done < <("$KUBECTL" -n "$NS" get pods --no-headers \
            -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[0].ready \
            2>/dev/null)
  if (( total == 0 )); then
    fail "no pods in namespace ${NS}"
  elif (( bad == 0 )); then
    pass "${total} pods, all Running/Succeeded"
  else
    hint "kubectl -n ${NS} describe pod <name> | tail -25"
  fi

  # Common side effect: restarts point to a problem that recovers
  # by itself - e.g. a truststore that doesn't match.
  restarts=$("$KUBECTL" -n "$NS" get pods --no-headers 2>/dev/null \
    | awk '$4 > 5 {print $1" ("$4"x)"}' | tr '\n' ' ')
  [[ -n "${restarts// }" ]] && warn "many restarts: ${restarts}"

  pend_pvc=$("$KUBECTL" -n "$NS" get pvc --no-headers 2>/dev/null | awk '$2 != "Bound" {print $1}' | tr '\n' ' ')
  if [[ -n "${pend_pvc// }" ]]; then
    fail "PVC not Bound: ${pend_pvc}"
    hint "kubectl -n ${NS} describe pvc <name> | tail -10"
  else
    n=$("$KUBECTL" -n "$NS" get pvc --no-headers 2>/dev/null | wc -l)
    (( n > 0 )) && pass "${n} PVC(s) Bound"
  fi
fi

# ---------------------------------------------------------------------------
section "6 – Ingresses and certificates"
# ---------------------------------------------------------------------------

ing=$("$KUBECTL" -n "$NS" get ingress --no-headers 2>/dev/null | wc -l)
(( ing > 0 )) && pass "${ing} ingress(es)" || fail "no ingress in namespace ${NS}"

certs=$("$KUBECTL" -n "$NS" get certificate --no-headers 2>/dev/null)
if [[ -z "$certs" ]]; then
  fail "no Certificate object"
else
  while read -r name ready rest; do
    [[ -n "$name" ]] || continue
    [[ "$ready" == "True" ]] && pass "Certificate ${name}: Ready" || fail "Certificate ${name}: ${ready}"
  done <<<"$certs"

  # Pending challenges usually state the cause directly.
  ch=$("$KUBECTL" -n "$NS" get challenge --no-headers 2>/dev/null | wc -l)
  (( ch > 0 )) && warn "${ch} pending challenge(s)" && hint "kubectl -n ${NS} describe challenge | tail -25"
fi

# ---------------------------------------------------------------------------
section "7 – DNS and reachability"
# ---------------------------------------------------------------------------

# Host names from the instance's ingresses, fallback list only without ingresses.
mapfile -t HOST_FQDNS < <("$KUBECTL" -n "$NS" get ingress \
  -o jsonpath='{range .items[*]}{range .spec.rules[*]}{.host}{"\n"}{end}{end}' \
  2>/dev/null | grep -v '^$' | sort -u)
if (( ${#HOST_FQDNS[@]} == 0 )) && [[ -n "$DOMAIN" ]]; then
  info "no ingress hosts found, using the default list"
  for h in "${FALLBACK_HOSTS[@]}"; do HOST_FQDNS+=("${h}.${DOMAIN}"); done
fi

if (( ${#HOST_FQDNS[@]} == 0 )); then
  warn "no host names known (no ingresses, DOMAIN unknown), DNS check skipped"
else
  declare -A addrs=()
  for fqdn in "${HOST_FQDNS[@]}"; do
    r=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk 'NR==1{print $1}')
    [[ -n "$r" ]] && addrs["$r"]=1 || fail "${fqdn} does not resolve"
  done
  if (( ${#addrs[@]} == 1 )); then
    a="${!addrs[*]}"
    if [[ "$a" == "$node_ip" ]]; then
      pass "DNS points directly to the node IP (${a})"
    elif [[ -n "${PUBLIC_IP:-}" && "$a" == "$PUBLIC_IP" ]]; then
      pass "DNS points to ${a} (NAT as configured)"
    elif [[ -n "${PUBLIC_IP:-}" ]]; then
      fail "DNS points to ${a}, PUBLIC_IP says ${PUBLIC_IP}"
    else
      pass "DNS consistently points to ${a} (NAT assumed)"
    fi
  elif (( ${#addrs[@]} > 1 )); then
    fail "inconsistent addresses: ${!addrs[*]}"
  fi

  # The most meaningful test: TLS handshake against the local ingress with
  # SNI set. This bypasses NAT and hairpin problems completely.
  for fqdn in "${HOST_FQDNS[@]}"; do
    out=$(echo | timeout 15 openssl s_client -connect 127.0.0.1:443 \
          -servername "$fqdn" 2>/dev/null | openssl x509 -noout -subject -issuer -dates 2>/dev/null)
    if [[ -z "$out" ]]; then
      fail "${fqdn}: no TLS handshake"
      continue
    fi
    issuer=$(grep '^issuer' <<<"$out")
    notafter=$(grep '^notAfter' <<<"$out" | cut -d= -f2)
    days=$(( ( $(date -d "$notafter" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    if grep -qi staging <<<"$issuer"; then
      if [[ "${LETSENCRYPT_STAGING:-}" == "true" ]]; then
        pass "${fqdn}: staging certificate, ${days} days left (as configured)"
      else
        fail "${fqdn}: still a staging certificate although set to production"
        hint "kubectl -n ${NS} delete secret -l cert-manager.io/certificate-name && 30-deploy-civitas.sh"
      fi
    else
      (( days < 21 )) && warn "${fqdn}: certificate expires in ${days} days" \
        || pass "${fqdn}: valid certificate, ${days} days left"
    fi
  done

  # HTTP-01 needs port 80. Only partially testable from here.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
         -H "Host: ${HOST_FQDNS[0]}" http://127.0.0.1/ 2>/dev/null)
  [[ "$code" =~ ^(200|301|302|308|404)$ ]] && pass "Ingress answers on port 80 (HTTP ${code})" \
    || warn "Ingress does not answer on port 80 as expected (HTTP ${code:-none})"
fi

# ---------------------------------------------------------------------------
section "Summary"
# ---------------------------------------------------------------------------

if (( FAILS == 0 && WARNS == 0 )); then
  printf '  %sAll good.%s\n\n' "$GRN" "$OFF"
  exit 0
elif (( FAILS == 0 )); then
  printf '  %s%d warning(s), no errors.%s\n\n' "$YEL" "$WARNS" "$OFF"
  exit 1
else
  printf '  %s%d error(s)%s, %d warning(s).\n' "$RED" "$FAILS" "$OFF" "$WARNS"
  printf '  Next steps are shown after each arrow.\n\n'
  exit 2
fi
