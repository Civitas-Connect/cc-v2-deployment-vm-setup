# CIVITAS/CORE V2 – klonbares VM-Template

Drei Skripte, zwei Phasen: einmal ein Image bauen, danach pro Instanz ein Kommando.

| Skript | Wann | Was |
|---|---|---|
| `10-build-template.sh` | einmal, auf einer leeren Ubuntu-24.04-VM | Härtung, k3s, ingress-nginx, cert-manager, Tooling, Repo, vorgezogene Images |
| `20-sysprep-template.sh` | direkt vor dem Snapshot | entfernt alles Instanzspezifische |
| `30-deploy-civitas.sh` | auf jedem Klon | ClusterIssuer, DNS, Secrets, `helmfile sync` |

## Ablauf

```bash
# --- Phase 1: Image bauen (einmalig) ---
sudo bash 10-build-template.sh
sudo kubectl get nodes -o wide && sudo kubectl get pods -A
curl -I http://127.0.0.1                 # 404 vom nginx = Ingress erreichbar

sudo bash 20-sysprep-template.sh
sudo poweroff
# -> im Hypervisor Snapshot / Template erzeugen, VM nicht mehr booten

# --- Phase 2: pro Instanz ---
# Klonen, Hostname + IP setzen, DNS-A-Records auf die neue IP zeigen lassen
sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
sudo nano /etc/civitas/deploy.env        # Domain, Slug, E-Mails, SMTP
sudo bash 30-deploy-civitas.sh
```

DNS-A-Records auf die Node-IP (Beispiel-Domain `demo.civitascore.de`):
`api`, `idm`, `portal`, `dashboard`.

## Warum der Klon hält

* **Fester Node-Name** (`civitas-node`) statt Hostname. Sonst registriert sich jeder Klon
  als neuer Node und der alte bleibt als `NotReady` liegen.
* **SQLite statt etcd** (kein `--cluster-init`). etcd würde die Node-IP festschreiben.
* **Serving-Certs regeneriert k3s selbst**, sobald sich die SANs ändern – deshalb übersteht
  der Cluster einen IP-Wechsel, anders als ein kubeadm-Cluster.
* **`machine-id`, SSH-Host-Keys, cloud-init-State** werden im Sysprep geleert und beim
  ersten Boot des Klons neu erzeugt.
* **Nichts Domain-Abhängiges im Image**: kein ClusterIssuer, kein Namespace, keine Secrets,
  kein CIVITAS-Release.

## Wartung

Das Image ist die Wartungseinheit, nicht der laufende Server. Eine Instanz driftet oder
stirbt → wegwerfen und neu klonen.

* `unattended-upgrades` mit Auto-Reboot um 03:30
* k3s-Version im Image gepinnt, nicht im Betrieb hochziehen
* Backups über Hypervisor-Snapshots, kein Velero
* Basis-Monitoring über einen externen Uptime-Check auf `https://portal.<domain>`
* Image alle 3–6 Monate neu bauen. Guter Anlass: k3s-Zertifikate laufen nach 12 Monaten ab
  (sie rotieren beim Neustart automatisch ab 90 Tagen Restlaufzeit, aber ein altes Image
  klont Klone mit knappen Certs).

## Reproduzierbarkeit

`10-build-template.sh` schreibt die tatsächlich installierten Versionen nach
`/etc/civitas/template.env`. Für den nächsten Build diese Werte oben im Skript eintragen,
dann ist das Image bit-genau wiederholbar.

## Zwei Stolpersteine, die im Skript schon abgefangen sind

* **`DEFAULT_FORWARD_POLICY="ACCEPT"` in ufw.** Bleibt es bei `DROP`, stirbt der Pod-Traffic.
  Typisches Symptom ist ein Admission-Webhook, der in `context deadline exceeded` läuft –
  genau das Bild des CNPG-Fehlers auf `itemsudpv2`.
* **CoreDNS in k3s nicht per `kubectl edit configmap coredns` anfassen.** Der Auto-Deploy-
  Controller überschreibt das beim Neustart. Der Split-Horizon läuft deshalb über die
  ConfigMap `coredns-custom`, die das Corefile per `import` einbindet.

## Varianten beim Sysprep

`sudo bash 20-sysprep-template.sh` behält den Cluster im Image – der Klon ist in ~30 Sekunden
einsatzbereit. Alle Klone teilen sich dann dieselbe Cluster-CA; bei geschlossenem Port 6443
ist das unkritisch.

`sudo bash 20-sysprep-template.sh --reset-cluster` verwirft den Cluster-State. Jeder Klon baut
beim ersten Boot einen frischen Cluster mit eigener CA auf, braucht dafür aber zusätzlich
`sudo bash 10-build-template.sh --addons-only`.
