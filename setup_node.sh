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

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}    Автонастройка сервера для Remnanode & Xray      ${NC}"
echo -e "${CYAN}====================================================${NC}"
echo

# 1. Запрос параметров у пользователя
# Домен сервера
read -p "Введите домен сервера (например, node.example.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    echo -e "${RED}Домен не может быть пустым.${NC}"
    read -p "Введите домен сервера: " DOMAIN
done

# Установка WARP
read -p "Устанавливать ли Cloudflare WARP? [y/N]: " INSTALL_WARP
INSTALL_WARP=${INSTALL_WARP:-n}

# SSH порт
read -p "Введите SSH порт (по умолчанию 22, нажмите Enter для согласия): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

# SecretKey из панели Remnawave
read -p "Введите SecretKey из панели Remnawave: " SECRET_KEY
while [[ -z "$SECRET_KEY" ]]; do
    echo -e "${RED}SecretKey не может быть пустым.${NC}"
    read -p "Введите SecretKey из панели Remnawave: " SECRET_KEY
done

echo
echo -e "${CYAN}--- Введенные настройки ---${NC}"
echo -e "Домен: ${GREEN}$DOMAIN${NC}"
echo -e "Установка WARP: ${GREEN}$INSTALL_WARP${NC}"
echo -e "SSH порт: ${GREEN}$SSH_PORT${NC}"
echo -e "SecretKey: ${GREEN}${SECRET_KEY:0:15}... (скрыто)${NC}"
echo -e "${CYAN}--------------------------${NC}"
echo
read -p "Все верно? Нажмите Enter для продолжения или Ctrl+C для отмены..."

# 2. Обновление пакетов и установка базовых зависимостей
echo -e "\n${YELLOW}[1/10] Обновление пакетов и установка зависимостей...${NC}"
apt-get update -y
apt-get install -y curl ufw logrotate sudo git dnsutils

# 3. Настройка TCP BBR и отключение IPv6
echo -e "\n${YELLOW}[2/10] Настройка TCP BBR и отключение IPv6...${NC}"

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

# 4. Установка Docker (если не установлен)
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Установка Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
else
    echo -e "${GREEN}Docker уже установлен.${NC}"
fi

# Проверяем наличие docker-compose / docker compose
if ! docker compose version &> /dev/null; then
    echo -e "${YELLOW}Установка Docker Compose плагина...${NC}"
    apt-get install -y docker-compose-plugin
fi

# 5. Настройка UFW
echo -e "\n${YELLOW}[3/10] Настройка брандмауэра UFW...${NC}"
ufw default deny incoming
ufw default allow outgoing

# Открываем порты
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
fi

# Включаем UFW без подтверждения
echo "y" | ufw enable
ufw status verbose

# 6. Настройка SSH порта (если он изменен)
if [[ "$SSH_PORT" != "22" ]]; then
    echo -e "\n${YELLOW}[4/10] Настройка SSH демона на порт $SSH_PORT...${NC}"
    if grep -q "^#Port " /etc/ssh/sshd_config || grep -q "^Port " /etc/ssh/sshd_config; then
        sed -i -E "s/^#?Port [0-9]+/Port $SSH_PORT/" /etc/ssh/sshd_config
    else
        echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi
    echo -e "${GREEN}Перезапуск службы SSH...${NC}"
    systemctl restart sshd || systemctl restart ssh
fi

# 7. Установка Fail2Ban
echo -e "\n${YELLOW}[5/10] Установка Fail2Ban через авто-скрипт...${NC}"
bash <(curl -s https://raw.githubusercontent.com/Zover1337/Fail2Ban-AUTO/refs/heads/main/fail2ban-install.sh)

# 8. Установка Caddy Selfsteal
echo -e "\n${YELLOW}[6/10] Установка Caddy Selfsteal...${NC}"
# Перед запуском проверяем DNS-запись домена, чтобы минимизировать ошибки DNS-проверки в скрипте selfsteal
SERVER_IP=$(curl -s https://ipinfo.io/ip || curl -s https://api.ipify.org || curl -s https://ifconfig.me)
DOMAIN_IP=$(dig +short A "$DOMAIN" 2>/dev/null | tail -n1)

if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    echo -e "${RED}Внимание: Домен $DOMAIN указывает на IP ($DOMAIN_IP), а IP этого сервера ($SERVER_IP).${NC}"
    echo -e "${YELLOW}DNS проверка в selfsteal.sh может не пройти. Если вы настроили DNS только что, подождите или пропустите ее в интерактивном режиме.${NC}"
fi

# Передаем ответы в интерактивный скрипт selfsteal:
# 1) Домен
# 2) 1 (Запуск проверки DNS)
# 3) 9443 (Порт)
# 4) y (Подтверждение)
printf "%s\n1\n9443\ny\n" "$DOMAIN" | bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install

# 9. Настройка Remnanode (Docker)
echo -e "\n${YELLOW}[7/10] Настройка Remnanode...${NC}"
mkdir -p /opt/remnanode
mkdir -p /var/log/xray
chmod 777 /var/log/xray

# Создание docker-compose.yml с интегрированным SecretKey и логированием xray
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

echo -e "${GREEN}Файл /opt/remnanode/docker-compose.yml успешно создан.${NC}"

# Запуск контейнера Remnanode
echo -e "${YELLOW}Запуск докер-контейнера Remnanode...${NC}"
cd /opt/remnanode
docker compose down &>/dev/null || true
docker compose up -d
docker compose ps

# 10. Настройка ротации логов для xray
echo -e "\n${YELLOW}[8/10] Настройка Logrotate для логов xray...${NC}"
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

# 11. Установка Traffic Guard
echo -e "\n${YELLOW}[9/10] Установка и запуск Traffic Guard...${NC}"
curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | sudo bash

sudo traffic-guard full \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
  --enable-logging

# 12. Установка WARP (если выбран)
if [[ "$INSTALL_WARP" =~ ^[Yy]$ ]]; then
    echo -e "\n${YELLOW}[10/10] Установка Cloudflare WARP...${NC}"
    bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
else
    echo -e "\n${GREEN}[10/10] Установка WARP пропущена.${NC}"
fi

# 13. Генерация ключей x25519 (Reality) для Xray
echo -e "\n${YELLOW}Ожидание запуска контейнера и генерация Reality ключей...${NC}"
sleep 5
XRAY_KEYS=$(docker exec remnanode xray x25519 2>/dev/null)

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}    Автонастройка сервера успешно завершена!        ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "Домен для маскировки (Reality): ${CYAN}$DOMAIN${NC}"
echo -e "Порт для маскировки (Reality): ${CYAN}9443${NC}"
echo -e "NODE_PORT (для панели Remnawave): ${CYAN}2222${NC}"
echo -e "Папка с конфигом Remnanode: ${CYAN}/opt/remnanode${NC}"
echo -e "Папка с логами Xray: ${CYAN}/var/log/xray${NC}"

if [[ -n "$XRAY_KEYS" ]]; then
    echo -e "\n${YELLOW}Ключи Reality (x25519) для настройки ноды в панели:${NC}"
    echo -e "${CYAN}$XRAY_KEYS${NC}"
else
    echo -e "\n${RED}Не удалось автоматически сгенерировать Reality ключи.${NC}"
    echo -e "Вы можете получить их вручную командой: ${YELLOW}docker exec -it remnanode xray x25519${NC}"
fi

echo -e "\nПроверка логов контейнера: ${CYAN}docker compose -f /opt/remnanode/docker-compose.yml logs -f${NC}"
echo -e "${GREEN}====================================================${NC}"
