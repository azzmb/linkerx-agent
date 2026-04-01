#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${INSTALL_DIR:-/opt/LinkerX}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
WEB_PORT="${WEB_PORT:-6443}"
GRPC_PORT="${GRPC_PORT:-6080}"
INSTALL_MODE="${INSTALL_MODE:-}"
LINKERX_LIC_LICENSE_ID="${LINKERX_LIC_LICENSE_ID:-}"
LINKERX_LIC_ENROLL_TOKEN="${LINKERX_LIC_ENROLL_TOKEN:-}"

BACKEND_IMAGE="${BACKEND_IMAGE:-azzmb/linkerx-backend:latest}"
FRONTEND_IMAGE="${FRONTEND_IMAGE:-azzmb/linkerx-frontend:latest}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
用法:
  bash deploy/online/install_online.sh

环境变量:
  INSTALL_DIR=/opt/LinkerX
  PUBLIC_BASE_URL=https://<ip>:<port>
  WEB_PORT=6443
  GRPC_PORT=6080
  INSTALL_MODE=upgrade|reinstall
  BACKEND_IMAGE=${BACKEND_IMAGE}
  FRONTEND_IMAGE=${FRONTEND_IMAGE}
  LINKERX_LIC_LICENSE_ID=...         reinstall 时必填
  LINKERX_LIC_ENROLL_TOKEN=...       reinstall 时必填
EOF
  exit 0
fi

detect_host_ip() {
  local ip=""
  if command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    ip="$(hostname -I | awk '{print $1}')"
  fi
  if [[ -z "${ip}" ]] && command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [[ -z "${ip}" ]]; then
    ip="127.0.0.1"
  fi
  echo "${ip}"
}

host_from_url() {
  local u="$1"
  u="${u#http://}"
  u="${u#https://}"
  u="${u%%/*}"
  u="${u%%:*}"
  if [[ -z "${u}" ]]; then
    u="127.0.0.1"
  fi
  echo "${u}"
}

prompt_with_default() {
  local prompt="$1"
  local def="$2"
  local out=""
  if [[ -t 0 ]]; then
    read -r -p "${prompt} [${def}]: " out || true
  fi
  if [[ -z "${out}" ]]; then
    out="${def}"
  fi
  echo "${out}"
}

prompt_required() {
  local prompt="$1"
  local out=""
  if [[ ! -t 0 ]]; then
    echo "${prompt} 不能为空" >&2
    return 1
  fi
  while true; do
    read -r -p "${prompt}: " out || true
    out="$(echo "${out}" | tr -d '[:space:]')"
    if [[ -n "${out}" ]]; then
      echo "${out}"
      return 0
    fi
    echo "不能为空，请重新输入" >&2
  done
}

rand_b64() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
    return 0
  fi
  head -c 32 /dev/urandom | base64 | tr -d '\n'
}

update_agent_artifacts() {
  local file="$1"
  local artifacts="$2"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${file}" "${artifacts}" <<'PY'
import json
import sys

try:
    path = sys.argv[1]
    artifacts = json.loads(sys.argv[2])
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    data.setdefault("agent_update", {})
    data["agent_update"].setdefault("release", {})
    data["agent_update"]["release"]["artifacts"] = artifacts
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
except Exception as e:
    sys.stderr.write(f"failed updating agent artifacts: {e}\n")
    sys.exit(1)
PY
    return $?
  fi
  if command -v jq >/dev/null 2>&1; then
    jq --argjson artifacts "${artifacts}" '.agent_update.release.artifacts=$artifacts' "${file}" > "${file}.tmp" && mv "${file}.tmp" "${file}"
    return 0
  fi
  echo "python3 or jq not found; skip updating agent artifacts" >&2
  return 1
}

normalize_install_mode() {
  local v="$1"
  v="$(echo "${v}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  case "${v}" in
    1|upgrade|u) echo "upgrade" ;;
    2|reinstall|reset|r) echo "reinstall" ;;
    *) echo "" ;;
  esac
}

existing_install_mode_default() {
  if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    echo "upgrade"
    return
  fi
  echo "reinstall"
}

if [[ ! -w "$(dirname "$INSTALL_DIR")" && ! -d "$INSTALL_DIR" ]]; then
  INSTALL_DIR="${HOME}/LinkerX"
fi

mkdir -p "${INSTALL_DIR}/config" "${INSTALL_DIR}/config/nginx/certs" "${INSTALL_DIR}/data" "${INSTALL_DIR}/data/downloads/agent" "${INSTALL_DIR}/data/certs/monitor-grpc"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker not found"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose not found"
  exit 1
fi

download_agent() {
  local url="$1"
  local out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "${out}" "${url}"
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "${out}" "${url}"
    return 0
  fi
  echo "curl or wget not found"
  return 1
}

download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/linkerx-agent-linux-amd64" "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64"
chmod +x "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" || true
download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/linkerx-agent-linux-arm64" "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64"
chmod +x "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" || true
download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/install_linkerx_agent.sh" "${INSTALL_DIR}/data/downloads/agent/install_linkerx_agent.sh"
chmod +x "${INSTALL_DIR}/data/downloads/agent/install_linkerx_agent.sh" || true

MODE="$(normalize_install_mode "${INSTALL_MODE}")"
if [[ -z "${MODE}" ]]; then
  DEFAULT_MODE="$(existing_install_mode_default)"
  if [[ -t 0 ]]; then
    echo "安装模式:"
    echo "  1) 仅升级（更新容器，保留配置）"
    echo "  2) 安装（重置配置或安装）"
    CHOICE="$(prompt_with_default '选择 (1/2 或 upgrade/reinstall)' "${DEFAULT_MODE}")"
    MODE="$(normalize_install_mode "${CHOICE}")"
  fi
  if [[ -z "${MODE}" ]]; then
    MODE="${DEFAULT_MODE}"
  fi
fi

ARTIFACTS_JSON="[]"

docker pull "${BACKEND_IMAGE}" >/dev/null
docker pull "${FRONTEND_IMAGE}" >/dev/null

if [[ "${MODE}" == "upgrade" ]]; then
  if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
    echo "existing install not found: ${INSTALL_DIR}/docker-compose.yml"
    exit 1
  fi
  download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/linkerx-agent-linux-amd64" "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64"
  chmod +x "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" || true
  download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/linkerx-agent-linux-arm64" "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64"
  chmod +x "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" || true
  download_agent "https://raw.githubusercontent.com/azzmb/linkerx-agent/main/install_linkerx_agent.sh" "${INSTALL_DIR}/data/downloads/agent/install_linkerx_agent.sh"
  chmod +x "${INSTALL_DIR}/data/downloads/agent/install_linkerx_agent.sh" || true
  if [[ -f "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      AGENT_AMD64_SHA="$(sha256sum "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" | awk '{print $1}')"
    else
      AGENT_AMD64_SHA="$(shasum -a 256 "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" | awk '{print $1}')"
    fi
    ARTIFACTS_JSON="[{\"os\":\"linux\",\"arch\":\"amd64\",\"path\":\"/downloads/agent/linkerx-agent-linux-amd64\",\"sha256\":\"${AGENT_AMD64_SHA}\"}"
  fi
  if [[ -f "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      AGENT_ARM64_SHA="$(sha256sum "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" | awk '{print $1}')"
    else
      AGENT_ARM64_SHA="$(shasum -a 256 "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" | awk '{print $1}')"
    fi
    if [[ "${ARTIFACTS_JSON}" != "["* ]]; then
      ARTIFACTS_JSON="["
    fi
    if [[ "${ARTIFACTS_JSON}" != "[" ]]; then
      ARTIFACTS_JSON="${ARTIFACTS_JSON},"
    fi
    ARTIFACTS_JSON="${ARTIFACTS_JSON}{\"os\":\"linux\",\"arch\":\"arm64\",\"path\":\"/downloads/agent/linkerx-agent-linux-arm64\",\"sha256\":\"${AGENT_ARM64_SHA}\"}"
  fi
  if [[ "${ARTIFACTS_JSON}" == "["* ]]; then
    ARTIFACTS_JSON="${ARTIFACTS_JSON}]"
  else
    ARTIFACTS_JSON="[]"
  fi
  update_agent_artifacts "${INSTALL_DIR}/config/linkerx_conf.json" "${ARTIFACTS_JSON}" || true
  cd "${INSTALL_DIR}"
  docker compose up -d --force-recreate
  echo "ok"
  exit 0
fi

if [[ -z "${PUBLIC_BASE_URL}" ]]; then
  HOST_IP="$(detect_host_ip)"
  PUBLIC_BASE_URL="$(prompt_with_default 'PUBLIC_BASE_URL (用于前端访问/agent 下载链接)' "https://${HOST_IP}:${WEB_PORT}")"
fi

if [[ -z "${LINKERX_LIC_LICENSE_ID}" ]]; then
  LINKERX_LIC_LICENSE_ID="$(prompt_required 'License ID（必填）')" || exit 1
fi
if [[ -z "${LINKERX_LIC_ENROLL_TOKEN}" ]]; then
  LINKERX_LIC_ENROLL_TOKEN="$(prompt_required 'Enroll Token（必填）')" || exit 1
fi

DOWNLOAD_SECRET="${DOWNLOAD_SECRET:-$(rand_b64)}"
PASSWORD_PEPPER="${PASSWORD_PEPPER:-$(rand_b64)}"

AGENT_AMD64_PATH=""
AGENT_ARM64_PATH=""
AGENT_AMD64_SHA=""
AGENT_ARM64_SHA=""
if [[ -f "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" ]]; then
  AGENT_AMD64_PATH="/downloads/agent/linkerx-agent-linux-amd64"
  if command -v sha256sum >/dev/null 2>&1; then
    AGENT_AMD64_SHA="$(sha256sum "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" | awk '{print $1}')"
  else
    AGENT_AMD64_SHA="$(shasum -a 256 "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-amd64" | awk '{print $1}')"
  fi
fi
if [[ -f "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" ]]; then
  AGENT_ARM64_PATH="/downloads/agent/linkerx-agent-linux-arm64"
  if command -v sha256sum >/dev/null 2>&1; then
    AGENT_ARM64_SHA="$(sha256sum "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" | awk '{print $1}')"
  else
    AGENT_ARM64_SHA="$(shasum -a 256 "${INSTALL_DIR}/data/downloads/agent/linkerx-agent-linux-arm64" | awk '{print $1}')"
  fi
fi

ARTIFACTS_JSON="[]"
if [[ -n "${AGENT_AMD64_PATH}" || -n "${AGENT_ARM64_PATH}" ]]; then
  ARTIFACTS_JSON="["
  if [[ -n "${AGENT_AMD64_PATH}" ]]; then
    ARTIFACTS_JSON="${ARTIFACTS_JSON}{\"os\":\"linux\",\"arch\":\"amd64\",\"path\":\"${AGENT_AMD64_PATH}\",\"sha256\":\"${AGENT_AMD64_SHA}\"}"
  fi
  if [[ -n "${AGENT_ARM64_PATH}" ]]; then
    if [[ "${ARTIFACTS_JSON}" != "[" ]]; then
      ARTIFACTS_JSON="${ARTIFACTS_JSON},"
    fi
    ARTIFACTS_JSON="${ARTIFACTS_JSON}{\"os\":\"linux\",\"arch\":\"arm64\",\"path\":\"${AGENT_ARM64_PATH}\",\"sha256\":\"${AGENT_ARM64_SHA}\"}"
  fi
  ARTIFACTS_JSON="${ARTIFACTS_JSON}]"
fi

if command -v openssl >/dev/null 2>&1; then
  CERT_DIR="${INSTALL_DIR}/data/certs/monitor-grpc"
  CA_KEY="${CERT_DIR}/ca.key"
  CA_CRT="${CERT_DIR}/ca.crt"
  SVR_KEY="${CERT_DIR}/server.key"
  SVR_CRT="${CERT_DIR}/server.crt"

  HOST_FOR_CERT="$(host_from_url "${PUBLIC_BASE_URL}")"
  MONITOR_GRPC_CERT_DNS_DEFAULT="localhost"
  MONITOR_GRPC_CERT_IPS_DEFAULT="127.0.0.1"
  if [[ "${HOST_FOR_CERT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    MONITOR_GRPC_CERT_IPS_DEFAULT="${HOST_FOR_CERT},127.0.0.1"
  else
    if [[ -n "${HOST_FOR_CERT}" && "${HOST_FOR_CERT}" != "localhost" ]]; then
      MONITOR_GRPC_CERT_DNS_DEFAULT="localhost,${HOST_FOR_CERT}"
    fi
  fi
  MONITOR_GRPC_CERT_DNS="$(prompt_with_default 'gRPC 证书 SAN DNS（逗号分隔）' "${MONITOR_GRPC_CERT_DNS_DEFAULT}")"
  MONITOR_GRPC_CERT_IPS="$(prompt_with_default 'gRPC 证书 SAN IP（逗号分隔）' "${MONITOR_GRPC_CERT_IPS_DEFAULT}")"

  if [[ ! -f "${CA_KEY}" || ! -f "${CA_CRT}" || ! -f "${SVR_KEY}" || ! -f "${SVR_CRT}" ]]; then
    openssl genrsa -out "${CA_KEY}" 2048 >/dev/null 2>&1
    openssl req -x509 -new -nodes -key "${CA_KEY}" -sha256 -days 3650 -subj "/CN=LinkerX Monitor CA" -out "${CA_CRT}" >/dev/null 2>&1
    openssl genrsa -out "${SVR_KEY}" 2048 >/dev/null 2>&1
    TMP_CNF="$(mktemp)"
    CN="linkerx-monitor"
    if [[ -n "${MONITOR_GRPC_CERT_DNS}" ]]; then
      CN="${MONITOR_GRPC_CERT_DNS%%,*}"
    elif [[ -n "${MONITOR_GRPC_CERT_IPS}" ]]; then
      CN="${MONITOR_GRPC_CERT_IPS%%,*}"
    fi
    CN="${CN// /}"
    if [[ -z "${CN}" ]]; then
      CN="linkerx-monitor"
    fi
    cat > "${TMP_CNF}" <<EOF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no
[req_distinguished_name]
CN=${CN}
[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
EOF
    dns_i=0
    IFS=',' read -ra dns_arr <<< "${MONITOR_GRPC_CERT_DNS}"
    for d in "${dns_arr[@]}"; do
      dd="${d// /}"
      if [[ -z "${dd}" ]]; then
        continue
      fi
      dns_i=$((dns_i+1))
      echo "DNS.${dns_i} = ${dd}" >> "${TMP_CNF}"
    done
    ip_i=0
    IFS=',' read -ra ip_arr <<< "${MONITOR_GRPC_CERT_IPS}"
    for p in "${ip_arr[@]}"; do
      pp="${p// /}"
      if [[ -z "${pp}" ]]; then
        continue
      fi
      ip_i=$((ip_i+1))
      echo "IP.${ip_i} = ${pp}" >> "${TMP_CNF}"
    done
    openssl req -new -key "${SVR_KEY}" -out "${CERT_DIR}/server.csr" -config "${TMP_CNF}" >/dev/null 2>&1
    openssl x509 -req -in "${CERT_DIR}/server.csr" -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial -out "${SVR_CRT}" -days 3650 -sha256 -extensions v3_req -extfile "${TMP_CNF}" >/dev/null 2>&1
    rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/ca.srl" "${TMP_CNF}"
  fi
fi

NGINX_CERT_DIR="${INSTALL_DIR}/config/nginx/certs"
NGINX_TLS_CRT="${NGINX_CERT_DIR}/tls.crt"
NGINX_TLS_KEY="${NGINX_CERT_DIR}/tls.key"
mkdir -p "${NGINX_CERT_DIR}"

HOST_IP="$(host_from_url "${PUBLIC_BASE_URL}")"
DEFAULT_DNS="localhost"
DEFAULT_IPS="${HOST_IP},127.0.0.1"
NGINX_TLS_DNS="$(prompt_with_default 'Nginx TLS 证书 SAN DNS（逗号分隔）' "${DEFAULT_DNS}")"
NGINX_TLS_IPS="$(prompt_with_default 'Nginx TLS 证书 SAN IP（逗号分隔）' "${DEFAULT_IPS}")"

if [[ ! -f "${NGINX_TLS_CRT}" || ! -f "${NGINX_TLS_KEY}" ]]; then
  if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl not found; please provide ${NGINX_TLS_CRT} and ${NGINX_TLS_KEY}"
    exit 1
  fi
  CN="${DEFAULT_DNS}"
  if [[ -n "${NGINX_TLS_DNS}" ]]; then
    CN="${NGINX_TLS_DNS%%,*}"
  elif [[ -n "${NGINX_TLS_IPS}" ]]; then
    CN="${NGINX_TLS_IPS%%,*}"
  fi
  CN="${CN// /}"
  if [[ -z "${CN}" ]]; then
    CN="linkerx"
  fi

  TMP_CNF="$(mktemp)"
  cat > "${TMP_CNF}" <<EOF
[req]
distinguished_name=req_distinguished_name
req_extensions=v3_req
prompt=no
[req_distinguished_name]
CN=${CN}
[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
EOF
  dns_i=0
  IFS=',' read -ra dns_arr <<< "${NGINX_TLS_DNS}"
  for d in "${dns_arr[@]}"; do
    dd="${d// /}"
    if [[ -z "${dd}" ]]; then
      continue
    fi
    dns_i=$((dns_i+1))
    echo "DNS.${dns_i} = ${dd}" >> "${TMP_CNF}"
  done
  ip_i=0
  IFS=',' read -ra ip_arr <<< "${NGINX_TLS_IPS}"
  for p in "${ip_arr[@]}"; do
    pp="${p// /}"
    if [[ -z "${pp}" ]]; then
      continue
    fi
    ip_i=$((ip_i+1))
    echo "IP.${ip_i} = ${pp}" >> "${TMP_CNF}"
  done
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout "${NGINX_TLS_KEY}" -out "${NGINX_TLS_CRT}" -config "${TMP_CNF}" -extensions v3_req >/dev/null 2>&1
  rm -f "${TMP_CNF}"
fi

cat > "${INSTALL_DIR}/config/linkerx_conf.json" <<EOF
{
  "http_addr": ":8000",
  "monitor_grpc": {
    "addr": ":${GRPC_PORT}",
    "tls_cert_file": "/data/certs/monitor-grpc/server.crt",
    "tls_key_file": "/data/certs/monitor-grpc/server.key",
    "tls_ca_file": "/data/certs/monitor-grpc/ca.crt",
    "cert_out_dir": "/data/certs/monitor-grpc",
    "cert_ips": "${MONITOR_GRPC_CERT_IPS:-}",
    "cert_dns": "${MONITOR_GRPC_CERT_DNS:-}",
    "ca_compat_minutes": 1440,
    "ca_version": 0,
    "ca_rotation_pending_until_unix_millis": 0
  },
  "retention": {
    "raw_retention_days": 7,
    "rollup_retention_days": 30,
    "rollup_bucket": "1m",
    "loop_interval": "10m",
    "vacuum_interval": "24h"
  },
  "agent_update": {
    "base_url": "${PUBLIC_BASE_URL}",
    "expires_seconds": 300,
    "download_path_prefix": "/downloads/agent",
    "download_secret": "${DOWNLOAD_SECRET}",
    "release": {
      "artifacts": ${ARTIFACTS_JSON}
    }
  },
  "licensing": {
    "license_id": "${LINKERX_LIC_LICENSE_ID}",
    "enroll_token": "${LINKERX_LIC_ENROLL_TOKEN}"
  },
  "auth": {
    "password_pepper": "${PASSWORD_PEPPER}"
  }
}
EOF
chmod 600 "${INSTALL_DIR}/config/linkerx_conf.json" || true

cat > "${INSTALL_DIR}/config/nginx.conf" <<EOF
events {}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  charset utf-8;
  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
  }

  server {
    listen 443 ssl;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    absolute_redirect off;

    ssl_certificate /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;

    location /_next/ {
      try_files \$uri =404;
    }

    location /api/ {
      proxy_pass http://backend:8000;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /downloads/agent/ {
      secure_link \$arg_md5,\$arg_exp;
      secure_link_md5 "\$secure_link_expires\${uri}${DOWNLOAD_SECRET}";
      if (\$secure_link = "") { return 403; }
      if (\$secure_link = "0") { return 410; }
      alias /srv/downloads/agent/;
      add_header Content-Disposition "attachment";
    }

    location = / {
      return 302 /dashboard/user;
    }

    location ^~ /server/monitor/ {
      try_files /server/monitor/[id].html =404;
    }

    location ^~ /user/group/ {
      try_files /user/group/[id].html =404;
    }

    location / {
      try_files \$uri \$uri.html \$uri/ /index.html;
    }
  }
}
EOF

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
name: linkerx

services:
  backend:
    image: ${BACKEND_IMAGE}
    working_dir: /data
    command: ["-c", "/etc/linkerx/linkerx_conf.json"]
    volumes:
      - ./data:/data
      - ./config/linkerx_conf.json:/etc/linkerx/linkerx_conf.json
    ports:
      - "${GRPC_PORT}:${GRPC_PORT}"
    restart: unless-stopped

  frontend:
    image: ${FRONTEND_IMAGE}
    depends_on:
      - backend
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./config/nginx/certs:/etc/nginx/certs:ro
      - ./data/downloads/agent:/srv/downloads/agent:ro
    ports:
      - "${WEB_PORT}:443"
    command: ["nginx","-g","daemon off;"]
    restart: unless-stopped
EOF

cd "${INSTALL_DIR}"
docker compose up -d

echo "ok"
echo "ui: ${PUBLIC_BASE_URL}"
echo "grpc: $(host_from_url "${PUBLIC_BASE_URL}"):${GRPC_PORT}"
