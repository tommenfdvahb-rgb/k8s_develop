# Quick Start

This guide provides the shortest path to deploy an offline Kubernetes cluster with sealos.

## Prerequisites

- Linux host with root or sudo permissions
- Offline tar package prepared in advance
- sealos binary available in PATH or the same directory as install.sh

## Single-node install

```bash
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10 \
PASSWORD='your_password' \
PORT=22 \
bash install.sh
```

## Multi-node install

```bash
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10,192.168.56.11 \
NODES=192.168.56.12,192.168.56.13 \
PASSWORD='your_password' \
PORT=22 \
bash install.sh
```

## Dry run mode

```bash
DRY_RUN=1 \
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10 \
bash install.sh
```

## Common variables

- OFFLINE_TAR: offline image tar path (required)
- MASTERS: master node IP list, comma-separated
- NODES: worker node IP list, comma-separated, optional
- PASSWORD: SSH password, optional
- PORT: SSH port, default 22
- LOG_FILE: install log path, default /var/log/sealos-install.log
- DRY_RUN: set 1 to print commands only
