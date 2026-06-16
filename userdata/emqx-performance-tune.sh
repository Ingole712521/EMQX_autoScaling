# EMQX Linux performance tuning (https://docs.emqx.com/en/emqx/latest/performance/tune.html)
# Sourced/injected by bootstrap user-data. Expects: log(), fail() from caller.
# Optional env overrides (defaults match EMQX docs): EMQX_TUNE_NOFILE, EMQX_TUNE_MAX_PORTS,
# EMQX_TUNE_ACCEPTORS, EMQX_TUNE_MAX_CONNECTIONS, EMQX_TUNE_DIST_BUFFER_SIZE_KB

apply_emqx_performance_tuning() {
  local node_role="${1:-replicant}"
  log "PERF: Applying OS + EMQX performance tuning (role=$node_role)"
  _emqx_tune_disable_swap
  _emqx_tune_kernel_and_network
  _emqx_tune_persist_sysctl
  _emqx_tune_limits_conf
  _emqx_tune_systemd_global_limits
  _emqx_tune_emqx_service_limits
  _emqx_tune_validate_os "$node_role"
}

_emqx_tune_nofile() {
  echo "${EMQX_TUNE_NOFILE:-2097152}"
}

_emqx_tune_max_ports() {
  echo "${EMQX_TUNE_MAX_PORTS:-2097152}"
}

_emqx_tune_acceptors() {
  echo "${EMQX_TUNE_ACCEPTORS:-64}"
}

_emqx_tune_max_connections() {
  echo "${EMQX_TUNE_MAX_CONNECTIONS:-1024000}"
}

_emqx_tune_dist_buffer_kb() {
  echo "${EMQX_TUNE_DIST_BUFFER_SIZE_KB:-2097151}"
}

_emqx_tune_disable_swap() {
  log "PERF: Disabling swap (recommended for Erlang/EMQX stability)"
  swapoff -a 2>/dev/null || true
  if [[ -f /etc/fstab ]]; then
    sed -i.bak-emqx -E 's/^([^#].*[[:space:]]swap[[:space:]])/#\1/' /etc/fstab || true
  fi
}

_emqx_tune_kernel_and_network() {
  local nofile
  nofile="$(_emqx_tune_nofile)"
  log "PERF: Applying runtime sysctl (file-max=$nofile, TCP backlog/buffers)"

  sysctl -w "fs.file-max=$nofile" 2>/dev/null || true
  sysctl -w "fs.nr_open=$nofile" 2>/dev/null || true
  echo "$nofile" > /proc/sys/fs/nr_open 2>/dev/null || true

  sysctl -w net.core.somaxconn=32768 2>/dev/null || true
  sysctl -w net.ipv4.tcp_max_syn_backlog=16384 2>/dev/null || true
  sysctl -w net.core.netdev_max_backlog=16384 2>/dev/null || true
  sysctl -w net.ipv4.ip_local_port_range="1024 65535" 2>/dev/null || true

  sysctl -w net.core.rmem_default=262144 2>/dev/null || true
  sysctl -w net.core.wmem_default=262144 2>/dev/null || true
  sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
  sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
  sysctl -w net.core.optmem_max=16777216 2>/dev/null || true
  sysctl -w net.ipv4.tcp_rmem="1024 4096 16777216" 2>/dev/null || true
  sysctl -w net.ipv4.tcp_wmem="1024 4096 16777216" 2>/dev/null || true

  sysctl -w net.ipv4.tcp_max_tw_buckets=1048576 2>/dev/null || true
  sysctl -w net.ipv4.tcp_fin_timeout=15 2>/dev/null || true

  if sysctl net.nf_conntrack_max >/dev/null 2>&1; then
    sysctl -w net.nf_conntrack_max=1000000 2>/dev/null || true
  fi
  if sysctl net.netfilter.nf_conntrack_max >/dev/null 2>&1; then
    sysctl -w net.netfilter.nf_conntrack_max=1000000 2>/dev/null || true
    sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30 2>/dev/null || true
  fi

  ulimit -n "$nofile" 2>/dev/null || true
}

_emqx_tune_persist_sysctl() {
  local nofile
  nofile="$(_emqx_tune_nofile)"
  log "PERF: Persisting sysctl to /etc/sysctl.d/99-emqx-performance.conf"

  cat > /etc/sysctl.d/99-emqx-performance.conf <<EOF
# EMQX performance tuning — https://docs.emqx.com/en/emqx/latest/performance/tune.html
fs.file-max = $nofile
fs.nr_open = $nofile

net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 16384
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 1024 65535

net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.optmem_max = 16777216
net.ipv4.tcp_rmem = 1024 4096 16777216
net.ipv4.tcp_wmem = 1024 4096 16777216

net.ipv4.tcp_max_tw_buckets = 1048576
net.ipv4.tcp_fin_timeout = 15

net.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
EOF

  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-emqx-performance.conf 2>/dev/null || true
}

_emqx_tune_limits_conf() {
  local nofile
  nofile="$(_emqx_tune_nofile)"
  log "PERF: Setting process/file limits in /etc/security/limits.d/99-emqx.conf"

  cat > /etc/security/limits.d/99-emqx.conf <<EOF
# EMQX performance tuning
* soft nofile $nofile
* hard nofile $nofile
* soft nproc  2097152
* hard nproc  2097152
emqx soft nofile $nofile
emqx hard nofile $nofile
emqx soft nproc  2097152
emqx hard nproc  2097152
root soft nofile $nofile
root hard nofile $nofile
EOF
}

_emqx_tune_systemd_global_limits() {
  local nofile
  nofile="$(_emqx_tune_nofile)"
  log "PERF: Setting systemd DefaultLimitNOFILE=$nofile"

  install -d /etc/systemd/system.conf.d
  cat > /etc/systemd/system.conf.d/99-emqx-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=$nofile
DefaultLimitNPROC=2097152
EOF
  systemctl daemon-reexec 2>/dev/null || systemctl daemon-reload 2>/dev/null || true
}

_emqx_tune_emqx_service_limits() {
  local nofile dropin
  nofile="$(_emqx_tune_nofile)"
  dropin="/etc/systemd/system/emqx.service.d"
  log "PERF: Setting emqx.service LimitNOFILE=$nofile"

  install -d "$dropin"
  cat > "$dropin/performance.conf" <<EOF
[Service]
LimitNOFILE=$nofile
LimitNPROC=2097152
EOF
}

append_emqx_performance_env() {
  local node_role="${1:-replicant}"
  local acceptors max_conn max_ports dist_buf

  acceptors="$(_emqx_tune_acceptors)"
  max_conn="$(_emqx_tune_max_connections)"
  max_ports="$(_emqx_tune_max_ports)"

  cat <<EOF
EMQX_NODE__MAX_PORTS=$max_ports
EMQX_LISTENERS__TCP__DEFAULT__ACCEPTORS=$acceptors
EMQX_LISTENERS__TCP__DEFAULT__MAX_CONNECTIONS=$max_conn
EMQX_MQTT__MAX_INFLIGHT=128
EMQX_MQTT__MAX_AWAITING_REL=1000
EOF

  if [[ "$node_role" == "core" ]]; then
    dist_buf="$(_emqx_tune_dist_buffer_kb)"
    echo "EMQX_NODE__DIST_BUFFER_SIZE=$dist_buf"
  fi
}

_emqx_tune_validate_os() {
  local node_role="${1:-replicant}"
  local nofile file_max somaxconn

  nofile="$(_emqx_tune_nofile)"
  file_max="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
  somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)"

  log "PERF: Validation — fs.file-max=$file_max (want $nofile), somaxconn=$somaxconn, swap=$(swapon --show 2>/dev/null | wc -l) active"

  if [[ "$file_max" -lt "$nofile" ]]; then
    log "PERF: WARN fs.file-max ($file_max) below target ($nofile)"
  fi

  if swapon --show 2>/dev/null | grep -q .; then
    log "PERF: WARN swap is still active"
  else
    log "PERF: swap disabled OK"
  fi

  if [[ -f /etc/systemd/system/emqx.service.d/performance.conf ]] \
     && grep -q "LimitNOFILE=$nofile" /etc/systemd/system/emqx.service.d/performance.conf; then
    log "PERF: emqx.service LimitNOFILE OK"
  else
    log "PERF: WARN emqx.service performance drop-in missing or mismatched"
  fi

  log "PERF: EMQX listener tuning — acceptors=$(_emqx_tune_acceptors), max_connections=$(_emqx_tune_max_connections), max_ports=$(_emqx_tune_max_ports)"
  if [[ "$node_role" == "core" ]]; then
    log "PERF: Core dist_buffer_size=$(_emqx_tune_dist_buffer_kb) KB"
  fi
}
