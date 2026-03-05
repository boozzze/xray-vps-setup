#/bin/bash

set -e

export GIT_BRANCH="main"
export GIT_REPO="boozzze/xray-vps-setup"

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

apt-get update
apt-get install -y sudo jq

# Auto-generate domain: <ip>.cdn-one.org
SERVER_IP=$(hostname -I | awk '{print $1}')
export VLESS_DOMAIN="${SERVER_IP}.cdn-one.org"
echo "Using domain: $VLESS_DOMAIN"

# Enable BBR if not enabled
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "BBR is already used"
else
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null
  echo "Enabled BBR"
fi

export ARCH=$(dpkg --print-architecture)

yq_install() {
  wget "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" -O /usr/bin/yq
  chmod +x /usr/bin/yq
}

yq_install

docker_install() {
  curl -fsSL https://get.docker.com | sh
}

if ! command -v docker >/dev/null 2>&1; then
  docker_install
fi

# Generate values for XRay
export IP_CADDY=$SERVER_IP
export CADDY_BASIC_AUTH=""

export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i "$XRAY_PIK" | tail -2 | head -1 | cut -d' ' -f 2)
export XRAY_SID=$(openssl rand -hex 8)
export XRAY_UUID=$(docker run --rm ghcr.io/xtls/xray-core uuid)

xray_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup

  # docker-compose.yml (xray + caddy)
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose" | envsubst > ./docker-compose.yml

  # create directories before writing files
  mkdir -p xray caddy/templates

  # base xray config (tcp-reality on 443)
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray" | envsubst > ./xray/config.json

  # xhttp inbound template -> append into config
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray_xhttp_inbound" | envsubst > ./xray/xhttp_inbound.json
  jq '.inbounds += [ input ]' ./xray/config.json ./xray/xhttp_inbound.json > ./xray/config_tmp.json
  mv ./xray/config_tmp.json ./xray/config.json
  rm ./xray/xhttp_inbound.json

  # Simple HTML page for Caddy instead of confluence_page
  echo '<!DOCTYPE html><html><head><title>Xray VPS</title></head><body><h1>Xray VPS is running</h1><p>TCP-REALITY:443 | XHTTP-REALITY:2087</p></body></html>' > ./caddy/templates/index.html

  export CADDY_REVERSE="root * /srv
file_server"
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/caddy" | envsubst > ./caddy/Caddyfile
}

xray_setup()

end_script() {
  cd /opt/xray-vps-setup

  docker run -v /opt/xray-vps-setup/caddy/Caddyfile:/opt/xray-vps-setup/Caddyfile --rm caddy caddy fmt --overwrite /opt/xray-vps-setup/Caddyfile
  docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

  xray_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray_outbound" | envsubst)
  singbox_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/sing_box_outbound" | envsubst)

  xhttp_link="vless://$XRAY_UUID@$VLESS_DOMAIN:2087?mode=stream-up&security=reality&encryption=none&extra=%7B%22scMaxEachPostBytes%22%3A1000000.0%2C%22scMaxConcurrentPosts%22%3A100.0%2C%22scMinPostsIntervalMs%22%3A30.0%2C%22xPaddingBytes%22%3A%22100-1000%22%2C%22noGRPCHeader%22%3Afalse%7D&pbk=$XRAY_PBK&fp=chrome&type=xhttp&sni=www.yahoo.com&sid=$XRAY_SID#XHTTP-2087"

  final_msg="Clipboard string format:
vless://$XRAY_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$XRAY_SID&spx=%2F&flow=xtls-rprx-vision

XHTTP on 2087:
$xhttp_link

XRay outbound config:
$xray_config

Sing-box outbound config:
$singbox_config

Plain data:
PBK: $XRAY_PBK
SID: $XRAY_SID
UUID: $XRAY_UUID
"

  docker rmi ghcr.io/xtls/xray-core:latest caddy:latest || true

  clear
  echo "$final_msg"
}

end_script
set +e
