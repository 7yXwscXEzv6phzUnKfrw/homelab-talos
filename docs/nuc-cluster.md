# NUC Talos Cluster

## Cluster

| Field | Value |
|---|---|
| Cluster name | nuc-cluster |
| Kubernetes API VIP | 192.168.90.20 |
| Network | 192.168.90.0/24 |
| Gateway | 192.168.90.1 |
| DNS | 192.168.90.2 |
| Talos version | v1.13.2 |
| Platform | metal |
| Architecture | amd64 |
| Secure Boot | Enabled |
| Bootloader | UEFI only |

## Hardware

| Field | Value |
|---|---|
| Hardware | 3x Intel NUC 11 |
| Install disk | /dev/nvme0n1 |
| Primary NIC interface | enp88s0 |

## Nodes

| Node | IP | Role | Disk | Interface | MAC Address |
|---|---:|---|---|---|---|
| nuc1 | 192.168.90.10 | controlplane | /dev/nvme0n1 | enp88s0 | 54:b2:03:f0:aa:03 |
| nuc2 | 192.168.90.11 | controlplane | /dev/nvme0n1 | enp88s0 | 54:b2:03:fd:40:53 |
| nuc3 | 192.168.90.12 | controlplane | /dev/nvme0n1 | enp88s0 | 48:21:0b:35:01:0c |

## Image Factory

| Field | Value |
|---|---|
| Schematic ID | 5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4 |
| SecureBoot ISO | https://factory.talos.dev/image/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4/v1.13.2/metal-amd64-secureboot.iso |
| SecureBoot installer image | factory.talos.dev/metal-installer-secureboot/5456009e429379979faf6c8c7c4791309a0b125f3caafc728e8f90c3c5f0deb4:v1.13.2 |

## Extensions

- siderolabs/intel-ucode
- siderolabs/iscsi-tools
- siderolabs/util-linux-tools

## Secure Boot Notes

Secure Boot keys were enrolled from the Talos SecureBoot USB using:

```text
Enroll Secure Boot keys: auto
```

Secure Boot was verified with:

```bash
talosctl -n <node-ip> -e <node-ip> get securitystate \
  --talosconfig clusters/nuc/talos/generated/talosconfig
```

Expected result:

```text
SECUREBOOT   true
```

## Generated Files

Generated Talos files under `clusters/nuc/talos/generated/` are not committed because they contain secrets, certificates, and tokens.

Do not commit these unless encrypted with SOPS:

- talosconfig
- controlplane.yaml
- worker.yaml
- controlplane-final.yaml
- nuc1-controlplane.yaml
- nuc2-controlplane.yaml
- nuc3-controlplane.yaml
- kubeconfig

## Install Boundary

Manual phase:

1. BIOS configuration
2. Secure Boot key enrollment
3. USB boot into Talos maintenance mode
4. Apply per-node Talos machine config
5. Verify NVMe boot, Secure Boot, hostname, services, and partitions

Automated phase:

1. Bootstrap Talos with Ansible
2. Fetch kubeconfig
3. Bootstrap Flux
4. Let Flux manage Kubernetes resources
