# OpenShift Local/CRC runbook

## Current validated state

- Host: Fedora 44 Workstation, x86_64
- CRC/OpenShift Local: 2.64.0
- Starting bundle: 4.22.14
- Current cluster: OpenShift `5.0.0-rc.7`
- VM resources: 4 vCPU, 12288 MiB RAM, 60 GiB disk
- Ingress: user networking with ports `8080`/`8443`
- The Kubernetes API and admin kubeconfig work normally
- The web console and normal OAuth flow are nonfunctional in this configuration

## Daily commands

```bash
crc start
crc status
export KUBECONFIG="$HOME/.crc/machines/crc/kubeconfig"
oc --context admin whoami
crc stop
```

`crc status` may continue to show the original bundle version after an in-place
upgrade. Use `oc get clusterversion` for the authoritative installed version.

## Validated 4.22.14 to 5.0.0-rc.7 upgrade

### Preconditions

- Start from a fully healthy 4.22.14 cluster.
- Increase the VM to at least 12288 MiB RAM.
- Keep the admin kubeconfig at `~/.crc/machines/crc/kubeconfig`.

```bash
crc config set memory 12288
crc stop
crc start
```

### Upgrade

```bash
oc patch clusterversion version --type merge \
  -p '{"spec":{"channel":"candidate-5.0"}}'

oc adm upgrade \
  --to-image quay.io/openshift-release-dev/ocp-release@sha256:d86593b04acdcce3a07c8d20757ccf44571aec502f1a50f7d8f2fe28f0b6a852 \
  --allow-explicit-upgrade \
  --allow-not-recommended
```

`--allow-not-recommended` is needed because this release candidate carries a
HyperShift-specific warning. This cluster is standalone CRC/SNO, so the warning
does not apply.

## 5.0 node rebase recovery

The 4.22 CRC image includes four layered packages:

```text
9pfs
cloud-init
gvisor-tap-vsock-gvforwarder
hyperv-daemons
```

During the 5.0 node rebase, `rpm-ostree` needs repositories that can resolve
those packages again. The CRC bundle builder intentionally removes its temporary
local RPM repository after creating the 4.22 bundle, leaving only the disabled
9pfs Copr repository.

If the upgrade pauses in machine-config with either error:

```text
error: No enabled repositories
error: Packages not found: cloud-init, gvisor-tap-vsock-gvforwarder, hyperv-daemons
```

restore the package sources inside the VM:

```bash
# Enable the existing 9pfs repository.
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$HOME/.crc/machines/crc/id_ed25519" -p 2222 core@127.0.0.1 \
  "sudo sed -i 's/^enabled=0/enabled=1/' \
   '/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:mskvarla:9pfs.repo'"
```

Then rebuild a temporary local RPM repository with the three missing packages
from CentOS Stream 9:

```bash
mkdir -p /tmp/crc-5-rpms

dnf5 \
  --repofrompath=c9-base,https://mirror.stream.centos.org/9-stream/BaseOS/x86_64/os/ \
  --repofrompath=c9-app,https://mirror.stream.centos.org/9-stream/AppStream/x86_64/os/ \
  --disablerepo='*' \
  --enablerepo='c9-base,c9-app' \
  download --resolve --alldeps --destdir /tmp/crc-5-rpms \
  cloud-init-24.4-8.el9.1.noarch \
  gvisor-tap-vsock-gvforwarder-0.8.7-1.el9.x86_64 \
  hyperv-daemons-0-0.44.20190303git.el9.x86_64

createrepo_c /tmp/crc-5-rpms

scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$HOME/.crc/machines/crc/id_ed25519" -P 2222 \
  -r /tmp/crc-5-rpms core@127.0.0.1:/home/core/

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "$HOME/.crc/machines/crc/id_ed25519" -p 2222 core@127.0.0.1 \
  "sudo sh -c \"printf '%s\n' '[local]' 'name=Local repo' \
   'baseurl=file:///home/core/crc-5-rpms/' 'enabled=1' 'gpgcheck=0' \
   > /etc/yum.repos.d/local.repo\""
```

Finally, restart the machine-config daemon so it performs a fresh reconciliation:

```bash
oc rollout restart daemonset/machine-config-daemon \
  -n openshift-machine-config-operator
```

Do not manually run `rpm-ostree rebase`; machine-config-daemon owns that
transaction. The daemon will stage the 5.0 OS image, reboot the VM, and then
reconcile the new machine config.

## Verified result

```bash
oc get clusterversion version -o wide
oc get co
oc get nodes -o wide
crc status
oc adm upgrade
```

Expected result:

```text
version   5.0.0-rc.7   True   False   Cluster version is 5.0.0-rc.7
```

All cluster operators should be `Available=True`, `Progressing=False`, and
`Degraded=False`. The single node should be `Ready`.

## Source and development releases

CRC is a bundle runner, not an OpenShift compiler. The supported path for a
development or source-built OpenShift release is:

1. Build or obtain a release image.
2. Use the matching `snc` branch to install that release as a single-node
   cluster and package it as a `.crcbundle`.
3. Point CRC at the generated bundle and start it.

Relevant variables:

```bash
export OPENSHIFT_PULL_SECRET_PATH="$HOME/.crc/pull-secret.json"
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="quay.io/example/ocp-release:5.1.0"
./snc.sh
./createdisk.sh crc-tmp-install-data
```

`OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` is the hook for a release image
assembled from source.

The `candidate-5.1` channel is visible, but no 5.1 release was published at the
time this runbook was validated. Until one is published, 5.1 testing requires a
source-built release image and the matching SNC branch.
