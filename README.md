# CIVITAS/CORE V2 – clonable VM template

Scripts to build a **golden Ubuntu VM image** with a ready-to-use single-node Kubernetes
(k3s) and to spin up any number of **[CIVITAS/CORE V2](https://gitlab.com/civitas-connect/civitas-core/civitas-core-v2/civitas-core-deployment)
demo instances** from it – one clone per instance, each with its own domain and Let's Encrypt
certificates.

The image is built once. Every clone then needs only two commands: one to personalize the
node (hostname, IP) and one to deploy CIVITAS/CORE. Container images are pre-pulled
in the image, so a deployment takes minutes instead of hours.

## How it works

```
 Ubuntu 24.04 VM ──10-build──▶ golden image ──20-sysprep──▶ snapshot
                                                               │ clone
                                                               ▼
                                   new VM ──25-postclone──▶ node ──30-deploy──▶ CIVITAS/CORE instance
```

| Script | Runs on | What it does |
|---|---|---|
| `10-build-template.sh` | master, once | Hardening (SSH, ufw, fail2ban, auto-updates), k3s, ingress-nginx, cert-manager, helm/helmfile, CIVITAS repo + image pre-pull, first-boot automation |
| `20-sysprep-template.sh` | master, before every snapshot | Seals the image: stops k3s, removes credentials and logs, sets the first-boot marker |
| `25-postclone-setup.sh` | each clone | Sets hostname and static IP, moves k3s to the new IP |
| `30-deploy-civitas.sh` | each clone | ClusterIssuer, CoreDNS split horizon, secrets, `helmfile` rollout |

On the first boot of a clone, `civitas-firstboot.service` automatically generates a new
`machine-id` and new SSH host keys, then reboots once. Nothing domain- or IP-specific is
baked into the image.

**Requirements:** Ubuntu 24.04 VM, ≥ 16 GB RAM, ≥ 40 GB disk, a sudo user with an SSH key,
ports 80/443 reachable from the internet, and a DNS record per instance.

Always run the scripts with `bash`, not `sh`.

---

## 1. Build the image (master)

```bash
sudo git clone https://github.com/BronxHD/civitas-core-demo_clone_setup-.git /opt/civitas/scripts-src
sudo install -d -m 0755 /opt/civitas/scripts
sudo install -m 0755 /opt/civitas/scripts-src/*.sh /opt/civitas/scripts/
sudo install -m 0644 /opt/civitas/scripts-src/deploy.env.example /opt/civitas/scripts/

tmux new -s build
sudo bash /opt/civitas/scripts/10-build-template.sh
```

To rebuild with the same versions instead of `latest`, pass the values from
`/etc/civitas/template.env`, e.g. `sudo K3S_VERSION=... CERT_MANAGER_VERSION=... CIVITAS_TAG=v2.0.0 bash ...`.

Then seal it and take the snapshot in the hypervisor (the VM may keep running):

```bash
sudo bash /opt/civitas/scripts/20-sysprep-template.sh
```

Do **not** reboot the master before the snapshot is taken. Afterwards `sudo reboot` it
and personalize it like a clone (step 2).

## 2. Personalize a clone

Boot the clone. It reboots once by itself. Then, **on a single line**:

```bash
sudo bash /opt/civitas/scripts/25-postclone-setup.sh --hostname civitas-demo1 --ip 10.0.0.11/24 --gateway 10.0.0.1 --dns 1.1.1.1
```

Without DHCP the clone has no address after boot. The exact command is shown above the
console login prompt. Use `--check` to compare the identity with other clones. Log in
again afterwards to use `kubectl` without `sudo`.

## 3. Deploy CIVITAS/CORE

1. **DNS:** create a wildcard record `*.<domain>` pointing to the instance's public (NAT)
   address. Port 80 must be reachable from outside for the Let's Encrypt HTTP-01 challenge.
2. **Configure:**
   ```bash
   sudo cp /etc/civitas/deploy.env.example /etc/civitas/deploy.env
   sudo nano /etc/civitas/deploy.env
   sudo chmod 600 /etc/civitas/deploy.env
   ```
   Required: `DOMAIN`, `INSTANCE_SLUG`, `INITIAL_USER_EMAIL`, `LETSENCRYPT_EMAIL`.
   Optional: SMTP settings (for Keycloak mails), `PUBLIC_IP`, `CIVITAS_REF`.
   Keep `LETSENCRYPT_STAGING=true` for the first run on a new domain.
3. **Deploy** (takes several minutes):
   ```bash
   tmux new -s deploy
   sudo bash /opt/civitas/scripts/30-deploy-civitas.sh
   ```
   The script renders and validates the release before touching the cluster and checks
   all DNS names up front. At the end it prints the URLs and the Keycloak admin password.
4. **Switch to production certificates** once everything works on staging: set
   `LETSENCRYPT_STAGING=false` and run the script again. Old staging certificates are
   replaced automatically.

Other options: `--diff` (preview only), `--reset` (wipe and rebuild the instance),
`--prepare` (only issuer/DNS/secrets), `--no-update` (skip the script self-update).

---

## Updates

- **New CIVITAS version:** no new image needed. Set `CIVITAS_REF=<tag>` in
  `/etc/civitas/deploy.env` and run `30-deploy-civitas.sh` (optionally with `--diff` first).
- **Script updates:** with `SCRIPTS_REF` set in `deploy.env`, `30-deploy-civitas.sh` pulls the
  scripts from this repo before every run. They run as root, so use a tag rather
  than a branch if you want to control exactly what runs.
- **New image:** rebuild every 3–6 months. The k3s certificates in the template expire after
  12 months. Run `20-sysprep-template.sh` again before **every** snapshot.

The image is the unit of maintenance: if an instance drifts or breaks, throw it away and clone
a new one.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `[[: not found` | Run with `bash`, not `sh` |
| `Unbekannte Option: --ip` | Line break/backslash when pasting – enter the command on one line |
| `certificate is not yet valid` | Clock was wrong at boot – `25-postclone-setup.sh` rotates the k3s certificates; check NTP |
| `permission denied` with kubectl | Log in again (group `civitas`) |
| `no endpoints available for service cert-manager-webhook` | cert-manager was not ready yet – just run the script again |
| Helm release stuck in `pending-upgrade` | SSH dropped mid-run – `helm rollback <release> -n <ns>`, then always use tmux |
| Let's Encrypt challenge times out | Port 80 not reachable from outside, or DNS points elsewhere |
