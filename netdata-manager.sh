#!/usr/bin/env bash
# =============================================================================
#  Netdata 一键管理脚本（父节点 / 子节点）
#
#  仓库：https://github.com/nekoangel233/netdata-manager
#
#  用法：
#    父节点（主节点，用来看所有服务器）：
#      curl -fsSL https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh | sudo bash -s -- parent
#
#    子节点（新加的服务器，只推送数据）：
#      curl -fsSL https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh | sudo bash -s -- child --parent 100.x.x.x --key <API_KEY>
#      （这条命令可以在父节点上执行 join-cmd 直接生成）
#
#    部署完成后，本脚本会安装为 netdata-manager 命令：
#      sudo netdata-manager join-cmd    # 父节点：打印子节点加入命令
#      sudo netdata-manager rotate-key  # 父节点：更换 API Key（旧 Key 立即作废）
#      sudo netdata-manager status      # 查看状态 / 已连接的子节点
#      sudo netdata-manager restart     # 重启 Netdata
#      sudo netdata-manager logs        # 查看最近的推送(streaming)日志
#      sudo netdata-manager update      # 更新本脚本到最新版
#      sudo netdata-manager uninstall   # 卸载 Netdata
#
#  常用选项：
#    --no-tailscale        不使用 Tailscale（改用内网 IP，需配合 --bind-ip）
#    --bind-ip IP          父节点额外监听的 IP（默认自动取 Tailscale IP）
#    --allow PATTERN       父节点允许接入的来源，默认 "100.*"（Tailscale 网段）
#    --retention SIZE      父节点最详细数据层的磁盘上限，默认 1GiB
#    --ml on|off           是否开启机器学习异常检测，默认 off（省 CPU）
#    --interval N          子节点采集间隔（秒），默认 2
#    --ts-authkey KEY      Tailscale 认证密钥，填了就不用手动点链接登录
#    --full                子节点已部署时也强制完整重装配置（默认只更新 Key 和父节点地址）
#
#  注意：脚本会用自己的配置覆盖 netdata.conf 和 stream.conf，
#        覆盖前会自动备份为 *.bak.时间戳。
# =============================================================================
set -euo pipefail

STATE_FILE="/etc/netdata-manager.conf"
SCRIPT_URL="https://raw.githubusercontent.com/nekoangel233/netdata-manager/main/netdata-manager.sh"
# 装到 /usr/bin：CentOS/RHEL 的 sudo 不会在 /usr/local/bin 里找命令
INSTALL_PATH="/usr/bin/netdata-manager"
LEGACY_PATH="/usr/local/bin/netdata-manager"
SELF="netdata-manager"

# ---- 默认参数 ----------------------------------------------------------------
USE_TAILSCALE=1
BIND_IP=""
ALLOW_FROM="100.*"
RETENTION="1GiB"
ML="off"
INTERVAL=2
PARENT_IP=""
API_KEY=""
TS_AUTHKEY=""
FULL=0

# ---- 输出工具 ----------------------------------------------------------------
c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_cyan=$'\033[36m'; c_off=$'\033[0m'
log()  { echo "${c_green}[✓]${c_off} $*"; }
info() { echo "${c_cyan}[i]${c_off} $*"; }
warn() { echo "${c_yellow}[!]${c_off} $*"; }
die()  { echo "${c_red}[✗]${c_off} $*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行（命令前加 sudo）"; }

usage() {
  # 通过 curl | bash 运行时 $0 不是文件，只能打印仓库地址
  if [ -f "$0" ]; then
    sed -n '2,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
  else
    echo "用法见：https://github.com/nekoangel233/netdata-manager"
  fi
  exit 0
}

# 把本脚本安装为 netdata-manager 命令，方便以后执行 status / logs 等
install_self() {
  local tmp
  tmp="$(mktemp)"
  if curl -fsSL "$SCRIPT_URL" -o "$tmp" && head -n1 "$tmp" | grep -q bash; then
    install -m 755 "$tmp" "$INSTALL_PATH"
    log "已安装命令：$INSTALL_PATH（以后直接用 sudo netdata-manager status 等）"
  elif [ -f "$0" ] && [ "$(readlink -f "$0")" != "$INSTALL_PATH" ]; then
    install -m 755 "$0" "$INSTALL_PATH"
    log "已安装命令：$INSTALL_PATH"
  else
    warn "没能安装 netdata-manager 命令（下载失败），不影响监控本身"
  fi
  rm -f "$tmp"
  rm -f "$LEGACY_PATH"   # 清理旧版本装在 /usr/local/bin 的副本
}

# ---- 参数解析 ----------------------------------------------------------------
parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-tailscale) USE_TAILSCALE=0 ;;
      --bind-ip)      BIND_IP="${2:?--bind-ip 需要一个 IP}"; shift ;;
      --allow)        ALLOW_FROM="${2:?--allow 需要一个值}"; shift ;;
      --retention)    RETENTION="${2:?--retention 需要一个值，如 2GiB}"; shift ;;
      --ml)           ML="${2:?--ml 需要 on 或 off}"; shift ;;
      --interval)     INTERVAL="${2:?--interval 需要秒数}"; shift ;;
      --parent)       PARENT_IP="${2:?--parent 需要父节点 IP}"; shift ;;
      --key)          API_KEY="${2:?--key 需要 API Key}"; shift ;;
      --ts-authkey)   TS_AUTHKEY="${2:?--ts-authkey 需要密钥}"; shift ;;
      --full)         FULL=1 ;;
      -h|--help)      usage ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
    shift
  done
  case "$ML" in on|off) ;; *) die "--ml 只能是 on 或 off" ;; esac
}

# ---- 状态文件 ----------------------------------------------------------------
load_state() { [ -f "$STATE_FILE" ] && . "$STATE_FILE" || true; }
save_state() {
  umask 077
  cat > "$STATE_FILE" <<EOF
ROLE="$1"
API_KEY="$API_KEY"
PARENT_IP="$PARENT_IP"
BIND_IP="$BIND_IP"
EOF
}

# ---- Netdata 安装与路径 ------------------------------------------------------
netdata_installed() {
  command -v netdata >/dev/null 2>&1 || [ -x /opt/netdata/bin/netdata ]
}

detect_paths() {
  if [ -d /opt/netdata/etc/netdata ]; then
    NETDATA_ETC=/opt/netdata/etc/netdata      # 静态版安装路径
  else
    NETDATA_ETC=/etc/netdata                  # 系统包安装路径
  fi
  [ -d "$NETDATA_ETC" ] || die "找不到 Netdata 配置目录（$NETDATA_ETC）"
}

install_netdata() {
  if netdata_installed; then
    log "Netdata 已安装，跳过安装"
    return
  fi
  command -v curl >/dev/null 2>&1 || die "需要 curl，请先安装：apt install curl 或 yum install curl"
  info "正在安装 Netdata（稳定版）..."
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o "$tmp/kickstart.sh"
  sh "$tmp/kickstart.sh" --stable-channel --disable-telemetry --non-interactive </dev/null
  rm -rf "$tmp"
  netdata_installed || die "Netdata 安装失败，请查看上面的输出"
  log "Netdata 安装完成"
}

backup() {
  local f="$1"
  if [ -f "$f" ]; then
    cp -a "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
    info "已备份 $f"
  fi
}

restart_netdata() {
  systemctl daemon-reload
  systemctl enable netdata >/dev/null 2>&1 || true
  systemctl restart netdata
  sleep 3
  systemctl is-active --quiet netdata || die "Netdata 启动失败，请执行：journalctl -u netdata -n 50"
  log "Netdata 已重启"
}

# ---- Tailscale ---------------------------------------------------------------
setup_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    info "正在安装 Tailscale..."
    local ts_tmp
    ts_tmp="$(mktemp)"
    curl -fsSL https://tailscale.com/install.sh -o "$ts_tmp"
    sh "$ts_tmp" </dev/null
    rm -f "$ts_tmp"
  else
    log "Tailscale 已安装"
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1 || true

  if tailscale ip -4 >/dev/null 2>&1; then
    log "Tailscale 已登录：$(tailscale ip -4 | head -n1)"
  else
    info "正在登录 Tailscale（如果出现链接，请在浏览器里打开并授权）..."
    if [ -n "$TS_AUTHKEY" ]; then
      tailscale up --accept-dns=false --authkey "$TS_AUTHKEY" </dev/null
    else
      tailscale up --accept-dns=false </dev/null
    fi
  fi
  warn "记得在 Tailscale 后台给这台机器点 “Disable key expiry”，否则 180 天后会断线"
}

ts_ip() { tailscale ip -4 2>/dev/null | head -n1; }

# 父节点要监听 Tailscale IP，必须等 tailscale0 网卡拿到 IP 后再启动 Netdata，
# 否则开机时 Netdata 先启动会绑定失败，子节点就连不上。
install_boot_order_fix() {
  mkdir -p /etc/systemd/system/netdata.service.d
  cat > /etc/systemd/system/netdata.service.d/10-wait-tailscale.conf <<'EOF'
# 由 netdata-manager.sh 生成：等待 Tailscale 拿到 IP 后再启动 Netdata
[Unit]
After=tailscaled.service network-online.target
Wants=tailscaled.service network-online.target

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 60); do ip -4 addr show tailscale0 2>/dev/null | grep -q "inet " && exit 0; sleep 1; done; exit 0'
EOF
  log "已设置开机顺序：Tailscale 就绪后再启动 Netdata"
}

# ---- 父节点 ------------------------------------------------------------------
cmd_parent() {
  load_state            # 先读已保存的配置，命令行参数可以覆盖它
  parse_opts "$@"
  install_netdata
  detect_paths

  if [ "$USE_TAILSCALE" -eq 1 ]; then
    setup_tailscale
    [ -n "$BIND_IP" ] || BIND_IP="$(ts_ip)"
    [ -n "$BIND_IP" ] || die "拿不到 Tailscale IP，请确认 tailscale 已登录（tailscale status）"
    install_boot_order_fix
  else
    [ -n "$BIND_IP" ] || die "不用 Tailscale 时必须指定 --bind-ip（父节点的内网 IP）"
    [ "$ALLOW_FROM" != "100.*" ] || warn "你没改 --allow，当前只允许 100.* 网段；内网一般要改成如 \"10.*\" 或 \"172.16.*\""
  fi

  # 沿用已有的 API Key，避免重新部署后所有子节点失联
  if [ -z "$API_KEY" ]; then
    API_KEY="$(cat /proc/sys/kernel/random/uuid)"
    log "已生成新的 API Key"
  else
    log "沿用已有的 API Key"
  fi

  backup "$NETDATA_ETC/netdata.conf"
  cat > "$NETDATA_ETC/netdata.conf" <<EOF
# 由 netdata-manager.sh 生成（角色：父节点）
[db]
    mode = dbengine
    dbengine tier 0 retention size = $RETENTION

[web]
    # 127.0.0.1 给 Cloudflare Tunnel 用，$BIND_IP 给子节点推送数据用
    bind to = 127.0.0.1 $BIND_IP
    allow connections from = localhost $ALLOW_FROM

[ml]
    enabled = $([ "$ML" = on ] && echo yes || echo no)
EOF

  backup "$NETDATA_ETC/stream.conf"
  cat > "$NETDATA_ETC/stream.conf" <<EOF
# 由 netdata-manager.sh 生成（角色：父节点）
[stream]
    enabled = no

[$API_KEY]
    enabled = yes
    allow from = $ALLOW_FROM
EOF
  chmod 640 "$NETDATA_ETC/stream.conf"
  chgrp netdata "$NETDATA_ETC/stream.conf" 2>/dev/null || true

  save_state parent
  restart_netdata
  install_self

  echo
  log "父节点部署完成！监听地址：127.0.0.1:19999（Tunnel） 和 $BIND_IP:19999（子节点）"
  if ss -tln 2>/dev/null | grep -q "0.0.0.0:19999"; then
    warn "检测到 19999 监听在 0.0.0.0，请检查配置，别暴露到公网"
  fi
  echo
  print_join_cmd
}

print_join_cmd() {
  load_state
  [ "${ROLE:-}" = parent ] || die "这台机器还不是父节点，请先部署父节点"
  echo "${c_cyan}在新服务器上执行这一条命令即可加入：${c_off}"
  echo
  echo "  curl -fsSL $SCRIPT_URL | sudo bash -s -- child --parent $BIND_IP --key $API_KEY"
  echo
  info "可在末尾加 --ts-authkey tskey-auth-xxx 免去手动登录 Tailscale"
  warn "API Key 相当于密码，不要公开发出去"
}

cmd_rotate_key() {
  load_state
  [ "${ROLE:-}" = parent ] || die "rotate-key 只能在父节点上运行"
  [ -n "${API_KEY:-}" ] || die "找不到当前的 API Key（$STATE_FILE）"
  detect_paths
  local conf="$NETDATA_ETC/stream.conf"
  grep -qF "[$API_KEY]" "$conf" || die "$conf 里找不到当前 Key 的配置段，请重新执行 parent 部署"

  warn "更换后，所有子节点会立即断开，需要在每台子节点上重新运行新的加入命令"
  local ans=""
  if [ "${1:-}" = "--yes" ]; then
    ans=y
  else
    read -r -p "确定要更换 API Key 吗？[y/N] " ans </dev/tty || true
  fi
  [ "$ans" = y ] || [ "$ans" = Y ] || { info "已取消"; exit 0; }

  local old_key="$API_KEY"
  API_KEY="$(cat /proc/sys/kernel/random/uuid)"
  backup "$conf"
  sed -i "s/^\[$old_key\]\$/[$API_KEY]/" "$conf"
  grep -qF "[$API_KEY]" "$conf" || die "写入新 Key 失败，原配置已备份"

  save_state parent
  restart_netdata
  log "API Key 已更换，旧 Key 已作废"
  echo
  print_join_cmd
}

# ---- 子节点 ------------------------------------------------------------------
cmd_child() {
  parse_opts "$@"
  [ -n "$PARENT_IP" ] || die "缺少 --parent（父节点 IP）。可在父节点执行 join-cmd 获取完整命令"
  [ -n "$API_KEY" ]   || die "缺少 --key（API Key）。可在父节点执行 join-cmd 获取完整命令"
  case "$PARENT_IP$API_KEY" in
    *x.x*|*'<'*|*'>'*|*你的*) die "--parent / --key 填的是示例占位符，请在父节点执行 sudo netdata-manager join-cmd 获取真实命令" ;;
  esac

  # 已经是子节点：不重复安装，只更新 Key 和父节点地址
  local prev_role=""
  [ -f "$STATE_FILE" ] && prev_role="$(. "$STATE_FILE"; echo "${ROLE:-}")"
  if [ "$FULL" -eq 0 ] && [ "$prev_role" = child ] && netdata_installed; then
    detect_paths
    if grep -q '^\[stream\]' "$NETDATA_ETC/stream.conf" 2>/dev/null; then
      cmd_child_update_key
      return
    fi
  fi

  install_netdata
  detect_paths
  [ "$USE_TAILSCALE" -eq 1 ] && setup_tailscale

  check_parent_reachable
  write_child_config
}

check_parent_reachable() {
  info "检查能否连上父节点 $PARENT_IP:19999 ..."
  if curl -fsS --max-time 8 "http://$PARENT_IP:19999/api/v1/info" >/dev/null 2>&1; then
    log "能连上父节点"
  else
    warn "暂时连不上父节点。常见原因：Tailscale 未登录 / 父节点没监听这个 IP / --allow 不包含本机 IP"
    warn "配置会照常写入，连通后会自动开始推送"
  fi
}

write_child_config() {
  backup "$NETDATA_ETC/netdata.conf"
  cat > "$NETDATA_ETC/netdata.conf" <<EOF
# 由 netdata-manager.sh 生成（角色：子节点）
[db]
    # 数据都存在父节点，本机只在内存里保留少量数据
    mode = ram
    update every = $INTERVAL

[web]
    # 不开面板、不监听任何端口
    mode = none

[health]
    # 告警由父节点统一计算
    enabled = no

[ml]
    enabled = $([ "$ML" = on ] && echo yes || echo no)
EOF

  backup "$NETDATA_ETC/stream.conf"
  cat > "$NETDATA_ETC/stream.conf" <<EOF
# 由 netdata-manager.sh 生成（角色：子节点）
[stream]
    enabled = yes
    destination = $PARENT_IP:19999
    api key = $API_KEY
EOF
  chmod 640 "$NETDATA_ETC/stream.conf"
  chgrp netdata "$NETDATA_ETC/stream.conf" 2>/dev/null || true

  save_state child
  restart_netdata
  install_self

  echo
  log "子节点部署完成！约 1 分钟内应该能在父节点面板的 Nodes 列表里看到 $(hostname)"
  info "如果没出现，执行：sudo $SELF logs"
}

# 子节点快速更新：只改 stream.conf 里的父节点地址和 API Key，其他一概不动
cmd_child_update_key() {
  log "检测到本机已经是子节点，跳过安装，只更新 API Key 和父节点地址"
  check_parent_reachable
  local conf="$NETDATA_ETC/stream.conf"
  backup "$conf"
  sed -i -E "s|^([[:space:]]*destination[[:space:]]*=).*|\1 $PARENT_IP:19999|; s|^([[:space:]]*api key[[:space:]]*=).*|\1 $API_KEY|" "$conf"
  grep -qF "$API_KEY" "$conf" || die "写入新 Key 失败（$conf 格式不符合预期），可加 --full 重新完整配置"
  save_state child
  restart_netdata
  install_self
  echo
  log "已更新！约 1 分钟内会重新连上父节点 $PARENT_IP"
  info "如果没连上，执行：sudo $SELF logs"
}

# ---- 运维命令 ----------------------------------------------------------------
cmd_status() {
  load_state
  echo "角色：${ROLE:-未通过本脚本配置}"
  echo -n "Netdata 服务："; systemctl is-active netdata 2>/dev/null || true
  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale IP：$(ts_ip || echo 未登录)"
  fi
  echo "监听端口："
  ss -tlnp 2>/dev/null | grep ':19999' | sed 's/^/  /' || echo "  （无，子节点不监听端口属于正常）"

  if [ "${ROLE:-}" = parent ]; then
    echo
    echo "已连接的节点（含本机）："
    local info_json
    info_json="$(curl -fsS --max-time 5 http://127.0.0.1:19999/api/v1/info 2>/dev/null || true)"
    if [ -n "$info_json" ]; then
      echo "$info_json" | tr -d '\n' | grep -o '"mirrored_hosts"[^]]*]' \
        | sed 's/"mirrored_hosts"[[:space:]]*:[[:space:]]*\[//; s/\]$//; s/"//g' \
        | tr ',' '\n' | sed 's/^[[:space:]]*/  - /'
    else
      warn "读取不到父节点 API"
    fi
  fi
}

cmd_logs() {
  journalctl -u netdata --since "30 min ago" --no-pager \
    | grep -iE 'stream|replication|connected|api key|denied' | tail -n 40 \
    || info "最近 30 分钟没有推送相关的日志"
}

cmd_uninstall() {
  local ans=""
  read -r -p "确定要卸载 Netdata 吗？所有监控数据都会删除 [y/N] " ans </dev/tty || true
  [ "$ans" = y ] || [ "$ans" = Y ] || { info "已取消"; exit 0; }
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o "$tmp/kickstart.sh"
  sh "$tmp/kickstart.sh" --uninstall --non-interactive
  rm -rf "$tmp" /etc/systemd/system/netdata.service.d/10-wait-tailscale.conf "$STATE_FILE" "$INSTALL_PATH" "$LEGACY_PATH"
  systemctl daemon-reload || true
  log "Netdata 已卸载（Tailscale 未动，如需卸载请用系统包管理器）"
}

# ---- 入口 --------------------------------------------------------------------
main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    parent)    need_root; cmd_parent "$@" ;;
    child)     need_root; cmd_child "$@" ;;
    join-cmd)  need_root; print_join_cmd ;;
    rotate-key) need_root; cmd_rotate_key "$@" ;;
    status)    need_root; cmd_status ;;
    restart)   need_root; restart_netdata ;;
    logs)      need_root; cmd_logs ;;
    update)    need_root; install_self ;;
    uninstall) need_root; cmd_uninstall ;;
    ""|-h|--help|help) usage ;;
    *) die "未知命令：$cmd（用 --help 查看用法）" ;;
  esac
}

main "$@"
