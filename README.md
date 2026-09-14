# CIVITAS/CORE V2 – klonbares VM-Template

Vier Skripte, zwei Phasen: einmal ein Image bauen, danach pro Instanz zwei Kommandos.

| Skript | Wann | Was |
|---|---|---|
| `10-build-template.sh` | einmal, auf einer leeren Ubuntu-24.04-VM | Härtung, k3s, ingress-nginx, cert-manager, Tooling, Repo, vorgezogene Images, Klon-Automatik |
| `20-sysprep-template.sh` | direkt vor dem Snapshot | versiegelt das Image, VM läuft weiter |
| `25-postclone-setup.sh` | auf jedem Klon nach dem Erstboot | Hostname, feste IP, k3s auf die neue IP umstellen |
| `30-deploy-civitas.sh` | danach, pro Instanz | ClusterIssuer, DNS, Secrets, `helmfile sync` |

## Warum der Master nicht heruntergefahren wird

Nutanix AHV und die meisten anderen Hypervisoren snapshotten laufende VMs. Der
klassische Sysprep-Ansatz – Identität löschen, `poweroff`, Snapshot, nie wieder
booten – funktioniert dort nicht: sobald man den Master wieder startet, erzeugt
er sich eine neue `machine-id` und neue SSH-Host-Keys, und die gelöschte
Netzwerkkonfiguration kommt ohne cloud-init-Datasource nicht zurück. Genau
dieser Fehler hat die erste Runde gekostet.

Deshalb löscht `20-sysprep-template.sh` nichts Identitätsstiftendes mehr. Es setzt
nur eine Markierung `/etc/civitas/sealed`. Ausgewertet wird sie von
`civitas-firstboot.service`, der in jedem Klon **vor** sshd und k3s läuft, dort
`machine-id`, SSH-Host-Keys, Hostname, Instanz-Netzwerk und das dynamische
k3s-Zertifikat verwirft und anschließend einmal neu startet. Der Master darf
währenddessen laufen – und ist, nach seinem nächsten eigenen Reboot, effektiv
selbst ein Klon.

## Ablauf

```bash
# --- Phase 1: Image bauen (einmalig) ---
sudo bash 10-build-template.sh
sudo kubectl get nodes -o wide && sudo kubectl get pods -A
curl -I http://127.0.0.1                 # 404 vom nginx = Ingress erreichbar

sudo bash 20-sysprep-template.sh
# -> jetzt im Hypervisor Snapshot / Template der LAUFENDEN VM erzeugen

# --- Master wieder in Betrieb nehmen ---
sudo reboot                              # firstboot läuft, VM startet zweimal
sudo bash 25-postclone-setup.sh --hostname civitas-master \
     --ip 192.168.210.100/24 --gateway 192.168.210.1 --dns 192.168.210.10

# --- Phase 2: pro Klon ---
# Klonen und starten. Der Klon bootet zweimal und hängt danach per DHCP im Netz.
sudo bash 25-postclone-setup.sh --hostname civitas-demo1 \
     --ip 192.168.210.101/24 --gateway 192.168.210.1 --dns 192.168.210.10

sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
sudo nano /etc/civitas/deploy.env        # Domain, Slug, E-Mails, SMTP
sudo bash 30-deploy-civitas.sh
```

Die Skripte immer mit `bash` aufrufen, nie mit `sh`. `sh` ist auf Ubuntu dash und
kennt `[[ ]]` nicht – das Ergebnis ist ein irreführendes „Bitte mit sudo ausführen".

DNS-A-Records auf die Node-IP (Beispiel-Domain `demo.civitascore.de`):
`api`, `idm`, `portal`, `dashboard`.

## Netzwerk

Das Image trägt einen DHCP-Fallback (`/etc/netplan/01-civitas-dhcp.yaml`) mit
Interface-Glob `e*`, damit ein Klon ohne Konsolenzugriff online kommt.
`25-postclone-setup.sh` schreibt die feste Adresse nach
`/etc/netplan/10-civitas-instance.yaml` und entfernt den Fallback.
`civitas-firstboot` löscht beim Klonen nur die Instanzdatei – der Fallback bleibt.

cloud-init schreibt keine Netzwerkkonfiguration mehr
(`/etc/cloud/cloud.cfg.d/99-civitas-disable-network.cfg`). Ohne das würde die
AHV-Datasource eine `50-cloud-init.yaml` anlegen, die gegen `10-` gewinnt.

Gibt es im Zielsegment kein DHCP, hängt der Klon nach dem Erstboot ohne Adresse
da und braucht einmalig die Hypervisor-Konsole. Damit dort niemand suchen muss,
schreibt `civitas-firstboot` den nötigen Aufruf nach `/etc/issue` — er steht dann
direkt über dem Login-Prompt. Wichtig für den, der ihn abtippt: **alles in einer
Zeile**, ohne Backslash. Über eine Hypervisor-Konsole überleben mehrzeilige
Befehle das Einfügen fast nie, und ein escaptes Leerzeichen führt zu der
irreführenden Meldung `Unbekannte Option:  --ip`.

## Warum der Klon hält

* **Fester Node-Name** (`civitas-node`) statt Hostname. Sonst registriert sich jeder
  Klon als neuer Node und der alte bleibt als `NotReady` liegen.
* **SQLite statt etcd** (kein `--cluster-init`). etcd würde die Node-IP festschreiben.
* **Serving-Certs**: `25-postclone-setup.sh` verwirft `k3s-serving` und
  `dynamic-cert.json`, damit die SANs nicht die alte IP behalten. Ohne das bleibt
  die Node-`InternalIP` auf dem Wert des Masters stehen und der CoreDNS-Split-Horizon
  zeigt ins Leere.
* **`machine-id`, SSH-Host-Keys, cloud-init-State** erzeugt `civitas-firstboot` neu.
* **Nichts Domain-Abhängiges im Image**: kein ClusterIssuer, kein Namespace, keine
  Secrets, kein CIVITAS-Release.

## Prüfen, ob das Klonen geklappt hat

```bash
sudo bash 25-postclone-setup.sh --check
```

**Muss sich zwischen Instanzen unterscheiden:** Hostname, `machine-id`,
SSH-Host-Key-Fingerprint, IP, `INTERNAL-IP` in `kubectl get node -o wide`.

**Darf und soll identisch sein:** Node-Name `civitas-node`, Cluster-CA und
Node-Token (bei Sysprep ohne `--reset-cluster`), Pod-/Service-CIDR, Image-Store,
`authorized_keys`.

Das Serverzertifikat kann nach einem IP-Wechsel beide Adressen in den SANs
führen. k3s ergänzt SANs, statt sie zu ersetzen – entscheidend ist, dass die
aktuelle IP enthalten ist.

## Wartung

Das Image ist die Wartungseinheit, nicht der laufende Server. Eine Instanz driftet
oder stirbt → wegwerfen und neu klonen.

* `unattended-upgrades` mit Auto-Reboot um 03:30
* k3s-Version im Image gepinnt, nicht im Betrieb hochziehen
* Backups über Hypervisor-Snapshots, kein Velero
* Basis-Monitoring über einen externen Uptime-Check auf `https://portal.<domain>`
* Image alle 3–6 Monate neu bauen. Guter Anlass: k3s-Zertifikate laufen nach 12
  Monaten ab (sie rotieren beim Neustart ab 90 Tagen Restlaufzeit automatisch,
  aber ein altes Image klont Klone mit knappen Certs).

Vor jedem neuen Snapshot muss `20-sysprep-template.sh` erneut laufen – die
Markierung wird beim Erstboot verbraucht.

## Reproduzierbarkeit

`10-build-template.sh` schreibt die tatsächlich installierten Versionen nach
`/etc/civitas/template.env`. Für den nächsten Build diese Werte oben im Skript
eintragen, dann ist das Image bit-genau wiederholbar.

## Stolpersteine, die im Skript schon abgefangen sind

* **`DEFAULT_FORWARD_POLICY="ACCEPT"` in ufw.** Bleibt es bei `DROP`, stirbt der
  Pod-Traffic. Typisches Symptom ist ein Admission-Webhook in
  `context deadline exceeded`.
* **CoreDNS in k3s nicht per `kubectl edit configmap coredns` anfassen.** Der
  Auto-Deploy-Controller überschreibt das beim Neustart. Der Split-Horizon läuft
  über die ConfigMap `coredns-custom` — und dort mit dem Schlüssel `civitas.server`,
  nicht `civitas.override`. Ein `.override` wird in den bestehenden `.:53`-Block
  importiert, in dem k3s bereits `hosts /etc/coredns/NodeHosts` stehen hat; CoreDNS
  bricht dann mit `plugin/hosts: this plugin can only be used once per Server Block`
  ab und geht in CrashLoopBackOff. Notbremse, falls das passiert:
  `kubectl -n kube-system delete cm coredns-custom && kubectl -n kube-system rollout restart deployment coredns`.
* **`kubectl` ohne `sudo`** läuft über die Gruppe `civitas`: k3s schreibt die
  kubeconfig mit `write-kubeconfig-mode: "0640"` und `write-kubeconfig-group: "civitas"`,
  der Admin-Benutzer ist Mitglied. Das überlebt auch eine Zertifikatsrotation — eine
  Kopie unter `~/.kube/config` nicht, deren CA passt danach nicht mehr. Die
  Gruppenmitgliedschaft greift erst nach einer **neuen Anmeldung**. Prüfen mit
  `stat -c '%a %G' /etc/rancher/k3s/k3s.yaml` — erwartet ist `640 civitas`.
* **IP-Konflikt beim Klonen.** `25-postclone-setup.sh` pingt die Zieladresse vorab
  und bricht ab, wenn sie schon jemandem gehört.
* **Kaputtes Netplan-YAML.** Vor `netplan apply` läuft `netplan generate`; schlägt
  es fehl, wird die Datei zurückgenommen, statt die VM offline zu nehmen.
* **`/run/sshd` fehlt nach dem Klonen.** `/run` liegt auf tmpfs, und sshd legt das
  Verzeichnis erst beim Start an. Da `civitas-firstboot` die Host-Keys entfernt,
  startet der Dienst vorher nie — `sshd -t` scheitert dann mit
  `Missing privilege separation directory`. `25-postclone-setup.sh` legt es an.
* **Teilfehler brechen nicht mehr alles ab.** Scheitert der SSH- oder k3s-Schritt,
  bleiben Netzwerk und Hostname trotzdem gesetzt; das Skript meldet, was offen ist,
  und kann nach der Behebung einfach erneut laufen.
* **Systemzeit — der häufigste Killer beim Klonen.** Startet ein Klon mit falsch
  gehender Uhr und erzeugt k3s in diesem Zustand Zertifikate, tragen sie ein
  `NotBefore` in der Zukunft. Sobald NTP die Uhr zurückzieht, ist der Cluster tot mit
  `certificate has expired or is not yet valid`, und ein Neustart hilft nicht.
  `25-postclone-setup.sh` wartet deshalb auf die NTP-Synchronisation, bevor es k3s
  anfasst, erkennt Zertifikate mit Zukunftsdatum und rotiert sie automatisch.
  Von Hand: `sudo k3s certificate rotate` nach `timedatectl set-ntp true`.
* **`10-build-template.sh` und `30-deploy-civitas.sh` nicht über eine nackte
  SSH-Sitzung laufen lassen.** Beide arbeiten minutenlang ohne Ausgabe; reißt die
  Verbindung ab, bleibt dpkg auf halbem Weg stehen bzw. Helm-Releases hängen in
  `pending-upgrade`. Beide Skripte warnen und empfehlen `tmux`; das Deployment
  bricht zusätzlich ab, wenn es hängende Releases vorfindet, und nennt den
  `helm rollback`-Befehl dazu.
* **Paketspiegel.** `archive.ubuntu.com` war in dieser Umgebung nicht erreichbar,
  während `de.archive.ubuntu.com` 79 MB/s lieferte. Wirkt wie ein Hänger im Build,
  ist aber ein toter Mirror — prüfen mit
  `curl -o /dev/null -w '%{speed_download}\n' --max-time 30 http://archive.ubuntu.com/ubuntu/ls-lR.gz`.
* **Repo-Layout.** `defaults/deployment` ist eine Vorlage; ihre Helmfiles laden
  `../helmfile-root.yaml.gotmpl` aus dem Repo-Root. Das Verzeichnis muss deshalb als
  `deployment/` direkt unter dem Repo-Root liegen — genau das macht auch das offizielle
  `justfile`. Einstiegspunkte sind `helmfile-operators.yaml` und
  `helmfile-instance.yaml.gotmpl`, nicht `helmfile.yaml`.

## Von einem anderen Tag oder Branch deployen

`CIVITAS_REF` in der `deploy.env` schaltet die Arbeitskopie unter
`/opt/civitas/rendered/repo` auf einen anderen Stand um; das Repo unter
`/opt/civitas/civitas-core-deployment` bleibt unberührt. Leer lassen heißt: der Stand
aus dem Image, bei diesem Template `v2.0-rc2`.

```bash
CIVITAS_REF=v2.0-rc3     # anderer Tag
CIVITAS_REF=main         # Branch, wird auf origin/main aufgelöst
```

Branchnamen werden bewusst gegen `origin/` aufgelöst — ein lokaler Branch stammt sonst
noch aus der Zeit des Image-Baus. Liegt die Referenz nicht lokal vor, wird gefetcht;
dafür braucht die VM Zugang zum GitLab.

Zwei Dinge dabei beachten: Die Container-Images im Node passen zum Stand aus dem Image,
ein anderer Tag lädt also nach. Und die Repo-Struktur kann sich zwischen Versionen
ändern — erst mit `LETSENCRYPT_STAGING=true` testen.

Soll ein anderer Stand dauerhaft gelten, gehört er ins Image: `CIVITAS_TAG` beim Aufruf
von `10-build-template.sh` setzen und neu bauen.

## Let's Encrypt: Staging und Produktion

`30-deploy-civitas.sh` erkennt am Aussteller der vorhandenen TLS-Secrets, ob sie zum
konfigurierten `LETSENCRYPT_STAGING` passen, und verwirft sie beim Wechsel — cert-manager
erneuert sonst nicht, weil das alte Zertifikat formal noch gültig ist.

Im Staging-Modus landet zusätzlich die Staging-Wurzel im Secret `custom-ca-cert`. Ohne
das stirbt NiFi in CrashLoopBackOff mit `SunCertPathBuilderException: unable to find
valid certification path` — der Truststore enthält dann nur das ISRG-Root, das zur
Staging-Kette nicht passt.

Prüfen, was tatsächlich ausgeliefert wird:

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername idm.<domain> 2>/dev/null \
  | openssl x509 -noout -issuer -dates
```

Rate Limits der Produktions-CA: fünf fehlgeschlagene Validierungen pro Konto und Stunde,
50 Zertifikate pro registrierter Domain und Woche. Bei einer neuen Domain oder einer neuen
NAT-Adresse lohnt ein Vorabtest von außerhalb des Netzes, bevor man auf Produktion geht:

```bash
curl -I --max-time 10 http://<öffentliche-ip>/.well-known/acme-challenge/test   # 404 = gut
```

## Varianten beim Sysprep

`sudo bash 20-sysprep-template.sh` behält den Cluster im Image – der Klon ist nach
dem zweiten Boot in etwa einer Minute einsatzbereit. Alle Klone teilen sich dann
dieselbe Cluster-CA; bei geschlossenem Port 6443 ist das unkritisch.

`sudo bash 20-sysprep-template.sh --reset-cluster` verwirft den Cluster-State. Jeder
Klon baut beim ersten Boot einen frischen Cluster mit eigener CA auf, braucht dafür
aber zusätzlich `sudo bash 10-build-template.sh --addons-only`.
