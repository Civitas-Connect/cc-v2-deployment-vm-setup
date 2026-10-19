# CIVITAS/CORE V2 – klonbares VM-Template

Ein Image bauen, dann pro Demo-Instanz klonen und zwei Skripte laufen lassen.

| Skript | Wo | Was |
|---|---|---|
| `10-build-template.sh` | Master, einmalig | k3s, ingress-nginx, cert-manager, Tooling, Repo, Klon-Automatik |
| `20-sysprep-template.sh` | Master, vor dem Snapshot | versiegelt das Image |
| `25-postclone-setup.sh` | jeder Klon, nach dem Erstboot | Hostname, feste IP, k3s auf die neue IP |
| `30-deploy-civitas.sh` | jeder Klon, danach | ClusterIssuer, DNS, Secrets, Rollout |

Alle Skripte liegen im Image unter `/opt/civitas/scripts/` und werden **mit `bash`**
aufgerufen, nie mit `sh` — `sh` ist dash und kennt `[[ ]]` nicht.

---

## A – Golden Image erzeugen (Master)

Leere Ubuntu-24.04-VM mit sudo-Benutzer und hinterlegtem SSH-Key. Skripte holen:

```bash
sudo git clone https://github.com/BronxHD/civitas-core-demo_clone_setup-.git /opt/civitas/scripts-src
sudo install -d -m 0755 /opt/civitas/scripts
sudo install -m 0755 /opt/civitas/scripts-src/*.sh /opt/civitas/scripts/
sudo install -m 0644 /opt/civitas/scripts-src/deploy.env.example /opt/civitas/scripts/
```

Image bauen:

```bash
tmux new -s build
sudo bash /opt/civitas/scripts/10-build-template.sh
```

Beim Nachbauen eines bestehenden Images die Versionen mitgeben, sonst zieht der Lauf
alles auf latest hoch:

```bash
cat /etc/civitas/template.env
sudo K3S_VERSION="v1.36.3+k3s1" CERT_MANAGER_VERSION="v1.21.1" \
     HELMFILE_VERSION="1.7.2" CIVITAS_TAG="v2.0.0" PREPULL_IMAGES=false \
     bash /opt/civitas/scripts/10-build-template.sh
```

Prüfen:

```bash
systemctl is-enabled civitas-firstboot.service            # enabled
stat -c '%a %G' /etc/rancher/k3s/k3s.yaml                 # 640 civitas
timedatectl | grep synchronized                           # yes
kubectl get pods -A                                       # alles Running
curl -I http://127.0.0.1                                  # 404 vom nginx
sudo openssl x509 -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt \
     -noout -dates                                        # notBefore in der Vergangenheit
```

Versiegeln:

```bash
sudo bash /opt/civitas/scripts/20-sysprep-template.sh
ls -l /etc/civitas/sealed        # muss existieren
systemctl is-active k3s          # inactive
```

Sally erzeugt jetzt den Snapshot — laufend oder heruntergefahren, beides geht. **Den
Master bis dahin nicht neu starten**, jeder Boot verbraucht die Markierung.

Danach den Master zurückholen: `sudo reboot` (er startet zweimal), dann Abschnitt B mit
seinen eigenen Werten.

---

## B – Klon personalisieren

Sally klont und startet die VM. Mehr muss sie nicht tun.

Der Klon startet zweimal: `civitas-firstboot` erzeugt eine neue `machine-id`, neue
SSH-Host-Keys und verwirft die Netzkonfiguration des Masters. Ohne DHCP im Segment hängt
er danach ohne Adresse da — der nötige Befehl steht über dem Login-Prompt der Konsole.
**Alles in einer Zeile**, ohne Backslash:

```bash
sudo bash /opt/civitas/scripts/25-postclone-setup.sh --hostname civitas-demo2 --ip 192.168.210.102/24 --gateway 192.168.210.1 --dns 8.8.8.8
```

Das Skript wartet auf die NTP-Synchronisation, rotiert bei Bedarf die k3s-Zertifikate,
stellt die Node-IP um und nimmt dich in die Gruppe `civitas` auf. Für `kubectl` ohne
`sudo` einmal neu anmelden.

Gegenprobe zum Master:

```bash
sudo bash /opt/civitas/scripts/25-postclone-setup.sh --check
```

Unterscheiden müssen sich: Hostname, `machine-id`, SSH-Host-Key, IP, k3s-Node-IP.
Gleich sein dürfen: Node-Name `civitas-node`, Cluster-CA, Pod-CIDR, Image-Store.

---

## C – CIVITAS/CORE deployen

**1. DNS.** Pro Instanz ein Wildcard-A-Record auf die *öffentliche* NAT-Adresse:

```
*.demo2.ghost-website.de   A   93.88.227.78   (TTL 300)
```

Ohne Wildcard braucht jeder Hostname des Releases einen eigenen Record (v2.0.0: api, idm,
portal, dashboard, management). Das Deploy-Skript liest die Liste aus dem gerenderten
Release, gibt sie aus und prüft jeden Namen, bevor es etwas am Cluster ändert.

**2. Erreichbarkeit von außen prüfen** — vom Handy-Hotspot, nicht aus dem Firmennetz:

```bash
curl -I --max-time 10 http://93.88.227.78/.well-known/acme-challenge/test
```

Ein `404` vom nginx ist die gute Antwort. Ein Timeout heißt: Let's Encrypt kann nicht
validieren, dann muss Port 80 freigegeben werden.

**3. Konfigurieren.**

```bash
sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
sudo nano /etc/civitas/deploy.env
sudo chmod 600 /etc/civitas/deploy.env
```

Pflichtfelder: `DOMAIN`, `INSTANCE_SLUG`, `INITIAL_USER_EMAIL`, `LETSENCRYPT_EMAIL`.
Steht die Instanz hinter NAT, kann `PUBLIC_IP` gesetzt werden — nötig ist es nicht, das
Skript erkennt die NAT-Situation auch selbst.
Dazu SMTP, falls Keycloak Mails verschicken soll. Bei einer neuen Domain
`LETSENCRYPT_STAGING=true` lassen — die Produktions-CA sperrt nach fünf fehlgeschlagenen
Validierungen pro Stunde.

Optional `CIVITAS_REF`, um von einem anderen Tag oder Branch zu deployen. Leer heißt:
der Stand aus dem Image.

`SCRIPTS_REF=main` (Standard in der Vorlage) holt vor jedem Lauf die aktuellen Skripte aus
GitHub. Leer schaltet das ab, `--no-update` überspringt es einmalig.

**4. Ausrollen.** In tmux, der Lauf dauert etliche Minuten ohne viel Ausgabe:

```bash
tmux new -s deploy
sudo bash /opt/civitas/scripts/30-deploy-civitas.sh
```

Das Skript aktualisiert sich zuerst selbst (`SCRIPTS_REF`) und rendert dann das Release
als Vorabprüfung. Scheitert das, bricht es ab, bevor am Cluster etwas passiert. Danach
legt es ClusterIssuer, CoreDNS-Split-Horizon, Namespace und Secrets an und rollt in zwei
Schritten aus: erst `helmfile-operators.yaml`, nach dem Bereitwerden der Webhooks
`helmfile-instance.yaml.gotmpl`.

**5. Prüfen.**

```bash
kubectl -n demo2 get pods
kubectl -n demo2 get certificate                 # READY=True
echo | openssl s_client -connect 127.0.0.1:443 -servername portal.demo2.ghost-website.de \
  2>/dev/null | openssl x509 -noout -issuer -dates
```

**6. Auf Produktion umstellen**, wenn mit Staging alles läuft:

```bash
sudo sed -i 's/^LETSENCRYPT_STAGING=.*/LETSENCRYPT_STAGING=false/' /etc/civitas/deploy.env
sudo bash /opt/civitas/scripts/30-deploy-civitas.sh
```

Das Skript erkennt am Aussteller, dass die vorhandenen Zertifikate nicht mehr zum Modus
passen, verwirft sie und lässt neu ausstellen. Im `issuer` darf danach kein `(STAGING)`
mehr stehen.

Weitere Optionen: `--diff` zeigt nur die Vorschau, `--reset` wirft die Instanz weg und
baut sie neu auf.

---

## Neue CIVITAS-Version

Kein neues Image nötig. Auf dem Klon in `/etc/civitas/deploy.env` setzen:

```bash
CIVITAS_REF=v2.1.0
```

und `30-deploy-civitas.sh` laufen lassen (vorher gern mit `--diff`). Mussten die Skripte
für das Release angepasst werden, reicht ein Push nach GitHub: jeder Klon holt sie über
`SCRIPTS_REF` beim nächsten Lauf. Ein neues Image lohnt sich nur, damit die Images der neuen
Version schon vorgeladen sind, oder weil k3s-Zertifikate bzw. OS-Updates es ohnehin fällig
machen.

## Skripte auf einer laufenden VM aktualisieren

Mit `SCRIPTS_REF` in der `deploy.env` passiert das automatisch. Für ältere Klone ohne diese
Variable einmalig von Hand:

```bash
sudo chmod 0755 /opt/civitas/scripts/*.sh
sudo chmod 0644 /opt/civitas/scripts/deploy.env.example
sudo cp /opt/civitas/scripts/deploy.env.example /etc/civitas/

# welche Fassung liegt hier?
grep -c "helmfile-operators" /opt/civitas/scripts/30-deploy-civitas.sh   # > 0
grep -c "civitas-firstboot"  /opt/civitas/scripts/10-build-template.sh   # > 0
grep -n 'DEPLOY_DIR="'       /opt/civitas/scripts/30-deploy-civitas.sh   # ${REPO_COPY}/deployment
```

Neue Skripte allein ändern nichts am System — Gruppe `civitas`, firstboot-Dienst und
DHCP-Fallback entstehen erst beim Lauf von `10-build-template.sh`.

---

## Wenn etwas klemmt

| Symptom | Ursache |
|---|---|
| `[[: not found` | mit `sh` statt `bash` aufgerufen |
| `Unbekannte Option:  --ip` | Backslash beim Einfügen in die Konsole, alles in eine Zeile tippen |
| `Missing privilege separation directory` | `sudo install -d -m 0755 /run/sshd` |
| `certificate is not yet valid` | Uhr ging beim Boot falsch → `k3s certificate rotate` bei gestopptem Dienst |
| `permission denied` bei kubectl | nach dem Build einmal neu anmelden (Gruppe `civitas`) |
| `no matches for path: ../helmfile-root…` | veraltete Skriptfassung, `DEPLOY_DIR` muss `${REPO_COPY}/deployment` sein |
| Pods in `CreateContainerError`, `name ... is reserved for` | Container-Namen aus dem Snapshot → `kubectl -n <ns> delete pod --all`; `civitas-clusterfix` macht das beim ersten Boot automatisch |
| DNS-Warnung „erwartet 192.168.x.y" bei NAT | behoben — bei einheitlicher öffentlicher Adresse ist das kein Fehler mehr; optional `PUBLIC_IP` setzen |
| `no endpoints available for service cert-manager-webhook` | zu früh gestartet, cert-manager war noch nicht bereit → einfach erneut laufen lassen |
| CoreDNS in CrashLoopBackOff | Schlüssel in `coredns-custom` muss `.server` heißen, nicht `.override` |
| NiFi `SunCertPathBuilderException` | Truststore passt nicht zur ACME-Umgebung |
| Helm hängt in `pending-upgrade` | SSH-Abriss mittendrin → `helm rollback <release> -n <ns>` |
| `apt` kriecht bei ~50 kB/s | toter Mirror → auf `de.archive.ubuntu.com` wechseln |

Ausführliche Erklärungen dazu stehen in `REFERENCE.md`.

---

## Wartung

Das Image ist die Wartungseinheit, nicht der laufende Server. Eine Instanz driftet oder
stirbt → wegwerfen und neu klonen.

Vor **jedem** neuen Snapshot muss `20-sysprep-template.sh` erneut laufen; die Markierung
wird beim Erstboot verbraucht. Image alle 3–6 Monate neu bauen — die k3s-Zertifikate im
Template laufen nach 12 Monaten ab.
