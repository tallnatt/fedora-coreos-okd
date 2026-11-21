# OKD on Fedora CoreOS (libvirt)

Automated installation of an **OKD** Kubernetes cluster on **Fedora CoreOS (FCOS)** using **libvirt/KVM**, **qcow2 copy-on-write overlays**, and **Butane/Ignition**.

## Features

- **Interactive topology selection** (`standard`, `compact`, or `sno`), or non-interactive via `TOPOLOGY=...`
- **qcow2 copy-on-write overlays** per VM backed by a single Fedora CoreOS base image (`fcos-base.qcow2`)
- **Butane-compiled Ignition configs** per node (merges OKD's `bootstrap.ign` / `master.ign` / `worker.ign` / `bootstrap-in-place-for-live-iso.ign` and sets per-node hostname/customizations)
- **Self-contained libvirt NAT networking** with `dnsmasq` DNS + static DHCP reservations and host `haproxy` load balancing (`6443`, `22623`, `80`, `443`)
- **End-to-end OKD lifecycle**: waits for bootstrap, removes the temporary bootstrap VM, auto-approves CSRs, and waits for `install-complete`

## Prerequisites

Run on a Linux host with KVM/libvirt installed and `sudo` access:

- `libvirt` (`virsh`), `virt-install`, `qemu-img`
- `haproxy`, `jq`, `curl`, `xz`, `sha256sum`
- An SSH public key (default `~/.ssh/id_ed25519.pub`)
- `openshift-install`, `oc`, and `butane` (automatically downloaded into `./bin/` by `make download` if not already in `PATH`)

## Quick Start

1. **(Optional) Customize configuration:**
   ```bash
   cp cluster.env.example cluster.env
   # Edit cluster.env as needed (OKD_VERSION, BASE_DOMAIN, node sizing, etc.)
   ```

2. **Run the automated install** (prompts for topology):
   ```bash
   make install
   ```

   Or specify the topology non-interactively:
   ```bash
   make install TOPOLOGY=compact
   ```

3. **Check cluster status:**
   ```bash
   make status
   ```

4. **Tear down the cluster:**
   ```bash
   make destroy
   # Pass CLEAN_BASE=1 to also remove the cached fcos-base.qcow2 image:
   CLEAN_BASE=1 make destroy
   ```

## Topology Options

| Topology | VMs (Install) | VMs (Steady State) | Notes |
| :--- | :--- | :--- | :--- |
| `standard` | 1 bootstrap + 3 master + 2+ worker | 3 master + 2+ worker | Full HA; workloads run on workers |
| `compact` | 1 bootstrap + 3 master | 3 master | 3-node etcd HA; masters are schedulable |
| `sno` | 1 node (`sno-0`) | 1 node (`sno-0`) | Single-Node OKD (`bootstrap-in-place`) |

## Step-by-Step Targets

You can also run each stage individually:

1. `make check-deps` — Verify host tools and libvirt connectivity
2. `make select-topology` — Prompt for cluster topology
3. `make download` — Download FCOS base image and OKD/Butane tools
4. `make network` — Create libvirt NAT network (`dnsmasq`) and configure `haproxy`
5. `make ignition` — Generate `install-config.yaml`, OKD Ignition files, and per-node Butane -> Ignition configs
6. `make overlays` — Create per-node `qcow2` overlays backed by `fcos-base.qcow2`
7. `make vms` — Provision and boot VMs in libvirt (`-fw_cfg` for Ignition)
8. `make finish` — Wait for bootstrap, remove bootstrap VM, approve CSRs, wait for `install-complete`
