# Ubuntu release upgrades

Procedure for moving the k3s host `k1` to a newer Ubuntu LTS release.

## Upgrade path

Ubuntu upgrades LTS to LTS only, one release at a time: 22.04 to 24.04 to 26.04. Each hop runs `do-release-upgrade` and reboots the host. Run one hop per session and verify the cluster before the next.

`k1` is an Oracle Cloud ARM64 (`ubuntu-ports`) KVM guest. k3s stores cluster state in SQLite through kine (`/var/lib/rancher/k3s/server/db/state.db`); `k3s etcd-snapshot` does not apply, and `server/db/etcd` is a leftover from an older install. Pod data lives on the boot volume, which makes the OCI boot volume backup the only full recovery point. Create one in the OCI console before the first hop.

## Before a hop

1. Confirm the next release is offered: `sudo do-release-upgrade -c`.
2. Free space on `/`. `/var/lib/rancher` holds tens of GB of container images; `apt autoremove --purge`, `apt clean`, and `journalctl --vacuum-size=200M` reclaim the easy parts. Leave at least a few GB.
3. Update the current release fully: `sudo apt update && sudo apt full-upgrade -y`.
4. Reboot if `/var/run/reboot-required` exists. The upgrader refuses to start while a reboot is pending.

## Running a hop

sshd restarts during the install phase, so the upgrade runs detached in tmux. A dropped SSH session then detaches only the monitor, not the upgrade.

```bash
printf '#!/bin/bash\nexec do-release-upgrade -f DistUpgradeViewNonInteractive\n' | sudo tee /var/tmp/upgrade-hop.sh >/dev/null
sudo chmod +x /var/tmp/upgrade-hop.sh
sudo tmux new-session -d -s upgrade "/var/tmp/upgrade-hop.sh > /var/log/dist-upgrade-hop.log 2>&1"
```

`/var/log/dist-upgrade/main.log` is the live log. The redirected stdout is block-buffered and stays empty for long stretches. Connection refused during the install phase means sshd is being replaced, not that the host went down.

Noninteractive mode answers every prompt with its default, keeps the current file on conffile conflicts, and does not reboot. The run ends at `confirmRestart() called` and the process exits. Reboot manually:

```bash
sudo systemctl reboot
```

The host returns in about two minutes. The tmux session and `/var/tmp/upgrade-hop.sh` do not survive the reboot; both are recreated per hop.

## After the reboot

```bash
lsb_release -ds && uname -r
systemctl --failed
systemctl is-active k3s tailscaled
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -v -E 'Running|Completed'
sudo k3s kubectl get clusters.postgresql.cnpg.io -A
sudo apt update && sudo apt full-upgrade -y
```

Pods read `Unknown` for a minute or two while kubelet re-registers, and stale objects clear on their own. Then confirm the next hop is offered with `sudo do-release-upgrade -c`.

## Repairs the 26.04 path needed

Expect this class of breakage on later hops.

- Third-party sources are disabled, and the upgrader cannot convert a one-line `.list` to deb822. Recreate the Tailscale source as `/etc/apt/sources.list.d/tailscale.sources`:

  ```
  Types: deb
  URIs: https://pkgs.tailscale.com/stable/ubuntu
  Suites: resolute
  Components: main
  Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg
  ```

  Set `Suites` to the new codename on later hops. Tailscale publishes per release; check `https://pkgs.tailscale.com/stable/ubuntu/dists/<codename>/Release` before choosing.

- `/etc/sysctl.conf` is removed. Node tuning moves to `/etc/sysctl.d/` (see [Node limits](#node-limits)).
- `netfilter-persistent` fails on the first boot. The shutdown before the upgrade autosaves the live k3s and Tailscale chains into `/etc/iptables/rules.v4`, and the restore races the services that create those chains. Disable it; k3s and tailscaled install their own rules:

  ```bash
  sudo systemctl disable --now netfilter-persistent
  ```

- The OCI agent sudoers file (`/etc/sudoers.d/100-oracle-cloud-agent-users`) uses `systemctl * <unit>` wildcards and `requiretty`, both invalid in the sudo shipped since 24.04. sudo works but prints warnings on every invocation, and the affected aliases are rejected. Replace each `/bin/systemctl * <unit>` argument with a bare `/bin/systemctl`, delete the `requiretty` line, and validate with `sudo visudo -c`. The agent refresh to 1.63 does not fix the file. Keep a backup of the original.
- Kernel packages from the old release stay in `rc` state. Purge them:

  ```bash
  dpkg -l | awk '$1=="rc" && $2 ~ /^linux-/ {print $2}' | xargs -r sudo dpkg --purge
  ```

- The OCI agent snap is held; `snap refresh oracle-cloud-agent` still refreshes it. `snap unhold` does not exist in snapd 2.77; use `snap refresh --unhold oracle-cloud-agent`.

## Node limits

A k8s node exhausts descriptors and inotify instances under normal pod churn. The kernel defaults (128 inotify instances, roughly 190k watches, soft 4096 descriptors for services) are too low; systemd path units failed with `Too many open files` until the inotify instance limit was raised. The host is not managed by Flux, so these files are applied by hand:

`/etc/sysctl.d/60-k8s-node.conf`:

```
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 1048576
fs.aio-max-nr = 1048576
```

`/etc/systemd/system.conf.d/60-k8s-node.conf`:

```
[Manager]
DefaultLimitNOFILE=1048576
```

Apply with `sudo sysctl --system` and `sudo systemctl daemon-reexec`. `k3s.service` sets its own `LimitNOFILE=1048576`; the drop-in covers every other service and takes effect at each service's next start. Files under `/etc/sysctl.d/` and `/etc/systemd/system.conf.d/` survive release upgrades, unlike `/etc/sysctl.conf` and package conffiles.
