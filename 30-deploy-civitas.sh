#!/usr/bin/env bash
#
# 30-deploy-civitas.sh
#
# Laeuft auf dem frisch geklonten Node und macht alles, was Domain oder IP kennt:
#   - optional: Skripte unter /opt/civitas/scripts aus dem Git-Repo aktualisieren
#   - Release rendern und daraus die Hostnamen ableiten (keine feste Liste)
#   - ClusterIssuer (Let's Encrypt prod oder staging)
#   - CoreDNS-Split-Horizon ueber die coredns-custom ConfigMap
#   - Namespace, keycloak-smtp, custom-ca-cert
#   - global.yaml.gotmpl rendern, dann helmfile-operators und helmfile-instance
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
#   sudo ./30-deploy-civitas.sh --no-update  # Skripte nicht aus Git aktualisieren
#

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte mit sudo ausfuehren."

# In ein stabiles Verzeichnis wechseln, das dieses Skript garantiert nicht anfasst.
# Wurde das Skript aus /opt/civitas/rendered/... heraus aufgerufen (z.B. weil man
# vorher zum Debuggen dorthin gecd't hat), reisst der spaetere rm -rf/cp -a des
# Repo-Copys (Schritt 7) genau dieses Arbeitsverzeichnis unter dem laufenden Prozess
# weg. Jeder folgende getcwd()-Aufruf - auch in helmfile selbst - schlaegt dann mit
# "no such file or directory" fehl, obwohl unter demselben Pfad laengst wieder ein
# frisches Verzeichnis existiert (neue Inode, alte cwd-Bindung ist aber tot).
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

# ---------------------------------------------------------------------------
# 1a – Skripte aus Git aktualisieren (optional)
#
# Damit kommen Anpassungen an neue CIVITAS-Releases auf bestehende Klone,
# ohne das Image neu zu bauen. Leeres SCRIPTS_REF schaltet das ab.
# ---------------------------------------------------------------------------

SCRIPTS_REPO="${SCRIPTS_REPO:-https://github.com/BronxHD/civitas-core-demo_clone_setup-.git}"
SCRIPTS_REF="${SCRIPTS_REF:-}"
SCRIPTS_DIR=/opt/civitas/scripts
SCRIPTS_SRC=/opt/civitas/scripts-src

update_scripts() {
  # Ohne Terminal-Prompt: ein nicht erreichbares oder privates Repo soll
  # scheitern, nicht auf einen Benutzernamen warten.
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

  # Eine kaputte Fassung darf die funktionierende nicht ersetzen.
  for f in "$SCRIPTS_SRC"/*.sh; do
    bash -n "$f" || { warn "  Syntaxfehler in $(basename "$f") - Aktualisierung verworfen"; return 1; }
  done
  [[ -f "${SCRIPTS_SRC}/30-deploy-civitas.sh" ]] || return 1

  # Neue Datei plus rename statt Ueberschreiben: bash liest das laufende Skript
  # stueckweise nach und wuerde sonst mitten im Lauf in die neue Fassung springen.
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
    # Mit der frischen Fassung von vorn beginnen. Die Markierung verhindert
    # eine Schleife.
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
# Tag oder Branch, von dem deployt wird. Leer = Stand nehmen, der im Image
# ausgecheckt ist. Sonst wird in der Arbeitskopie umgeschaltet, das Repo unter
# CIVITAS_DIR bleibt unberuehrt.
CIVITAS_REF="${CIVITAS_REF:-}"
# Oeffentliche Adresse, auf die die DNS-Namen zeigen, wenn die Instanz hinter
# NAT steht. Leer = wird aus der DNS-Aufloesung abgeleitet.
PUBLIC_IP="${PUBLIC_IP:-}"
WORK_DIR="/opt/civitas/rendered"
# Das gesamte Repo wird kopiert, nicht nur defaults/deployment: helmfile-root.yaml.gotmpl
# liegt im Repo-Root, und defaults/deployment/*.yaml(.gotmpl) referenzieren es ueber
# '../helmfile-root.yaml.gotmpl' - das funktioniert nur, wenn das Deployment-Verzeichnis
# EINE Ebene direkt unter dem Repo-Root liegt, nicht zwei (wie defaults/deployment es tut).
# Genau deshalb kopiert auch das offizielle justfile (Target "deploy") vor jedem Lauf
# "defaults/deployment" nach "deployment" im Repo-Root - das bilden wir unten nach.
REPO_COPY="${WORK_DIR}/repo"
DEPLOY_DIR="${REPO_COPY}/deployment"
# Zwei Einstiegspunkte, in dieser Reihenfolge. helmfile.yaml im selben
# Verzeichnis ist NICHT der richtige Einstieg - sie verweist auf eine
# helmfile-root.yaml.gotmpl, die (nur) im Repo-Root liegt.
HELMFILE_OPERATORS="${DEPLOY_DIR}/helmfile-operators.yaml"
HELMFILE_INSTANCE="${DEPLOY_DIR}/helmfile-instance.yaml.gotmpl"
OPERATOR_NS="${OPERATOR_NS:-civitas-operators}"
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

# Die Hostnamen kommen aus dem gerenderten Release (Schritt 3), damit neue
# Hosts kuenftiger Versionen automatisch geprueft werden - so wie management
# mit v2.0.0 dazukam. Diese Liste greift nur, wenn das nicht klappt.
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
# 2 – Cluster-Voraussetzungen pruefen
# ---------------------------------------------------------------------------

# Der Rollout laeuft viele Minuten ohne Ausgabe. Reisst die SSH-Sitzung ab,
# stirbt helmfile mitten im Upgrade und hinterlaesst Releases in
# pending-upgrade, die den naechsten Lauf blockieren.
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

# Vorhanden heisst nicht bereit. Nach dem Klonen startet k3s alle Pods neu;
# laeuft das Deployment zu frueh los, lehnt der API-Server den ClusterIssuer ab:
#   failed calling webhook ... cert-manager-webhook ... no endpoints available
# Der Issuer wird dann nicht angelegt, und der naechste Schritt meldet NotFound.
log "Warten, bis cert-manager und ingress-nginx bereit sind"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  "$KUBECTL" -n cert-manager rollout status "deployment/${d}" --timeout=300s >/dev/null 2>&1 \
    || warn "  ${d} ist nach 5 Minuten nicht Available"
done
"$KUBECTL" -n ingress-nginx rollout status daemonset/ingress-nginx-controller --timeout=300s >/dev/null 2>&1 \
  || warn "  ingress-nginx-controller ist nach 5 Minuten nicht bereit"

# Entscheidend ist der Endpoint hinter dem Webhook-Service, nicht der Pod-Status:
# zwischen "Running" und "im Service eingetragen" liegen einige Sekunden.
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
# 3 – Release vorbereiten, pruefen und Hostnamen ableiten
# ---------------------------------------------------------------------------

log "Deployment-Verzeichnis unter ${WORK_DIR} aufbauen"
[[ -d "$CIVITAS_DIR" ]] || die "$CIVITAS_DIR fehlt - im Template wurde das Repo nicht geklont."
mkdir -p "$WORK_DIR"
rm -rf "$REPO_COPY"
cp -a "$CIVITAS_DIR" "$REPO_COPY"

# Auf einen anderen Tag oder Branch umschalten - nur in der Arbeitskopie.
if [[ -n "$CIVITAS_REF" ]]; then
  log "Auf ${CIVITAS_REF} umschalten"
  git config --global --add safe.directory "$REPO_COPY" 2>/dev/null || true

  if ! git -C "$REPO_COPY" rev-parse --verify --quiet "${CIVITAS_REF}^{commit}" >/dev/null; then
    echo "  ${CIVITAS_REF} liegt nicht lokal vor, hole vom Remote"
    git -C "$REPO_COPY" fetch --all --tags --prune --quiet \
      || die "git fetch fehlgeschlagen - ohne Netz kann ${CIVITAS_REF} nicht geholt werden."
  fi

  target="$CIVITAS_REF"
  # Branchnamen auf den Remote-Stand aufloesen, sonst landet man auf einem
  # veralteten lokalen Branch aus der Zeit des Image-Baus.
  if git -C "$REPO_COPY" rev-parse --verify --quiet "refs/remotes/origin/${CIVITAS_REF}" >/dev/null; then
    target="origin/${CIVITAS_REF}"
  fi

  git -C "$REPO_COPY" checkout --quiet --detach "$target" \
    || die "Checkout von ${CIVITAS_REF} fehlgeschlagen. Verfuegbar:
$(git -C "$REPO_COPY" tag | tail -10 | sed 's/^/  /')
$(git -C "$REPO_COPY" branch -r | sed 's/^/  /')"

  echo "  jetzt auf: $(git -C "$REPO_COPY" describe --tags --always 2>/dev/null) ($(git -C "$REPO_COPY" log -1 --format=%h\ %s))"
fi

# Wie im offiziellen justfile (Target "deploy"): defaults/deployment nach deployment/
# im Repo-Root kopieren, damit '../helmfile-root.yaml.gotmpl' aus den Helmfiles dort
# auf das tatsaechlich vorhandene helmfile-root.yaml.gotmpl im Repo-Root zeigt.
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

# Vorabpruefung: das Release muss sich mit den installierten Tools rendern
# lassen, BEVOR irgendetwas am Cluster passiert (Reset, Issuer, Namespace).
# Passen ein kuenftiges Release und die Tool-Versionen im Image nicht
# zusammen, faellt das hier auf und nicht mitten im Rollout.
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

# Alle Hostnamen aus den Ingresses des Releases. Sie landen gemeinsam in einem
# Zertifikat - fehlt einer im DNS, scheitert die Challenge fuer alle.
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
# 3b – Oeffentliche DNS-Aufloesung
# ---------------------------------------------------------------------------

# Zwei gueltige Betriebsarten:
#
#   direkt  Die Namen zeigen auf die Node-IP. Nur moeglich, wenn die VM selbst
#           aus dem Internet erreichbar ist.
#   NAT     Die Namen zeigen auf eine oeffentliche Adresse, die der Hypervisor
#           bzw. die Firewall auf die private Node-IP abbildet. Das ist der
#           Normalfall in einem Rechenzentrumsnetz - und dann ist eine
#           Abweichung von der Node-IP KEIN Fehler.
#
# Entscheidend fuer die HTTP-01-Challenge ist nur, dass alle Namen einheitlich
# auf dieselbe Adresse zeigen und dass Port 80 von aussen dort ankommt.
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
  # Der Test laeuft von der VM aus und damit ueber Hairpin-NAT, das viele
  # Firewalls nicht beherrschen. Ein Fehlschlag sagt hier also wenig - deshalb
  # nur als Hinweis, nie als Abbruchgrund.
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
apply_with_retry() {  # liest das Manifest von stdin
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
# Der Name bleibt bewusst letsencrypt-prod, weil die CIVITAS-Ingresses ihn
# referenzieren. Nur der ACME-Endpunkt wechselt.
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
# apply_with_retry gibt bei Misserfolg nicht 0 zurueck - ohne Issuer ist jedes
# weitere Ausrollen sinnlos, weil kein Zertifikat ausgestellt werden kann.
[[ $? -eq 0 ]] || die "ClusterIssuer konnte nicht angelegt werden.
Meist ist der cert-manager-Webhook nicht erreichbar:
  kubectl -n cert-manager get pods
  kubectl -n cert-manager get endpoints cert-manager-webhook"

"$KUBECTL" wait --for=condition=Ready clusterissuer/letsencrypt-prod --timeout=120s \
  || warn "ClusterIssuer noch nicht Ready - kubectl describe clusterissuer letsencrypt-prod"

# ---------------------------------------------------------------------------
# 6 – CoreDNS Split-Horizon
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

# ---------------------------------------------------------------------------
# 5b – Wechsel zwischen Staging und Produktion
#
# cert-manager erneuert ein Zertifikat NICHT, nur weil der ACME-Endpunkt sich
# geaendert hat - das vorhandene Secret ist ja formal noch gueltig. Beim
# Wechsel muessen die TLS-Secrets deshalb weg, sonst bleibt das alte
# Zertifikat liegen und NiFi scheitert weiter am Truststore.
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
# 7 – Namespace und Secrets
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
# NiFi prueft ausgehende TLS-Verbindungen gegen diesen Truststore. Enthaelt er
# die falsche Wurzel, stirbt der Pod in CrashLoopBackOff mit
#   SunCertPathBuilderException: unable to find valid certification path
# Im Staging-Modus wird nicht von ISRG signiert, sondern von der Staging-CA -
# deren Wurzel muss dann zusaetzlich hinein.
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

# Die Operatoren bringen Admission-Webhooks mit. Startet der Instanz-Teil zu
# frueh, scheitert das Release postgres-cluster reproduzierbar mit
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

# helmfile beendet sich auch dann mit 0, wenn es gar keine Releases gefunden
# hat - etwa bei abweichender Repo-Struktur oder falschem Environment.
releases=$(helm list -n "$NS" -q 2>/dev/null | wc -l)
if (( releases == 0 )); then
  warn "helmfile lief durch, aber im Namespace ${NS} existiert kein Release."
  warn "Was helmfile ueberhaupt sieht:"
  warn "  cd ${DEPLOY_DIR} && sudo helmfile -f helmfile-instance.yaml.gotmpl -e production list"
  die "Kein Rollout erfolgt - Abbruch."
fi
echo "  ${releases} Release(s) im Namespace ${NS}"

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
  warn "Keine Ingress-Hosts gefunden - es bleiben die Standardnamen."
fi

# ---------------------------------------------------------------------------
# 10 – Verifikation
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
