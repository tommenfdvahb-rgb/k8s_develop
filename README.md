# 离线 K8s 一键部署

用于离线环境的一键式 K8s 部署脚本，基于 sealos 实现支持自动主机名与 hosts 配置、依赖安装、K8s 部署以及可选的 Rancher 安装。

## 当前功能

- 依赖安装：自动识别 apt/yum/dnf；在 Debian/Ubuntu 上如发现上级目录存在 packages/deb/*.deb，将优先离线安装。
- 主机名与 hosts 自动配置：基于 `MASTERS`/`NODES` 生成 master/node 序号；
- K8s 部署：校验离线镜像 tar（默认路径为上级目录 images/k8s-offline.tar），使用 sealos 部署集群。
- 可选安装 Rancher：(待完成)
- 日志：输出到上级目录 logs/sealos-install.log

## 快速开始
1) 从[release](https://github.com/IonRh/k8s_develop/releases)页面下载对应架构的 k8s-offline-<arch>-<pkg>.tar.gz，解压到任意目录。
2) 进入解压后的 scripts 目录，编辑 k8s.env 配置环境变量。
3) 执行安装脚本：

```bash
cd release/scripts
chmod +x install.sh
./install.sh
```

示例配置（摘自 k8s.env）：

```bash
MASTERS=192.168.56.10,192.168.56.11
NODES=192.168.56.12,192.168.56.13,192.168.56.14
PASSWORD=your_password
PORT=22
SSH_USER=root

# 可选：Rancher
SKIP_RANCHER=1
# RANCHER_HOSTNAME=rancher.local
# RANCHER_NAMESPACE=cattle-system
# RANCHER_CHART_DIR=/path/to/offline/charts
```

## 菜单项说明

1) 集群部署（环境校验 + 依赖安装 + 主机名/hosts 配置 + K8s 部署 + 后置检查）
2) 安装 Rancher（需 kubectl/helm）
3) 环境校验（内核/内存/磁盘/关键端口）
4) 集群后置检查（kubectl 节点与 Pod 列表）
5) 显示当前配置
6) 配置 hosts/主机名（仅应用该步骤，不做部署）

## 配置项（环境变量/配置文件键）

- MASTERS：Master 节点 IP，逗号分隔（必填）。
- NODES：Worker 节点 IP，逗号分隔（可空）。
- PASSWORD：SSH 密码。
- PORT：SSH 端口，默认 22。
- SSH_USER：SSH 用户，默认 root。
- SKIP_RANCHER：为 1 时跳过 Rancher（仅在你扩展流程时有用）。
- RANCHER_HOSTNAME：安装 Rancher 时使用的域名。
- RANCHER_NAMESPACE：Rancher 命名空间，默认 cattle-system。
- RANCHER_CHART_DIR：离线 Rancher Chart 所在目录（提供 cert-manager-*.tgz 与 rancher-*.tgz）。
- CONFIG_FILE：配置文件路径，默认 k8s.env。

说明：脚本会先读取环境变量，再加载配置文件，配置文件不会覆盖已存在的环境变量。

## 前置条件与检查项

- 建议内核版本 >= 4.x，内存 >= 4G；关键端口 6443/10250/2379 不被占用。
- 目标主机之间 SSH 可达；请设置 PASSWORD
- 完成部署后可执行(或执行./install.sh 选择4)：

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

## 压缩包结构

在release目录下：k8s-offline-<架构>-<pkg>.tar.gz。解压后包含：

- release/bin：sealos 与版本文件
- release/images：k8s 镜像 tar（k8s-offline.tar）
- release/packages：离线依赖（deb 或 rpm）
- release/scripts：本脚本副本

### 示例解压后目录结构
```text
release/
├── bin/
│   └── sealos
├── images/
│   └── k8s-offline.tar
├── packages/
│   ├── deb/                    # Debian/Ubuntu系列存在这个目录
│   │   ├── *.deb 文件（很多个）
│   └── rpm/                    # RPM 系列存在这个目录
│       ├── *.rpm 文件（很多个）
├── scripts/
│   └── install.sh
└── version.txt
```

—— 如有问题或改进建议，欢迎反馈与贡献。
