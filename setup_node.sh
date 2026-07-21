#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}Ошибка: Этот скрипт необходимо запускать от root или через sudo.${NC}"
   exit 1
fi

# Переменные для хранения настроек в рамках сессии
DOMAIN=""
SECRET_KEY=""
SSH_PORT=""

# --- Вспомогательные функции запроса данных ---

get_domain() {
    if [[ -z "$DOMAIN" ]]; then
        read -p "Введите домен сервера (например, node.example.com): " DOMAIN
        while [[ -z "$DOMAIN" ]]; do
            echo -e "${RED}Домен не может быть пустым.${NC}"
            read -p "Введите домен сервера: " DOMAIN
        done
    fi
}

get_secret_key() {
    if [[ -z "$SECRET_KEY" ]]; then
        read -p "Введите SecretKey из панели Remnawave: " SECRET_KEY
        while [[ -z "$SECRET_KEY" ]]; do
            echo -e "${RED}SecretKey не может быть пустым.${NC}"
            read -p "Введите SecretKey из панели Remnawave: " SECRET_KEY
        done
    fi
}

get_ssh_port() {
    if [[ -z "$SSH_PORT" ]]; then
        read -p "Введите SSH порт (по умолчанию 22, нажмите Enter для согласия): " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}
    fi
}

# --- Отдельные шаги установки ---

step_sys_bbr() {
    clear
    echo -e "${YELLOW}[Шаг 1] Обновление пакетов, BBR и отключение IPv6...${NC}"
    apt-get update -y
    apt-get install -y curl ufw logrotate sudo git dnsutils

    if ! grep -q "disable_ipv6" /etc/sysctl.conf; then
        echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
        echo "net.ipv6.conf.lo.disable_ipv6=1" >> /etc/sysctl.conf
        sysctl -p >/dev/null 2>&1
        echo -e "${GREEN}IPv6 успешно отключен.${NC}"
    else
        echo -e "${GREEN}IPv6 уже отключен.${NC}"
    fi

    if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
        echo -e "${GREEN}BBR уже включен.${NC}"
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
        if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
            echo -e "${GREEN}BBR успешно включен!${NC}"
        else
            echo -e "${RED}Не удалось включить BBR автоматически.${NC}"
        fi
    fi
    echo -e "${GREEN}Шаг 1 завершен.${NC}"
}

step_install_docker() {
    clear
    echo -e "${YELLOW}[Шаг 2] Установка Docker и Docker Compose...${NC}"
    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
    else
        echo -e "${GREEN}Docker уже установлен.${NC}"
    fi

    if ! docker compose version &> /dev/null; then
        echo -e "${YELLOW}Установка Docker Compose плагина...${NC}"
        apt-get install -y docker-compose-plugin
    else
        echo -e "${GREEN}Docker Compose уже доступен.${NC}"
    fi
    echo -e "${GREEN}Шаг 2 завершен.${NC}"
}

step_ufw_ssh() {
    clear
    get_ssh_port
    echo -e "${YELLOW}[Шаг 3] Настройка брандмауэра UFW и SSH порта ($SSH_PORT)...${NC}"
    ufw default deny incoming
    ufw default allow outgoing

    ufw allow 22/tcp
    ufw allow OpenSSH
    ufw allow 2222/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 443/udp
    ufw allow 9443/tcp
    ufw allow 61000/tcp
    ufw allow 45876/tcp

    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "${YELLOW}Открытие кастомного SSH порта: $SSH_PORT/tcp${NC}"
        ufw allow "$SSH_PORT/tcp"

        if grep -q "^#Port " /etc/ssh/sshd_config || grep -q "^Port " /etc/ssh/sshd_config; then
            sed -i -E "s/^#?Port [0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
        else
            echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
        fi
        echo -e "${GREEN}Перезапуск службы SSH...${NC}"
        systemctl restart sshd || systemctl restart ssh
    fi

    echo "y" | ufw enable
    ufw status verbose
    echo -e "${GREEN}Шаг 3 завершен.${NC}"
}

step_fail2ban() {
    clear
    echo -e "${YELLOW}[Шаг 4] Установка Fail2Ban...${NC}"
    bash <(curl -s https://raw.githubusercontent.com/Zover1337/Fail2Ban-AUTO/refs/heads/main/fail2ban-install.sh)
    echo -e "${GREEN}Шаг 4 завершен.${NC}"
}

step_selfsteal() {
    clear
    get_domain
    echo -e "${YELLOW}[Шаг 5] Установка Caddy Selfsteal для $DOMAIN...${NC}"
    SERVER_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
    DOMAIN_IP=$(dig +short A "$DOMAIN" 2>/dev/null | tail -n1)

    if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
        echo -e "${RED}Внимание: Домен $DOMAIN указывает на IP ($DOMAIN_IP), а IP этого сервера ($SERVER_IP).${NC}"
        echo -e "${YELLOW}DNS проверка в selfsteal.sh может не пройти.${NC}"
    fi

    printf "%s\n1\n9443\ny\n" "$DOMAIN" | bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install
    echo -e "${GREEN}Шаг 5 завершен.${NC}"
}

step_remnanode() {
    clear
    get_secret_key
    echo -e "${YELLOW}[Шаг 6] Настройка и запуск Remnanode...${NC}"
    mkdir -p /opt/remnanode
    mkdir -p /var/log/xray
    chmod 777 /var/log/xray

    cat << EOF > /opt/remnanode/docker-compose.yml
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$SECRET_KEY"
    volumes:
      - '/var/log/xray:/var/log/xray'
      - /etc/letsencrypt:/etc/letsencrypt:ro
EOF

    echo -e "${GREEN}Файл /opt/remnanode/docker-compose.yml создан.${NC}"
    cd /opt/remnanode
    docker compose down &>/dev/null || true
    docker compose up -d
    docker compose ps
    echo -e "${GREEN}Шаг 6 завершен.${NC}"
}

step_logrotate() {
    clear
    echo -e "${YELLOW}[Шаг 7] Настройка Logrotate для логов Xray...${NC}"
    cat << 'EOF' > /etc/logrotate.d/xray
/var/log/xray/*.log {
      size 50M
      rotate 5
      compress
      missingok
      notifempty
      copytruncate
}
EOF
    echo -e "${GREEN}Ротация логов настроена (/etc/logrotate.d/xray).${NC}"
}

step_traffic_guard() {
    clear
    echo -e "${YELLOW}[Шаг 8] Установка и запуск Traffic Guard...${NC}"
    curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | sudo bash

    sudo traffic-guard full \
      -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
      -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
      --enable-logging
    echo -e "${GREEN}Шаг 8 завершен.${NC}"
}

step_warp() {
    clear
    echo -e "${YELLOW}[Шаг 9] Установка Cloudflare WARP...${NC}"
    bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
    echo -e "${GREEN}Шаг 9 завершен.${NC}"
}

step_keys() {
    clear
    echo -e "${YELLOW}Генерация Reality (x25519) ключей...${NC}"
    sleep 2
    XRAY_KEYS=$(docker exec remnanode xray x25519 2>/dev/null)
    if [[ -n "$XRAY_KEYS" ]]; then
        echo -e "\n${YELLOW}Ключи Reality (x25519):${NC}"
        echo -e "${CYAN}$XRAY_KEYS${NC}"
    else
        echo -e "\n${RED}Не удалось сгенерировать ключи. Убедитесь, что контейнер remnanode запущен.${NC}"
    fi
}

# --- Полная автоустановка (Всё в один клик) ---

full_install() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${CYAN}    Полная автоматическая установка Remnanode      ${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo

    get_domain
    read -p "Устанавливать ли Cloudflare WARP? [y/N]: " INSTALL_WARP
    INSTALL_WARP=${INSTALL_WARP:-n}
    get_ssh_port
    get_secret_key

    echo
    echo -e "${CYAN}--- Введенные настройки ---${NC}"
    echo -e "Домен: ${GREEN}$DOMAIN${NC}"
    echo -e "Установка WARP: ${GREEN}$INSTALL_WARP${NC}"
    echo -e "SSH порт: ${GREEN}$SSH_PORT${NC}"
    echo -e "SecretKey: ${GREEN}${SECRET_KEY:0:15}... (скрыто)${NC}"
    echo -e "${CYAN}--------------------------${NC}"
    echo
    read -p "Все верно? Нажмите Enter для продолжения..."

    step_sys_bbr
    step_install_docker
    step_ufw_ssh
    step_fail2ban
    step_selfsteal
    step_remnanode
    step_logrotate
    step_traffic_guard

    if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
        step_warp
    fi

    step_keys

    echo -e "\n${GREEN}====================================================${NC}"
    echo -e "${GREEN}    Автонастройка сервера успешно завершена!        ${NC}"
    echo -e "${GREEN}====================================================${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}

# --- Подменю выбора пошаговой установки ---

install_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN}             Пошаговая установка ноды               ${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${GREEN}1.${NC}  Запустить ПОЛНУЮ авто-установку (все шаги под ключ)"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e "${GREEN}2.${NC}  [Шаг 1] Обновить пакеты, BBR и отключить IPv6"
        echo -e "${GREEN}3.${NC}  [Шаг 2] Установить Docker & Docker Compose"
        echo -e "${GREEN}4.${NC}  [Шаг 3] Настроить UFW брандмауэр и SSH порт"
        echo -e "${GREEN}5.${NC}  [Шаг 4] Установить Fail2Ban"
        echo -e "${GREEN}6.${NC}  [Шаг 5] Установить Caddy Selfsteal"
        echo -e "${GREEN}7.${NC}  [Шаг 6] Создать и запустить Remnanode (Docker)"
        echo -e "${GREEN}8.${NC}  [Шаг 7] Настроить Logrotate для логов Xray"
        echo -e "${GREEN}9.${NC}  [Шаг 8] Установить Traffic Guard"
        echo -e "${GREEN}10.${NC} [Шаг 9] Установить Cloudflare WARP"
        echo -e "${GREEN}11.${NC} Получить Reality ключи (x25519)"
        echo -e "${GREEN}0.${NC}  Назад в главное меню"
        echo -e "${CYAN}====================================================${NC}"
        read -p "Выберите действие (0-11): " step_choice

        case $step_choice in
            1) full_install ;;
            2) step_sys_bbr; read -p "Нажмите Enter для продолжения..." ;;
            3) step_install_docker; read -p "Нажмите Enter для продолжения..." ;;
            4) step_ufw_ssh; read -p "Нажмите Enter для продолжения..." ;;
            5) step_fail2ban; read -p "Нажмите Enter для продолжения..." ;;
            6) step_selfsteal; read -p "Нажмите Enter для продолжения..." ;;
            7) step_remnanode; read -p "Нажмите Enter для продолжения..." ;;
            8) step_logrotate; read -p "Нажмите Enter для продолжения..." ;;
            9) step_traffic_guard; read -p "Нажмите Enter для продолжения..." ;;
            10) step_warp; read -p "Нажмите Enter для продолжения..." ;;
            11) step_keys; read -p "Нажмите Enter для продолжения..." ;;
            0) break ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

# --- Прочие функции управления ---

restart_node() {
    if [[ -d "/opt/remnanode" ]]; then
        echo -e "${YELLOW}Перезапуск Remnanode...${NC}"
        cd /opt/remnanode && docker compose restart
        echo -e "${GREEN}Готово!${NC}"
        read -p "Нажмите Enter для возврата в меню..."
    else
        echo -e "${RED}Нода не установлена (/opt/remnanode не найдена).${NC}"
        read -p "Нажмите Enter для возврата в меню..."
    fi
}

view_keys() {
    echo -e "${YELLOW}Ключи Reality (x25519):${NC}"
    docker exec remnanode xray x25519 2>/dev/null || echo -e "${RED}Контейнер не запущен или не установлен.${NC}"
    read -p "Нажмите Enter для возврата в меню..."
}

view_logs() {
    if [[ -d "/opt/remnanode" ]]; then
        echo -e "${YELLOW}Для выхода из просмотра логов нажмите Ctrl+C.${NC}"
        sleep 2
        cd /opt/remnanode && docker compose logs --tail=50 -f
    else
        echo -e "${RED}Нода не установлена.${NC}"
        read -p "Нажмите Enter для возврата в меню..."
    fi
}

# --- Главное меню ---

show_menu() {
    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN}    Меню управления сервером Remnanode & Xray       ${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${GREEN}1.${NC} Меню установки ноды (Всё сразу или по шагам)"
        echo -e "${GREEN}2.${NC} Перезапустить ноду"
        echo -e "${GREEN}3.${NC} Посмотреть логи"
        echo -e "${GREEN}4.${NC} Посмотреть Reality ключи"
        echo -e "${GREEN}0.${NC} Выход"
        echo -e "${CYAN}====================================================${NC}"
        read -p "Выберите действие (0-4): " choice

        case $choice in
            1) install_menu ;;
            2) restart_node ;;
            3) view_logs ;;
            4) view_keys ;;
            0) echo -e "${GREEN}Выход...${NC}"; exit 0 ;;
            *) echo -e "${RED}Неверный выбор, попробуйте еще раз.${NC}"; sleep 1 ;;
        esac
    done
}

show_menu
