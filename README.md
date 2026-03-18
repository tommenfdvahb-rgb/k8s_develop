# 基于 sealos 的离线 K8s 一键部署

本仓库用于离线场景的一键式 K8s 部署，基于 sealos 实现。
K8s 镜像与 sealos 二进制已打包到同一个压缩包中。

## 目标

- 提供交互式 Shell 脚本，在离线环境完成 K8s 安装与配置
- 支持单机与多机部署，流程简单可重复
- 便于后续扩展（配置文件、预设参数、日志与错误处理等）

## 已准备内容

- K8s 镜像离线包
- sealos 二进制
- 已打包成压缩包

## 规划产出

- 交互式安装脚本（如 install.sh）
- 可选配置文件（如 config.yaml）
- 日志与验证输出

## 当前已实现

- 提供交互式安装脚本骨架（install.sh）
- 自动定位 sealos（二进制位于 PATH 或脚本目录）
- 支持选择离线 tar 包并做基本校验
- 支持单机/多机模式的参数收集
- 执行前摘要确认
- 支持通过环境变量启用干跑：`DRY_RUN=1 ./install.sh`
- 支持菜单模式：全部部署、简单部署、安装 Rancher、环境校验、后置检查
- 支持非交互动作模式：`ACTION=full|simple|rancher|precheck|postcheck|config`
- 提供快速上手文档：`docs/quick-start.md`
- 提供问题排查文档：`docs/troubleshooting.md`
- 提供单机与高可用参数示例：`examples/single-node.env`、`examples/ha-cluster.env`
- 提供基础 CI 检查：`.github/workflows/ci.yml`

## 安装步骤

1. 准备 Linux 主机，并使用 root 运行脚本。
2. 准备离线包，并确认 `sealos` 二进制位于 PATH 或脚本同目录。
3. 如果需要安装 Rancher，请确保 `kubectl` 可用；`helm` 可位于 PATH、脚本同目录，或 `../rancher/helm/helm`。
4. 给脚本添加可执行权限。
5. 根据需要选择菜单模式或非交互模式执行。

示例：

```bash
chmod +x install.sh
./install.sh
```

如果你已经准备好了部署参数，也可以直接使用环境变量启动：

```bash
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10,192.168.56.11 \
NODES=192.168.56.12,192.168.56.13 \
PASSWORD='your_password' \
bash install.sh
```

## 脚本使用方法

脚本支持两种方式：菜单模式和非交互模式。

### 菜单模式

直接执行：

```bash
./install.sh
```

当未传入 `ACTION`，且未传入 `OFFLINE_TAR` 时，脚本会进入菜单模式。当前菜单项包括：

1. 全部部署（环境校验 + 依赖安装 + K8s + Rancher）
2. 简单部署（环境校验 + K8s）
3. 安装 Rancher
4. 环境校验
5. 集群后置检查
6. 显示当前配置
0. 退出

说明：菜单负责选择动作，但部署参数仍通过环境变量传入，例如 `OFFLINE_TAR`、`MASTERS`、`NODES`、`PASSWORD`。

示例：

```bash
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10 \
PASSWORD='your_password' \
./install.sh
```

### 非交互模式

通过 `ACTION` 指定执行动作，适合自动化调用。

支持的动作：

- `ACTION=menu`：菜单模式
- `ACTION=full`：全部部署
- `ACTION=simple`：简单部署
- `ACTION=rancher`：仅安装 Rancher
- `ACTION=precheck`：仅环境校验
- `ACTION=postcheck`：仅执行后置检查
- `ACTION=config`：打印当前配置

全部部署示例：

```bash
ACTION=full \
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10,192.168.56.11 \
NODES=192.168.56.12 \
PASSWORD='your_password' \
RANCHER_HOSTNAME=rancher.example.local \
bash install.sh
```

简单部署示例：

```bash
ACTION=simple \
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10 \
PASSWORD='your_password' \
bash install.sh
```

仅安装 Rancher：

```bash
ACTION=rancher \
RANCHER_HOSTNAME=rancher.example.local \
bash install.sh
```

离线安装 Rancher Chart：

```bash
ACTION=rancher \
RANCHER_HOSTNAME=rancher.example.local \
RANCHER_CHART_DIR=/opt/offline/rancher/charts \
bash install.sh
```

仅环境校验：

```bash
ACTION=precheck bash install.sh
```

仅后置检查：

```bash
ACTION=postcheck bash install.sh
```

干跑模式：

```bash
DRY_RUN=1 \
ACTION=full \
OFFLINE_TAR=/opt/offline/k8s-images.tar \
MASTERS=192.168.56.10 \
bash install.sh
```

## 环境变量说明

- `OFFLINE_TAR`：离线 tar 包路径，部署 K8s 时必填
- `MASTERS`：Master 节点 IP，逗号分隔，部署 K8s 时必填
- `NODES`：Worker 节点 IP，逗号分隔，可为空
- `PASSWORD`：SSH 密码，可为空
- `PORT`：SSH 端口，默认 `22`
- `ACTION`：执行动作类型
- `DRY_RUN`：为 `1` 时只打印命令，不真正执行
- `SKIP_RANCHER`：为 `1` 时在全部部署中跳过 Rancher
- `RANCHER_HOSTNAME`：安装 Rancher 时使用的域名
- `RANCHER_NAMESPACE`：Rancher 安装命名空间，默认 `cattle-system`
- `RANCHER_CHART_DIR`：离线 Rancher Chart 所在目录

## 脚本流程

- 环境校验：检查内核、内存、磁盘和关键端口
- 依赖安装：根据系统包管理器安装基础组件
- K8s 部署：校验离线包、检查 SSH、调用 `sealos run`
- Rancher 安装：使用在线或离线 Helm Chart 安装 Rancher
- 部署后检查：执行 `kubectl get nodes` 和 `kubectl get pods -A`

## 说明

- 菜单模式当前只负责选择执行动作，不会自动逐项询问部署参数
- 部署参数建议通过环境变量传入，或参考 `examples/` 目录中的示例文件
- 实际离线包内容、Rancher Chart 目录结构，以最终打包产物为准

## TODO

- 明确最终目录结构
- 完善交互式安装脚本（配置文件/更严格校验）
- 增加非交互模式（CLI 参数）
- 补齐镜像导入与后置校验逻辑
- 添加日志与错误处理
- 补充版本与兼容性矩阵

## 仓库结构

```text
.
├── .github/workflows/
│   ├── buildTAR.yml
│   └── ci.yml
├── docs/
│   ├── quick-start.md
│   └── troubleshooting.md
├── examples/
│   ├── single-node.env
│   └── ha-cluster.env
├── CHANGELOG.md
├── LICENSE
├── install.sh
└── README.md
```
