#!/bin/bash

export LANG=ru_RU.UTF-8

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

red(){
    echo -e "\033[31m\033[01m$1\033[0m"
}

green(){
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow(){
    echo -e "\033[33m\033[01m$1\033[0m"
}

if [[ $EUID -ne 0 ]]; then
    red "Внимание: Запустите скрипт от имени root пользователя"
    exit 1
fi

CUSTOM_SNI=""
for arg in "$@"; do
    case $arg in
        --custom-sni=*)
            CUSTOM_SNI="${arg#*=}"
            shift
            ;;
        --help)
            echo "Использование: $0 [--custom-sni=example.com]"
            echo ""
            echo "Опции:"
            echo "  --custom-sni=HOSTNAME  Указать свой SNI хост (по умолчанию: web.max.ru)"
            echo "  --help                 Показать эту справку"
            exit 0
            ;;
    esac
done

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Alpine")
PACKAGE_UPDATE=("apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "apk update -f")
PACKAGE_INSTALL=("apt -y install" "apt -y install" "yum -y install" "yum -y install" "yum -y install" "apk add -f")

CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')")

for i in "${CMD[@]}"; do
    SYS="$i" && [[ -n $SYS ]] && break
done

for ((int = 0; int < ${#REGEX[@]}; int++)); do
    [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]] && SYSTEM="${RELEASE[int]}" && [[ -n $SYSTEM ]] && break
done

[[ -z $SYSTEM ]] && red "Текущая система VPS не поддерживается, используйте основную операционную систему" && exit 1

if [[ -z $(type -P curl) ]]; then
    if [[ ! $SYSTEM == "CentOS" ]]; then
        ${PACKAGE_UPDATE[int]}
    fi
    ${PACKAGE_INSTALL[int]} curl
fi

get_ip() {
    local ip=$(curl -s4m8 ip.sb -k) || ip=$(curl -s6m8 ip.sb -k)
    echo "$ip"
}

install_server_core() {
    yellow "Установка Hysteria2..."
    
    set -e

    SCRIPT_ARGS=("$@")

    EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"

    SYSTEMD_SERVICES_DIR="/etc/systemd/system"

    CONFIG_DIR="/etc/hysteria"

    REPO_URL="https://github.com/apernet/hysteria"

    HY2_API_BASE_URL="https://api.hy2.io/v1"

    CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

    PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"

    OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"

    ARCHITECTURE="${ARCHITECTURE:-}"

    HYSTERIA_USER="${HYSTERIA_USER:-}"

    HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-}"

    OPERATION=

    VERSION=

    FORCE=

    LOCAL_FILE=

    has_command() {
      local _command=$1
      type -P "$_command" > /dev/null 2>&1
    }

    curl() {
      command curl "${CURL_FLAGS[@]}" "$@"
    }

    mktemp() {
      command mktemp "$@" "/tmp/hyservinst.XXXXXXXXXX"
    }

    note() {
      local _msg="$1"
      echo -e "$SCRIPT_NAME: $(tput bold)note: $_msg$(tput sgr0)"
    }

    warning() {
      local _msg="$1"
      echo -e "$SCRIPT_NAME: $(tput setaf 3)warning: $_msg$(tput sgr0)"
    }

    error() {
      local _msg="$1"
      echo -e "$SCRIPT_NAME: $(tput setaf 1)error: $_msg$(tput sgr0)"
    }

    check_environment_operating_system() {
      if [[ -n "$OPERATING_SYSTEM" ]]; then
        warning "OPERATING_SYSTEM=$OPERATING_SYSTEM обнаружено, определение ОС выполняться не будет."
        return
      fi

      if [[ "x$(uname)" == "xLinux" ]]; then
        OPERATING_SYSTEM=linux
        return
      fi

      error "Этот скрипт поддерживает только Linux."
      exit 95
    }

    check_environment_architecture() {
      if [[ -n "$ARCHITECTURE" ]]; then
        warning "ARCHITECTURE=$ARCHITECTURE обнаружено, определение архитектуры выполняться не будет."
        return
      fi

      case "$(uname -m)" in
        'i386' | 'i686')
          ARCHITECTURE='386'
          ;;
        'amd64' | 'x86_64')
          ARCHITECTURE='amd64'
          ;;
        'armv5tel' | 'armv6l' | 'armv7' | 'armv7l')
          ARCHITECTURE='arm'
          ;;
        'armv8' | 'aarch64')
          ARCHITECTURE='arm64'
          ;;
        'mips' | 'mipsle' | 'mips64' | 'mips64le')
          ARCHITECTURE='mipsle'
          ;;
        's390x')
          ARCHITECTURE='s390x'
          ;;
        *)
          error "Архитектура '$(uname -a)' не поддерживается."
          exit 8
          ;;
      esac
    }

    check_environment_systemd() {
      if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
        return
      fi

      case "$FORCE_NO_SYSTEMD" in
        '1')
          warning "FORCE_NO_SYSTEMD=1, продолжим даже если systemd не обнаружен."
          ;;
        '2')
          warning "FORCE_NO_SYSTEMD=2, продолжим но пропустим все команды связанные с systemd."
          ;;
        *)
          error "Этот скрипт поддерживает только дистрибутивы Linux с systemd."
          exit 1
          ;;
      esac
    }

    update_packages() {
      ${PACKAGE_UPDATE[int]}
    }

    check_environment_curl() {
      if has_command curl; then
        return
      fi
      ${PACKAGE_INSTALL[int]} curl
    }

    check_environment_grep() {
      if has_command grep; then
        return
      fi
      ${PACKAGE_INSTALL[int]} grep
    }

    check_environment_qrencode() {
      if has_command qrencode; then
        return
      fi
      ${PACKAGE_INSTALL[int]} qrencode
    }

    check_environment() {
      update_packages
      check_environment_operating_system
      check_environment_architecture
      check_environment_systemd
      check_environment_curl
      check_environment_grep
      check_environment_qrencode
    }

    install_content() {
      local _install_flags="$1"
      local _content="$2"
      local _destination="$3"
      local _overwrite="$4"

      local _tmpfile="$(mktemp)"

      echo -ne "Установка $_destination ... "
      echo "$_content" > "$_tmpfile"
      if [[ -z "$_overwrite" && -e "$_destination" ]]; then
        echo -e "существует"
      elif install "$_install_flags" "$_tmpfile" "$_destination"; then
        echo -e "ок"
      fi

      rm -f "$_tmpfile"
    }

    get_latest_version() {
      if [[ -n "$VERSION" ]]; then
        echo "$VERSION"
        return
      fi

      local _tmpfile=$(mktemp)
      if ! curl -sS "$HY2_API_BASE_URL/update?cver=installscript&plat=${OPERATING_SYSTEM}&arch=${ARCHITECTURE}&chan=release&side=server" -o "$_tmpfile"; then
        error "Ошибка получения последней версии от Hysteria 2 API"
        exit 11
      fi

      local _latest_version=$(grep -oP '"lver":\s*\K"v.*?"' "$_tmpfile" | head -1)
      _latest_version=${_latest_version#'"'}
      _latest_version=${_latest_version%'"'}

      if [[ -n "$_latest_version" ]]; then
        echo "$_latest_version"
      fi

      rm -f "$_tmpfile"
    }

    download_hysteria() {
      local _version="$1"
      local _destination="$2"

      local _download_url="$REPO_URL/releases/download/app/$_version/hysteria-$OPERATING_SYSTEM-$ARCHITECTURE"
      echo "Загрузка бинарного файла hysteria: $_download_url ..."
      if ! curl -R -H 'Cache-Control: no-cache' "$_download_url" -o "$_destination"; then
        error "Ошибка загрузки, проверьте ваше соединение и попробуйте снова."
        return 11
      fi
      return 0
    }

    perform_install_hysteria_binary() {
      local _tmpfile=$(mktemp)
      local _version=$(get_latest_version)

      if ! download_hysteria "$_version" "$_tmpfile"; then
        rm -f "$_tmpfile"
        exit 11
      fi

      echo -ne "Установка исполняемого файла hysteria ... "
      if install -Dm755 "$_tmpfile" "$EXECUTABLE_INSTALL_PATH"; then
        echo "ок"
      else
        exit 13
      fi

      rm -f "$_tmpfile"

      mkdir -p /etc/hysteria
    }

    perform_install_hysteria_systemd() {
      if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]]; then
        return
      fi

      local _service_content=$(cat << 'EOF'
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
WorkingDirectory=~
User=root
Group=root
Environment=HYSTERIA_LOG_LEVEL=info
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
)
      install_content -Dm644 "$_service_content" "$SYSTEMD_SERVICES_DIR/hysteria-server.service" "1"

      systemctl daemon-reload
    }

    check_environment
    HYSTERIA_USER="root"
    HYSTERIA_HOME_DIR="/root"

    perform_install_hysteria_binary
    perform_install_hysteria_systemd

    green "Hysteria2 core успешно установлен!"
}

configure_hysteria() {
    yellow "Настройка сервера Hysteria2..."
    
    if [[ -n "$CUSTOM_SNI" ]]; then
        local sni_host="$CUSTOM_SNI"
        yellow "Используется кастомный SNI: $sni_host"
    else
        local sni_host="apple.com"
    fi
    
    local masquerade_url="$sni_host"
    local port="8443"
    
    mkdir -p /etc/hysteria
    
    local auth_pwd=$(date +%s%N | md5sum | cut -c 1-16)
    local obfs_pwd=$(date +%s%N | md5sum | cut -c 1-16)
    
    openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/private.key
    openssl req -new -x509 -days 36500 -key /etc/hysteria/private.key -out /etc/hysteria/cert.crt -subj "/CN=$sni_host"
    chmod 600 /etc/hysteria/cert.crt
    chmod 600 /etc/hysteria/private.key

    cat << EOF > /etc/hysteria/config.yaml
listen: :$port

tls:
  cert: /etc/hysteria/cert.crt
  key: /etc/hysteria/private.key

obfs:
  type: salamander
  salamander:
    password: $obfs_pwd

auth:
  type: password
  password: $auth_pwd

masquerade:
  type: proxy
  proxy:
    url: https://$masquerade_url
    rewriteHost: true

quic:
  initStreamReceiveWindow: 16777216
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 33554432
  maxConnReceiveWindow: 33554432
EOF

    local server_ip=$(get_ip)
    
    cat << EOF > /root/hysteria2.txt
hy2://$auth_pwd@$server_ip:$port?mport&security=tls&sni=$sni_host&allowInsecure=true&alpn&obfs=salamander&obfs-password=$obfs_pwd#Test
EOF

    green "Настройка завершена!"
    echo
    yellow "IP сервера: $server_ip"
    yellow "Порт: $port"
    yellow "SNI: $sni_host"
    yellow "Пароль аутентификации: $auth_pwd"
    yellow "Пароль обфускации: $obfs_pwd"
    yellow "Маскировка: https://$masquerade_url"
    echo
    
    if [[ -n "$CUSTOM_SNI" ]]; then
        green "Использован кастомный SNI: $CUSTOM_SNI"
    fi
}

start_service() {
    yellow "Запуск службы Hysteria2..."
    
    systemctl daemon-reload
    systemctl enable hysteria-server
    systemctl start hysteria-server
    
    sleep 2
    if systemctl is-active --quiet hysteria-server; then
        green "Служба Hysteria2 успешно запущена"
    else
        red "Ошибка запуска службы Hysteria2"
        systemctl status hysteria-server
        exit 1
    fi
}

show_config() {
    if command -v qrencode &> /dev/null; then
        green "=== QR Code ==="
        qrencode -t ANSIUTF8 "$(cat /root/hysteria2.txt)"
    else
        yellow "Установите qrencode для генерации QR кода: apt install qrencode / yum install qrencode"
    fi
}

uninstall_hysteria() {
    red "Удаление Hysteria2..."
    
    systemctl stop hysteria-server 2>/dev/null || true
    systemctl disable hysteria-server 2>/dev/null || true
    rm -f /etc/systemd/system/hysteria-server.service
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -f /root/hysteria2.txt
    systemctl daemon-reload
    
    green "Hysteria2 полностью удален!"
}

check_hysteria_installed() {
    [[ -f "/usr/local/bin/hysteria" ]]
}

main() {
    if check_hysteria_installed; then
        red "Hysteria2 уже установлен!"
        echo
        read -p "Хотите переустановить? [y/N]: " reinstall
        case $reinstall in
            [yY]|[yY][eE][sS])
                uninstall_hysteria
                ;;
            *)
                echo "Выход..."
                exit 0
                ;;
        esac
    fi

    install_server_core
    configure_hysteria
    start_service
    show_config
    
    echo
    green "Установка Hysteria2 успешно завершена!"
    echo
    yellow "Конфиг клиента: /root/hysteria2.txt"
    yellow "Перезапуск службы: systemctl restart hysteria-server"
    yellow "Проверка статуса: systemctl status hysteria-server"
    echo
    yellow "Hysteria2 ключ:"
    cat /root/hysteria2.txt
    echo
    echo "Инструкции по настройке VPN приложений:"
    echo "https://github.com/YukiKras/wiki/blob/main/nastroikavpn.md"
}

main
