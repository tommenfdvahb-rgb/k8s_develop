#!/usr/bin/env bash
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 固定的默认配置（用户无需通过环境变量覆盖）
OFFLINE_TAR="../images/k8s-offline.tar"
LOG_FILE="../logs/sealos-install.log"
DRY_RUN=0

CONFIG_FILE="k8s.env"

# Track env-provided vars so config file won't override them.
declare -A ENV_SET=()
while IFS='=' read -r env_k _; do
	ENV_SET["$env_k"]=1
done < <(env)


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


load_config_file() {
	[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && return 0
	log "加载配置文件: $CONFIG_FILE"
	local line key value
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%$'\r'}"
		[[ -z "${line//[[:space:]]/}" ]] && continue
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			value="${BASH_REMATCH[2]}"
			[[ "$key" == "CONFIG_FILE" ]] && continue
			[[ -n "${ENV_SET[$key]:-}" ]] && continue
			value="${value#"${value%%[![:space:]]*}"}"
			value="${value%"${value##*[![:space:]]}"}"
			if [[ "$value" =~ ^\".*\"$ ]]; then
				value="${value:1:-1}"
				value="${value//\\\"/\"}"
			elif [[ "$value" =~ ^\'.*\'$ ]]; then
				value="${value:1:-1}"
			fi
			printf -v "$key" '%s' "$value"
		fi
	done < "$CONFIG_FILE"
}

init_action() {
	# 强制使用菜单为默认入口（不从外部 ACTION 覆盖）
	ACTION="menu"
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
		if [[ -d "$PKG_DIR" ]] && compgen -G "$PKG_DIR/*.deb" >/dev/null 2>&1; then
			log "检测到离线 .deb 包，使用 dpkg 本地安装"
			# 依次尝试安装所有 .deb，可能会遇到依赖顺序问题，保持容错
			run_cmd dpkg -i "$PKG_DIR"/*.deb || true
			# 尝试修复并配置已解包但未配置的包
			run_cmd dpkg --configure -a || true
		else
			run_cmd $PKG_MANAGER install -y \
				conntrack \
				socat \
				ipset \
				iptables \
				sshpass \
				nfs-utils \
				iscsi-initiator-utils \
				iproute || true
		fi
			;;
		apt)
		run_cmd apt-get update || true
		# 如果存在离线 deb 包目录，则优先使用 dpkg 本地安装（方案 B）
		PKG_DIR="$SCRIPT_DIR/../packages/deb"
		if [[ -d "$PKG_DIR" ]] && compgen -G "$PKG_DIR/*.deb" >/dev/null 2>&1; then
			log "检测到离线 .deb 包，使用 dpkg 本地安装"
			# 依次尝试安装所有 .deb，可能会遇到依赖顺序问题，保持容错
			run_cmd dpkg -i "$PKG_DIR"/*.deb || true
			# 尝试修复并配置已解包但未配置的包
			run_cmd dpkg --configure -a || true
		else
			run_cmd apt-get install -y \
				conntrack \
				socat \
				ipset \
				iptables \
				nfs-common \
				nfs-utils \
				sshpass \
				open-iscsi \
				iproute2 || true
		fi
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

	if [[ -f ../bin/sealos ]]; then
		install -m 0755 ../bin/sealos /usr/bin/sealos
		command -v sealos >/dev/null || die "sealos 安装失败"
	else
		die "未找到 sealos 二进制，请把 sealos 放到脚本所在目录或已安装于 PATH"
	fi
}

# ================== 参数 ==================
MASTERS="${MASTERS:-}"
NODES="${NODES:-}"
PASSWORD="${PASSWORD:-}"
PORT="${PORT:-22}"
SKIP_RANCHER="${SKIP_RANCHER:-0}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.local}"
RANCHER_NAMESPACE="${RANCHER_NAMESPACE:-cattle-system}"
RANCHER_CHART_DIR="${RANCHER_CHART_DIR:-}"
SSH_USER="${SSH_USER:-root}"

usage() {
	cat <<EOF
用法:
编辑 `k8s.env` 填写 MASTERS/NODES 等，或导出环境变量后运行脚本，例如：
MASTERS=1.1.1.1,1.1.1.2 PASSWORD=xxx bash install.sh

默认以菜单模式启动（无需设置 ACTION）。

可选配置文件: CONFIG_FILE=/path/k8s.env
hosts 条目将根据 MASTERS/NODES 自动生成并写入 /etc/hosts（无需 HOSTS_FILE）
EOF
	exit 1
}

show_config() {
	cat <<EOF
当前配置:
	- CONFIG_FILE=$CONFIG_FILE
	- OFFLINE_TAR=$OFFLINE_TAR
	- MASTERS=$MASTERS
	- NODES=$NODES
	- PORT=$PORT
	- SKIP_RANCHER=$SKIP_RANCHER
	- RANCHER_HOSTNAME=$RANCHER_HOSTNAME
	- RANCHER_NAMESPACE=$RANCHER_NAMESPACE
	- RANCHER_CHART_DIR=$RANCHER_CHART_DIR
	- SSH_USER=$SSH_USER
	- LOG_FILE=$LOG_FILE
EOF
}

require_deploy_params() {
	[[ -z "$MASTERS" ]] && die "MASTERS 不能为空"
}

# ================== 主机名/hosts 配置 ==================
collect_hosts() {
	local combined=""
	if [[ -n "$MASTERS" ]]; then
		combined="$MASTERS"
	fi
	if [[ -n "$NODES" ]]; then
		if [[ -n "$combined" ]]; then
			combined+=",${NODES}"
		else
			combined="$NODES"
		fi
	fi
	combined="${combined// /}"
	echo "$combined"
}

get_hostname_for_host() {
	local host="$1"
	# 如果用户提供了 HOSTNAME_MAP（保留兼容），优先使用
	if [[ -n "${HOSTNAME_MAP:-}" ]]; then
		local pair ip name
		IFS=',' read -ra pairs <<< "${HOSTNAME_MAP// /}"
		for pair in "${pairs[@]}"; do
			[[ -z "$pair" ]] && continue
			if [[ "$pair" != *=* ]]; then
				die "HOSTNAME_MAP 格式错误: $pair"
			fi
			ip="${pair%%=*}"
			name="${pair#*=}"
			if [[ "$ip" == "$host" ]]; then
				echo "$name"
				return 0
			fi
		done
	fi
	# 否则按 MASTERS/NODES 列表自动生成：单个主机使用 master/node，多主机使用 master1/master2...
	generate_hostname_map
	local pair ip name
	IFS=',' read -ra pairs <<< "${HOSTNAME_MAP// /}"
	for pair in "${pairs[@]}"; do
		ip="${pair%%=*}"
		name="${pair#*=}"
		if [[ "$ip" == "$host" ]]; then
			echo "$name"
			return 0
		fi
	done
	return 1
}

generate_hostname_map() {
	# 如果已生成则直接返回
	[[ -n "${HOSTNAME_MAP:-}" ]] && return 0
	local map_list=()
	# 生成 masters 映射
	if [[ -n "${MASTERS:-}" ]]; then
		IFS=',' read -ra mlist <<< "${MASTERS// /}"
		local count=${#mlist[@]}
		local i
		for i in "${!mlist[@]}"; do
			local ip=${mlist[i]}
			if (( count == 1 )); then
				map_list+=("${ip}=master")
			else
				map_list+=("${ip}=master$((i+1))")
			fi
		done
	fi
	# 生成 nodes 映射
	if [[ -n "${NODES:-}" ]]; then
		IFS=',' read -ra nlist <<< "${NODES// /}"
		local ncount=${#nlist[@]}
		local j
		for j in "${!nlist[@]}"; do
			local ip=${nlist[j]}
			if (( ncount == 1 )); then
				map_list+=("${ip}=node")
			else
				map_list+=("${ip}=node$((j+1))")
			fi
		done
	fi
	HOSTNAME_MAP="$(IFS=,; echo "${map_list[*]}")"
}

is_local_host() {
	local host="$1"
	[[ "$host" == "localhost" || "$host" == "127.0.0.1" ]] && return 0
	[[ "$host" == "$(hostname)" ]] && return 0
	if command -v ip >/dev/null; then
		local ip
		while read -r ip; do
			[[ "$ip" == "$host" ]] && return 0
		done < <(ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1)
	fi
	return 1
}

remote_exec() {
	local host="$1"
	shift
	log "+ [$host] $*"
	[[ "$DRY_RUN" == "1" ]] && return 0
	local ssh_cmd=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$PORT" "${SSH_USER}@${host}")
	if [[ -n "$PASSWORD" ]]; then
		ssh_cmd=(sshpass -p "$PASSWORD" "${ssh_cmd[@]}")
	fi
	"${ssh_cmd[@]}" "$@"
}

build_hosts_block() {
	# 由 MASTERS/NODES 或 HOSTNAME_MAP 自动生成 hosts 块（每行: IP HOSTNAME）
	local tmp
	tmp="$(mktemp)"
	: > "$tmp"
	generate_hostname_map
	local pair ip name
	IFS=',' read -ra pairs <<< "${HOSTNAME_MAP// /}"
	for pair in "${pairs[@]}"; do
		[[ -z "$pair" ]] && continue
		ip="${pair%%=*}"
		name="${pair#*=}"
		printf '%s %s\n' "$ip" "$name" >> "$tmp"
	done
	# 清理空行（保险）
	awk 'NF {print $0}' "$tmp" > "${tmp}.clean"
	mv "${tmp}.clean" "$tmp"
	echo "$tmp"
}

apply_hosts_block_local() {
	local block_file="$1"
	local tmp
	tmp="$(mktemp)"
	# 使用 sed 删除已存在的 k8s-autoinstall 区块（更兼容不同 awk 实现）
	sed '/^# k8s-autoinstall begin$/,/^# k8s-autoinstall end$/d' /etc/hosts > "$tmp"
	{
		echo "# k8s-autoinstall begin"
		cat "$block_file"
		echo "# k8s-autoinstall end"
	} >> "$tmp"
	run_cmd cp "$tmp" /etc/hosts
	run_cmd chmod 0644 /etc/hosts
	rm -f "$tmp"
}

apply_hosts_block_remote() {
	local host="$1"
	local block_file="$2"
	remote_exec "$host" "cat > /tmp/k8s-hosts.block" < "$block_file"
	remote_exec "$host" bash -s <<'EOF'
set -euo pipefail
block="/tmp/k8s-hosts.block"
tmp="$(mktemp)"
sed '/^# k8s-autoinstall begin$/,/^# k8s-autoinstall end$/d' /etc/hosts > "$tmp"
{
	echo "# k8s-autoinstall begin"
	cat "$block"
	echo "# k8s-autoinstall end"
} >> "$tmp"
cp "$tmp" /etc/hosts
chmod 0644 /etc/hosts
rm -f "$tmp" "$block"
EOF
}

set_hostname_local() {
	local name="$1"
	if command -v hostnamectl >/dev/null; then
		run_cmd hostnamectl set-hostname "$name"
	else
		run_cmd hostname "$name"
		echo "$name" > /etc/hostname || true
	fi
}

set_hostname_remote() {
	local host="$1"
	local name="$2"
	remote_exec "$host" env NEW_HOSTNAME="$name" bash -s <<'EOF'
set -euo pipefail
name="${NEW_HOSTNAME:?}"
if command -v hostnamectl >/dev/null 2>&1; then
	hostnamectl set-hostname "$name"
else
	hostname "$name"
	echo "$name" > /etc/hostname
fi
EOF
}

configure_hosts() {
	local need_hosts=0
	local need_hostname=0
	# 总是根据 MASTERS/NODES 生成并更新 hosts 与主机名（若未提供则跳过）
	if [[ -n "$MASTERS" || -n "$NODES" ]]; then
		need_hostname=1
		need_hosts=1
	fi
	if (( need_hosts == 0 && need_hostname == 0 )); then
		log "未提供 MASTERS/NODES，跳过主机名/hosts 配置"
		return 0
	fi

	local host_list
	host_list="$(collect_hosts)"
	if [[ -z "$host_list" ]]; then
		log "未设置 MASTERS/NODES，仅在本机应用 hosts/主机名"
	fi

	local block_file=""
	if (( need_hosts == 1 )); then
		block_file="$(build_hosts_block)"
		[[ -s "$block_file" ]] || die "hosts 内容为空，请检查 MASTERS/NODES"
	fi

	local local_host=""
	local remote_hosts=()
	if [[ -n "$host_list" ]]; then
		local host
		IFS=',' read -ra hosts <<< "$host_list"
		for host in "${hosts[@]}"; do
			[[ -z "$host" ]] && continue
			if is_local_host "$host"; then
				local_host="$host"
			else
				remote_hosts+=("$host")
			fi
		done
	fi

	if (( need_hosts == 1 )); then
		if [[ -n "$local_host" || -z "$host_list" ]]; then
			log "更新本机 /etc/hosts"
			apply_hosts_block_local "$block_file"
		fi
	fi

	if (( need_hostname == 1 )); then
		generate_hostname_map
		if [[ -n "$local_host" ]]; then
			local local_name
			if local_name="$(get_hostname_for_host "$local_host")"; then
				log "设置本机主机名: $local_name"
				set_hostname_local "$local_name"
			else
				warn "无法为本机生成主机名: $local_host"
			fi
		fi
	fi

	if ((${#remote_hosts[@]} > 0)); then
		require_cmds ssh
		check_ssh "$(IFS=','; echo "${remote_hosts[*]}")" "$PORT"

		local host
		for host in "${remote_hosts[@]}"; do
			if (( need_hosts == 1 )); then
				log "更新远程 /etc/hosts: $host"
				apply_hosts_block_remote "$host" "$block_file"
			fi
			if (( need_hostname == 1 )); then
				local name
				if name="$(get_hostname_for_host "$host")"; then
					log "设置远程主机名: $host => $name"
					set_hostname_remote "$host" "$name"
				else
					warn "无法为远程主机生成主机名: $host"
				fi
			fi
		done
	fi

	[[ -n "$block_file" ]] && rm -f "$block_file"
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

simple_deploy() {
	echo "执行完整部署流程: 环境检查 + 依赖安装 + 主机名/hosts 配置 + K8s 部署 + 集群状态检查"
	echo "组件存在：kubernetes:v1.30.14，calico:v3.27.4，Longhorn:v1.6.4，ingress-nginx:v1.11.3"
    #环境检查
	precheck
    #依赖安装
	install_deps
    #更新hosts
	configure_hosts
    #开始部署
	deploy_k8s
    #检查集群状态
	post_check
}

print_menu() {
	cat <<EOF

================= 部署菜单 =================
1) 集群部署 (环境校验 + 依赖安装 + K8s)
2) 安装 Rancher
3) 环境校验
4) 集群后置检查
5) 显示当前配置
6) 配置 hosts/主机名
0) 退出
===========================================
EOF
}

menu_mode() {
	while true; do
		print_menu
		read -rp "请输入菜单编号: " choice
		case "$choice" in
			1) simple_deploy ;;
			2) install_rancher ;;
			3) precheck ;;
			4) post_check ;;
			5) show_config ;;
			6) configure_hosts ;;
			0) log "退出"; break ;;
			*) warn "无效选项: $choice" ;;
		esac
	done
}
run_action() {
	case "$ACTION" in
		menu) menu_mode ;;
		wizard) wizard_mode ;;
		full|all) full_deploy ;;
		simple|k8s) simple_deploy ;;
		rancher) install_rancher ;;
		precheck|check) precheck ;;
		postcheck) post_check ;;
		hosts) configure_hosts ;;
		config) show_config ;;
		*) usage ;;
	esac
}
# ================== 主流程 ==================
main() {
	load_config_file
	init_action
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