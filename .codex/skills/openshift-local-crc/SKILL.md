---
name: openshift-local-crc
description: Operate, troubleshoot, and upgrade a local OpenShift Local/CRC cluster, including in-place OpenShift upgrades and node rebase recovery. Do not use for production OpenShift or upstream Kubernetes clusters.
---

# OpenShift Local (CRC)

Use this skill when the user asks about the local OpenShift Local/CRC cluster on this machine.

Key facts:

- CRC binary: `~/.local/bin/crc`
- `oc` binary: `~/.local/bin/oc`
- Admin kubeconfig: `~/.crc/machines/crc/kubeconfig`
- Pull secret: `~/.crc/pull-secret.json`
- Validated cluster baseline: OpenShift `5.0.0-rc.7`
- VM size needed for 5.x upgrades: 4 vCPU, 12288 MiB RAM, 60 GiB disk
- Web console/OAuth are intentionally nonfunctional because ingress uses ports `8080`/`8443`

For setup, upgrade, troubleshooting, or source-build questions, read [references/runbook.md](references/runbook.md). Do not manually run `rpm-ostree rebase`; let machine-config-daemon own that transaction.
