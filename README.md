# Автоматическая настройка сервера для Remnanode & Xray

Этот репозиторий содержит скрипт для автоматической настройки сервера под ноду Remnanode (Xray). Скрипт подготавливает сервер "с нуля", устанавливая все необходимые компоненты, настраивая сеть и применяя базовые правила безопасности.

## ⚡ Быстрый запуск одной командой

Вам не нужно ничего скачивать вручную. Просто скопируйте эту команду и вставьте в терминал вашего сервера:

```bash
curl -sSL https://raw.githubusercontent.com/Zover1337/RemnaNodeAuto/main/setup_node.sh | sudo bash
```

## 🛠 Ручная установка (Альтернативный способ)

Если вы хотите сначала скачать и посмотреть код скрипта перед запуском:

1. Скачайте скрипт:
```bash
wget https://raw.githubusercontent.com/Zover1337/RemnaNodeAuto/main/setup_node.sh
```

2. Сделайте его исполняемым:
```bash
chmod +x setup_node.sh
```

3. Запустите установку:
```bash
sudo ./setup_node.sh
```

**Требования:**
- Чистая ОС (рекомендуется Ubuntu/Debian)
- Права `root` (запуск от root или через `sudo`)

### Что делает скрипт быстрого запуска:
- Обновляет пакеты и устанавливает базовые зависимости.
- Отключает IPv6 и включает TCP BBR для улучшения сетевой производительности.
- Устанавливает Docker и плагин Docker Compose.
- Настраивает брандмауэр UFW (закрывает всё, открывает только нужные порты: SSH, HTTP/HTTPS, порты ноды).
- Устанавливает защиту от брутфорса Fail2Ban.
- Устанавливает Caddy для получения TLS-сертификатов (скрипт Selfsteal).
- Создает конфигурацию и запускает контейнер `remnanode` с переданным `SECRET_KEY`.
- Настраивает ротацию логов (logrotate) для Xray, чтобы не забивался диск.
- Устанавливает Traffic Guard для защиты от сканеров и ботнетов.
- Опционально устанавливает Cloudflare WARP.
- Автоматически генерирует ключи x25519 (Reality) для использования в панели управления Remnawave.

---

## 🛠 Продвинутая настройка (Ручная установка)

Если вы хотите полностью контролировать процесс, понимать, какие изменения вносятся в систему, или интегрировать ноду в уже работающий сервер, выполните следующие шаги вручную.

### 1. Подготовка системы
Обновите кэш пакетов и установите нужные системные утилиты:
```bash
sudo apt-get update -y
sudo apt-get install -y curl ufw logrotate sudo git dnsutils
```

### 2. Настройка сети (BBR и IPv6)
Для стабильной работы Xray рекомендуется отключить IPv6:
```bash
echo "net.ipv6.conf.all.disable_ipv6=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6=1" | sudo tee -a /etc/sysctl.conf
echo "net.ipv6.conf.lo.disable_ipv6=1" | sudo tee -a /etc/sysctl.conf
```
Включение алгоритма TCP BBR для ускорения сети:
```bash
echo "net.core.default_qdisc=fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 3. Установка Docker и Docker Compose
```bash
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker
sudo apt-get install -y docker-compose-plugin
```

### 4. Настройка брандмауэра (UFW)
Настройте файрвол. Если вы используете нестандартный SSH порт, замените `22` на ваш.
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем нужные порты
sudo ufw allow 22/tcp      # SSH
sudo ufw allow 2222/tcp    # Панель управления нодой
sudo ufw allow 80/tcp      # HTTP (для сертификатов)
sudo ufw allow 443/tcp     # HTTPS
sudo ufw allow 443/udp     # QUIC
sudo ufw allow 9443/tcp    # Reality
sudo ufw allow 61000/tcp
sudo ufw allow 45876/tcp

# Включаем UFW
echo "y" | sudo ufw enable
```

### 5. Установка защиты сервера (Fail2Ban и Traffic Guard)
**Fail2Ban (защита от брутфорс атак по SSH):**
```bash
bash <(curl -s https://raw.githubusercontent.com/Zover1337/Fail2Ban-AUTO/refs/heads/main/fail2ban-install.sh)
```
**Traffic Guard (защита от сетевых сканеров):**
```bash
curl -fsSL https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | sudo bash
sudo traffic-guard full \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
  -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
  --enable-logging
```

### 6. Установка сертификатов Caddy
Скрипт Selfsteal автоматически получает сертификаты от Let's Encrypt. Замените `example.com` на ваш рабочий домен.
```bash
# Формат передачи данных: Домен, Проверка DNS (1=да), Порт Reality (9443), Подтверждение (y)
printf "example.com\n1\n9443\ny\n" | bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install
```

### 7. Настройка и запуск Remnanode
Создайте директории и настройте права для логов Xray:
```bash
sudo mkdir -p /opt/remnanode /var/log/xray
sudo chmod 777 /var/log/xray
```
Создайте файл `docker-compose.yml` в папке `/opt/remnanode/`. Вы можете скопировать его из этого репозитория. Внутри файла **обязательно замените** `SECRET_KEY` на ключ из вашей панели Remnawave.

Запуск ноды:
```bash
cd /opt/remnanode
sudo docker compose up -d
```

### 8. Настройка ротации логов (logrotate)
Чтобы логи Xray не переполнили ваш жесткий диск, добавьте правило в logrotate:
```bash
cat << 'EOF' | sudo tee /etc/logrotate.d/xray
/var/log/xray/*.log {
      size 50M
      rotate 5
      compress
      missingok
      notifempty
      copytruncate
}
EOF
```

### 9. Генерация ключей Reality (x25519)
Дождитесь запуска контейнера и сгенерируйте пару ключей (Private Key / Public Key), которые вам понадобятся при настройке Inbounds в панели Remnawave:
```bash
sudo docker exec -it remnanode xray x25519
```
Сохраните выведенные ключи.

---

## 💡 Полезная информация

### Настройка логирования в Xray
Для записи логов доступа, убедитесь, что в конфигурации Xray указан правильный путь к файлу логов. Пример настройки:
```json
"log": {
  "access": "/var/log/xray/access.log",
  "loglevel": "info"
}
```

### Маршрутизация через WARP (Пример)
Если вам нужно пустить трафик через WARP, настройте исходящее подключение (`outbounds`) и правила маршрутизации (`routing`) следующим образом:

**Outbounds:**
```json
"outbounds": [
  {
    "tag": "warp-out",
    "protocol": "freedom",
    "settings": {},
    "streamSettings": {
      "sockopt": {
        "interface": "warp",
        "tcpFastOpen": true
      }
    }
  }
]
```

**Routing:**
```json
"routing": {
  "rules": [
    {
      "network": "tcp, udp",
      "outboundTag": "warp-out"
    }
  ]
}
```

### Конфигурация SELFSTEAL (Reality)
Пример настройки параметров `realitySettings` для использования со скриптом Selfsteal:
```json
"realitySettings": {
  "dest": "127.0.0.1:9443",
  "show": false,
  "xver": 0,
  "spiderX": "/",
  "shortIds": [
    ""
  ],
  "publicKey": "Публичный ключ(опционально)",
  "privateKey": "ПриватныйКлюч",
  "fingerprint": "фп",
  "serverNames": [
    "домен"
  ]
}
```
