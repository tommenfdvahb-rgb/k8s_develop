#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

LOG_FILE="${LOG_FILE:-/var/log/sealos-install.log}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[%s] %s\n' "$(date +'%F %T')" "$*"; }
warn() { log "WARN: $*"; }
die() { log "ERROR: $*"; exit 1; }

setup_logging() {
	mkdir -p "$(dirname "$LOG_FILE")" || die "无法创建日志目录: $(dirname "$LOG_FILE")"
	touch "$LOG_FILE" || die "无法写入日志: $LOG_FILE"
	exec > >(tee -a "$LOG_FILE") 2>&1
}

trap 'ret=$?; log "脚本退出，返回码=$ret"; exit $ret' EXIT
trap 'log "发生错误, 请查看 $LOG_FILE"' ERR

run_cmd() {
	log "+ $*"
	[[ "$DRY_RUN" == "1" ]] && return 0
	"$@"
}

require_root() {
	[[ "$(id -u)" -ne 0 ]] && die "请用 root 运行"
	setup_logging
}

require_cmds() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null || die "缺少命令: $cmd"
	done
}

detect_package_manager() {
	if command -v yum >/dev/null; then
		PKG_MANAGER=yum
	elif command -v dnf >/dev/null; then
		PKG_MANAGER=dnf
	elif command -v apt-get >/dev/null; then
		PKG_MANAGER=apt
	else
		PKG_MANAGER=unknown
	fi
}

# ================== 环境检查 ==================
precheck() {
	log "开始环境检查..."

	# 内核
	kernel=$(uname -r | cut -d. -f1)
	if (( kernel < 4 )); then
		warn "内核 <4.x，可能影响K8s/Longhorn"
	fi

	# 内存
	mem=$(free -m | awk '/Mem:/ {print $2}')
	(( mem < 4000 )) && warn "内存 <4G"

	# 磁盘
	root_disk=$(df -h / | awk 'NR==2 {print $4}')
	log "剩余磁盘: $root_disk"

	# 端口
	for p in 6443 10250 2379; do
		if ss -lnt | grep -q ":$p "; then
			warn "端口 $p 已占用"
		fi
	done
}

# ================== 依赖安装 ==================
install_deps() {
	log "安装基础依赖..."
	detect_package_manager
	case "$PKG_MANAGER" in
		yum|dnf)
			run_cmd $PKG_MANAGER install -y \
				conntrack \
				socat \
				ipset \
				iptables \
				nfs-utils \
				iscsi-initiator-utils \
				iproute || true
			;;
		apt)
			run_cmd apt-get update || true
			run_cmd apt-get install -y \
				conntrack \
				socat \
				ipset \
				iptables \
				nfs-common \
				open-iscsi \
				iproute2 || true
			;;
		*)
			warn "未识别包管理器，请手动安装依赖"
			;;
	esac

	systemctl enable iscsid --now || true
}

# ================== 校验离线包 ==================
validate_tar() {
	log "检查离线包..."
	[[ ! -f "$1" ]] && die "离线包不存在"
	if ! tar -tf "$1" | head -n 5 >/dev/null; then
		die "非法 tar 包"
	fi
}

# ================== SSH检测 ==================
check_ssh() {
	local hosts="$1"
	local port="$2"

	IFS=',' read -ra arr <<< "$hosts"
	for h in "${arr[@]}"; do
		log "检查 SSH/端口: $h:$port"
		if command -v nc >/dev/null; then
			timeout 5 nc -z -w5 "$h" "$port" || die "端口 $port 不通: $h"
		else
			# /dev/tcp 可能不可用，但作为最后手段保留
			timeout 5 bash -c "</dev/tcp/$h/$port" || die "端口 $port 不通: $h"
		fi
	done
}

# ================== sealos 检测 ==================
ensure_sealos() {
	if command -v sealos >/dev/null; then
		sealos version >/dev/null 2>&1 || die "sealos 无法运行"
		return
	fi

	if [[ -f ./sealos ]]; then
		install -m 0755 ./sealos /usr/bin/sealos
		command -v sealos >/dev/null || die "sealos 安装失败"
	else
		die "未找到 sealos 二进制，请把 sealos 放到脚本所在目录或已安装于 PATH"
	fi
}

# ================== 参数 ==================
OFFLINE_TAR="${OFFLINE_TAR:-}"
MASTERS="${MASTERS:-}"
NODES="${NODES:-}"
PASSWORD="${PASSWORD:-}"
PORT="${PORT:-22}"
ACTION="${ACTION:-}"
SKIP_RANCHER="${SKIP_RANCHER:-0}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.local}"
RANCHER_NAMESPACE="${RANCHER_NAMESPACE:-cattle-system}"
RANCHER_CHART_DIR="${RANCHER_CHART_DIR:-}"

if [[ -z "$ACTION" ]]; then
	if [[ -n "$OFFLINE_TAR" ]]; then
		ACTION="full"
	else
		ACTION="menu"
	fi
fi

usage() {
	cat <<EOF
用法:
OFFLINE_TAR=xxx.tar \
MASTERS=1.1.1.1,1.1.1.2 \
NODES=1.1.1.3 \
PASSWORD=xxx \
bash install.sh

可选动作:
ACTION=menu        # 菜单模式(默认)
ACTION=full        # 全部部署(环境校验+依赖安装+K8s部署+Rancher)
ACTION=simple      # 简单部署(环境校验+K8s部署)
ACTION=rancher     # 仅安装 Rancher
ACTION=precheck    # 仅环境校验
ACTION=postcheck   # 仅集群后置检查
ACTION=config      # 打印当前配置
EOF
	exit 1
}

show_config() {
	cat <<EOF
当前配置:
- ACTION=$ACTION
- OFFLINE_TAR=$OFFLINE_TAR
- MASTERS=$MASTERS
- NODES=$NODES
- PORT=$PORT
- SKIP_RANCHER=$SKIP_RANCHER
- RANCHER_HOSTNAME=$RANCHER_HOSTNAME
- RANCHER_NAMESPACE=$RANCHER_NAMESPACE
- RANCHER_CHART_DIR=$RANCHER_CHART_DIR
- LOG_FILE=$LOG_FILE
- DRY_RUN=$DRY_RUN
EOF
}

require_deploy_params() {
	[[ -z "$OFFLINE_TAR" ]] && die "OFFLINE_TAR 不能为空"
	[[ -z "$MASTERS" ]] && die "MASTERS 不能为空"
}

deploy_k8s() {
	require_deploy_params
	validate_tar "$OFFLINE_TAR"
	ensure_sealos

	check_ssh "$MASTERS" "$PORT"
	[[ -n "$NODES" ]] && check_ssh "$NODES" "$PORT"

	log "开始部署 K8s 集群..."

	args=(sealos run "$OFFLINE_TAR" --masters "$MASTERS")
	[[ -n "$NODES" ]] && args+=(--nodes "$NODES")
	[[ -n "$PASSWORD" ]] && args+=(--passwd "$PASSWORD")
	args+=(--port "$PORT")

	run_cmd "${args[@]}"
}

ensure_helm() {
	if command -v helm >/dev/null; then
		return
	fi

	if [[ -x ./helm ]]; then
		install -m 0755 ./helm /usr/bin/helm
	elif [[ -x ../rancher/helm/helm ]]; then
		install -m 0755 ../rancher/helm/helm /usr/bin/helm
	else
		die "未找到 helm，请放在脚本目录或 ../rancher/helm/helm"
	fi
}

find_chart_file() {
	local chart_dir="$1"
	local pattern="$2"
	local f
	for f in "$chart_dir"/$pattern; do
		if [[ -f "$f" ]]; then
			echo "$f"
			return 0
		fi
	done
	return 1
}

install_rancher() {
	log "开始安装 Rancher..."
	require_cmds kubectl
	ensure_helm

	if [[ "$DRY_RUN" == "1" ]]; then
		log "+ kubectl create namespace $RANCHER_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -"
	else
		kubectl create namespace "$RANCHER_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
	fi

	if [[ -n "$RANCHER_CHART_DIR" ]]; then
		cert_chart="$(find_chart_file "$RANCHER_CHART_DIR" "cert-manager-*.tgz")" || die "离线 chart 不存在: cert-manager-*.tgz"
		rancher_chart="$(find_chart_file "$RANCHER_CHART_DIR" "rancher-*.tgz")" || die "离线 chart 不存在: rancher-*.tgz"

		run_cmd helm upgrade --install cert-manager "$cert_chart" --namespace cert-manager --create-namespace
		run_cmd helm upgrade --install rancher "$rancher_chart" --namespace "$RANCHER_NAMESPACE" --set hostname="$RANCHER_HOSTNAME"
	else
		run_cmd helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
		run_cmd helm repo add jetstack https://charts.jetstack.io
		run_cmd helm repo update

		run_cmd helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.13.3
		run_cmd helm upgrade --install rancher rancher-stable/rancher --namespace "$RANCHER_NAMESPACE" --set hostname="$RANCHER_HOSTNAME"
	fi

	log "Rancher 安装命令已执行，建议检查: kubectl get pods -n $RANCHER_NAMESPACE"
}

full_deploy() {
	precheck
	install_deps
	deploy_k8s
	post_check

	if [[ "$SKIP_RANCHER" != "1" ]]; then
		install_rancher
	else
		log "SKIP_RANCHER=1，跳过 Rancher 安装"
	fi
}

simple_deploy() {
	precheck
	deploy_k8s
	post_check
}

print_menu() {
	cat <<EOF

================= 部署菜单 =================
1) 全部部署 (环境校验 + 依赖安装 + K8s + Rancher)
2) 简单部署 (环境校验 + K8s)
3) 安装 Rancher
4) 环境校验
5) 集群后置检查
6) 显示当前配置
0) 退出
===========================================
EOF
}

menu_mode() {
	while true; do
		print_menu
		read -rp "请输入菜单编号: " choice
		case "$choice" in
			1) full_deploy ;;
			2) simple_deploy ;;
			3) install_rancher ;;
			4) precheck ;;
			5) post_check ;;
			6) show_config ;;
			0) log "退出"; break ;;
			*) warn "无效选项: $choice" ;;
		esac
	done
}

run_action() {
	case "$ACTION" in
		menu) menu_mode ;;
		full|all) full_deploy ;;
		simple|k8s) simple_deploy ;;
		rancher) install_rancher ;;
		precheck|check) precheck ;;
		postcheck) post_check ;;
		config) show_config ;;
		*) usage ;;
	esac
}

# ================== 主流程 ==================
main() {
	require_root
	require_cmds tar awk timeout
	run_action
}

# ================== 部署后检查 ==================
post_check() {
	log "检查集群状态..."

	if command -v kubectl >/dev/null; then
		kubectl get nodes -o wide || warn "kubectl异常"
		kubectl get pods -A || warn "Pod异常"
	else
		warn "kubectl 未安装"
	fi
}

main "$@"