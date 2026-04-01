#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  sudo ./install_linkerx_agent.sh --server_ip <ip> --port <port> --token <token> [--ca_b64 <base64>] [--agent_url <url>]
  sudo ./install_linkerx_agent.sh --server_ip <ip> --port <port> --token <token> [--ca_b64 <base64>] [--agent_url_amd64 <url>] [--agent_url_arm64 <url>]

说明:
  - 会把 agent 安装到 /etc/linkerx/linkerx-agent（优先使用同目录二进制；否则用 --agent_url 下载）
  - 可通过 --ca_b64 传入 CA 证书（base64 编码后的 PEM 内容），并写入 /etc/linkerx/ca.pem
  - 会生成 /etc/linkerx/linkerx_conf.json
  - 会写入并启动 /etc/systemd/system/linkerx-agent.service
  - 脚本执行完成后会自删除
EOF
}

server_ip=""
port=""
token=""
ca_b64=""
agent_url=""
agent_url_amd64=""
agent_url_arm64=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --server_ip|--server-ip)
      server_ip="${2:-}"; shift 2
      ;;
    --port)
      port="${2:-}"; shift 2
      ;;
    --token)
      token="${2:-}"; shift 2
      ;;
    --ca_b64|--ca-b64)
      ca_b64="${2:-}"; shift 2
      ;;
    --agent_url|--agent-url)
      agent_url="${2:-}"; shift 2
      ;;
    --agent_url_amd64|--agent-url-amd64)
      agent_url_amd64="${2:-}"; shift 2
      ;;
    --agent_url_arm64|--agent-url-arm64)
      agent_url_arm64="${2:-}"; shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${server_ip}" || -z "${port}" || -z "${token}" ]]; then
  usage
  exit 2
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "该脚本仅支持在 Linux 上安装（依赖 systemd）。" >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 权限运行，例如: sudo ./install_linkerx_agent.sh ..." >&2
  exit 1
fi

arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64) dist_bin="linkerx-agent-linux-amd64" ;;
  aarch64|arm64) dist_bin="linkerx-agent-linux-arm64" ;;
  *)
    echo "不支持的 CPU 架构: ${arch}" >&2
    exit 1
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
src_bin="${script_dir}/${dist_bin}"

if [[ ! -f "${src_bin}" && -z "${agent_url}" && -z "${agent_url_amd64}" && -z "${agent_url_arm64}" ]]; then
  echo "未找到二进制文件: ${src_bin}，请提供 --agent_url 或对应架构的下载 URL。" >&2
  exit 1
fi

install_dir="/etc/linkerx"
mkdir -p "${install_dir}"

installed_bin="${install_dir}/linkerx-agent"
if [[ -f "${src_bin}" ]]; then
  cp -f "${src_bin}" "${installed_bin}"
else
  if [[ -z "${agent_url}" ]]; then
    if [[ "${dist_bin}" == "linkerx-agent-linux-amd64" ]]; then
      agent_url="${agent_url_amd64}"
    else
      agent_url="${agent_url_arm64}"
    fi
  fi
  if [[ -z "${agent_url}" ]]; then
    echo "未找到本地二进制 ${src_bin}，且未提供 --agent_url/--agent_url_amd64/--agent_url_arm64" >&2
    exit 1
  fi
  if command -v curl >/dev/null 2>&1; then
    tmp_bin="$(mktemp "${install_dir}/linkerx-agent.tmp.XXXXXX")"
    if ! curl -fsSLk "${agent_url}" -o "${tmp_bin}"; then
      rm -f -- "${tmp_bin}" 2>/dev/null || true
      echo "下载 agent 失败: ${agent_url}" >&2
      exit 1
    fi
    mv -f "${tmp_bin}" "${installed_bin}"
  elif command -v wget >/dev/null 2>&1; then
    tmp_bin="$(mktemp "${install_dir}/linkerx-agent.tmp.XXXXXX")"
    if ! wget -qO "${tmp_bin}" "${agent_url}"; then
      rm -f -- "${tmp_bin}" 2>/dev/null || true
      echo "下载 agent 失败: ${agent_url}" >&2
      exit 1
    fi
    mv -f "${tmp_bin}" "${installed_bin}"
  else
    echo "缺少 curl/wget，无法自动下载 agent。" >&2
    exit 1
  fi
fi
chmod 0755 "${installed_bin}"

ca_path="${install_dir}/ca.pem"
if [[ -n "${ca_b64}" ]]; then
  if ! command -v base64 >/dev/null 2>&1; then
    echo "缺少 base64 命令，请先安装 coreutils/gnu-base64。" >&2
    exit 1
  fi
  tmp_ca="$(mktemp "${install_dir}/ca.pem.tmp.XXXXXX")"
  if ! printf '%s' "${ca_b64}" | base64 -d > "${tmp_ca}" 2>/dev/null; then
    rm -f -- "${tmp_ca}" 2>/dev/null || true
    echo "CA base64 解码失败，请确认传入的是 base64(PEM) 且参数已正确加引号。" >&2
    exit 1
  fi
  if ! grep -q "BEGIN CERTIFICATE" "${tmp_ca}"; then
    rm -f -- "${tmp_ca}" 2>/dev/null || true
    echo "CA 内容看起来不是证书 PEM（缺少 BEGIN CERTIFICATE）。" >&2
    exit 1
  fi
  mv -f "${tmp_ca}" "${ca_path}"
  chmod 0644 "${ca_path}"
fi

insecure="false"
if [[ ! -s "${ca_path}" ]]; then
  insecure="true"
fi

cat > "${install_dir}/linkerx_conf.json" <<EOF
{
  "server_ip": "${server_ip}",
  "server_port": ${port},
  "token": "${token}",
  "interval": "10s",
  "tls_ca": "${ca_path}",
  "insecure": ${insecure}
}
EOF

cat > /etc/systemd/system/linkerx-agent.service <<'EOF'
[Unit]
Description=linkerx-agent Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/etc/linkerx
ExecStart=/etc/linkerx/linkerx-agent -c /etc/linkerx/linkerx_conf.json

Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now linkerx-agent
systemctl --no-pager -l status linkerx-agent || true

rm -f -- "${script_path}" 2>/dev/null || true
echo "安装完成：/etc/linkerx/linkerx-agent （systemd 服务: linkerx-agent）"
