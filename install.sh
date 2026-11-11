#!/bin/sh
# ==============================================================================
# KeenSniff (Go) — автономный установщик для роутеров Keenetic
#
# Установка / обновление в одну команду:
#   curl -sSL https://raw.githubusercontent.com/bjornfree/KeenSniff/main/install.sh | sh
# или через wget:
#   wget -qO- https://raw.githubusercontent.com/bjornfree/KeenSniff/main/install.sh | sh
#
# Удаление:
#   sh /opt/keensniff-go/uninstall.sh
# ==============================================================================

set -eu
umask 022

ROOT="/opt/keensniff-go"
INIT="/opt/etc/init.d/S99sniffer-go"
DEFAULT_REPO="bjornfree/KeenSniff"
REPO="${REPO:-$DEFAULT_REPO}"
GITHUB_RELEASES_URL="https://github.com/${REPO}/releases/latest/download"
GITHUB_PAGES_URL="https://bjornfree.github.io/KeenSniff/downloads"
TMP_STAGE="/tmp/keensniff-install-$$"

info()  { printf "\033[1;32m[+]\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m[!]\033[0m %s\n" "$1"; }
error() { printf "\033[1;31m[-]\033[0m %s\n" "$1"; }
die()   { error "$1"; exit 1; }

# --- Определение архитектуры роутера ---
detect_arch() {
    if command -v opkg >/dev/null 2>&1; then
        case "$(opkg print-architecture 2>/dev/null | awk '/_kn/{print $2; exit}')" in
            aarch64*) echo "arm64"; return 0 ;;
            mipsel*)  echo "mipsle"; return 0 ;;
            mips*)    echo "mips"; return 0 ;;
            arm*)     echo "arm"; return 0 ;;
        esac
    fi
    case "$(uname -m 2>/dev/null)" in
        aarch64*|arm64*) echo "arm64"; return 0 ;;
        arm*)            echo "arm"; return 0 ;;
        mips*)
            if [ -f /bin/busybox ]; then
                endian=$(dd if=/bin/busybox bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 2>/dev/null | tr -d ' ')
                if [ "$endian" = "2" ]; then
                    echo "mips"; return 0
                fi
            fi
            echo "mipsle"; return 0
            ;;
    esac
    return 1
}

# --- Проверка свободной памяти ---
get_avail_mem_kb() {
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${mem_avail:-0}" -eq 0 ]; then
        mem_free=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        buffers=$(awk '/^Buffers:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        cached=$(awk '/^Cached:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        mem_avail=$((mem_free + buffers + cached))
    fi
    echo "${mem_avail:-0}"
}

# --- Проверка ресурсов до начала установки ---
check_resources_pre() {
    info "Проверка окружения и ресурсов роутера..."
    [ -d /opt ] || die "Каталог /opt не найден. Установите OPKG (Entware) через веб-интерфейс Keenetic."

    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
    mem_avail=$(get_avail_mem_kb)

    [ "$mem_total" -ge 80000 ] || die "Недостаточно общей памяти: $((mem_total / 1024)) МБ (требуется от 90 МБ)."
    
    if [ "$mem_avail" -lt 15000 ]; then
        die "Критически мало свободной памяти: доступно всего $((mem_avail / 1024)) МБ. Установка отменена для безопасности роутера."
    elif [ "$mem_avail" -lt 30000 ]; then
        warn "Свободной памяти мало ($((mem_avail / 1024)) МБ), но для Go-демона с лимитом кучи (32 МБ) достаточно."
    else
        info "Память: всего $((mem_total / 1024)) МБ, доступно $((mem_avail / 1024)) МБ — ресурсов достаточно."
    fi

    disk_free=$(df -k /opt 2>/dev/null | awk 'NR==2{print $4}')
    [ "${disk_free:-0}" -ge 25000 ] || die "Недостаточно свободного места в /opt ($((disk_free / 1024)) МБ, требуется от 25 МБ)."
    info "Свободно на диске в /opt: $((disk_free / 1024)) МБ."
}

# --- Скачивание файла с автоматическим доустановлением curl при необходимости ---
download_file() {
    url="$1"
    dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --connect-timeout 15 --max-time 120 "$url" -o "$dest" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$dest" "$url" 2>/dev/null && return 0
    fi
    return 1
}

fetch_package() {
    arch="$1"
    tarball_name="keensniff-go-${arch}.tar.gz"
    dest="$TMP_STAGE/$tarball_name"
    mkdir -p "$TMP_STAGE"

    info "Скачиваю пакет для архитектуры $arch..."
    
    # 1. Пробуем GitHub Releases
    url="${GITHUB_RELEASES_URL}/${tarball_name}"
    if download_file "$url" "$dest" && [ -s "$dest" ]; then
        info "Пакет успешно скачан из GitHub Releases."
        echo "$dest"
        return 0
    fi

    # 2. Пробуем GitHub Pages
    url="${GITHUB_PAGES_URL}/${tarball_name}"
    if download_file "$url" "$dest" && [ -s "$dest" ]; then
        info "Пакет успешно скачан из GitHub Pages."
        echo "$dest"
        return 0
    fi

    # 3. Если скачивание не удалось (например, busybox wget не поддерживает HTTPS)
    warn "Прямое скачивание не удалось (возможно, wget без поддержки HTTPS)."
    if command -v opkg >/dev/null 2>&1; then
        info "Устанавливаю пакет curl через opkg..."
        opkg update >/dev/null 2>&1 || true
        opkg install curl >/dev/null 2>&1 || true
        if command -v curl >/dev/null 2>&1; then
            if curl -fSL --connect-timeout 15 --max-time 120 "${GITHUB_RELEASES_URL}/${tarball_name}" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
                info "Пакет успешно скачан с помощью curl."
                echo "$dest"
                return 0
            fi
            if curl -fSL --connect-timeout 15 --max-time 120 "${GITHUB_PAGES_URL}/${tarball_name}" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
                info "Пакет успешно скачан с помощью curl."
                echo "$dest"
                return 0
            fi
        fi
    fi

    die "Не удалось скачать архив $tarball_name. Проверьте интернет-соединение."
}

# --- Проверка ответа веб-сервера роутера ---
probe_keenetic_web() {
    if command -v curl >/dev/null 2>&1; then
        curl -sI -m 2 http://127.0.0.1:80 >/dev/null 2>&1 || curl -sI -m 2 "http://${LAN_IP}:80" >/dev/null 2>&1 && return 0
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 2 -O /dev/null http://127.0.0.1:80 2>/dev/null || wget -q -T 2 -O /dev/null "http://${LAN_IP}:80" 2>/dev/null && return 0
    fi
    test -S /var/run/ndm.core.socket
}

# --- Экстренное самоудаление при сбое ресурсов или веб-интерфейса ---
emergency_rollback() {
    reason="$1"
    echo ""
    error "================================================================="
    error "  СБОЙ БЕЗОПАСНОСТИ: $reason"
    error "  ВНИМАНИЕ: Запущено экстренное автоматическое удаление KeenSniff!"
    error "================================================================="
    echo ""

    warn "Останавливаем службу KeenSniff..."
    "$INIT" stop 2>/dev/null || true
    killall -9 keensniff 2>/dev/null || true

    warn "Удаляем установленные файлы..."
    rm -f "$INIT"
    rm -rf "$ROOT"
    rm -rf "$TMP_STAGE"

    info "Роутер возвращён в исходное состояние, веб-интерфейс Keenetic сохранён."
    exit 1
}

# --- Проверка стабильности роутера и KeenSniff после старта ---
verify_and_guard() {
    info "Запуск демона и контроль стабильности роутера (20 сек)..."
    
    attempts=0
    max_attempts=10
    
    while [ "$attempts" -lt "$max_attempts" ]; do
        attempts=$((attempts + 1))
        sleep 2
        
        # 1. Проверяем, что ядро NDM живо
        if [ ! -S /var/run/ndm.core.socket ]; then
            emergency_rollback "Сокет ядра Keenetic (/var/run/ndm.core.socket) перестал отвечать"
        fi
        
        # 2. Проверяем, что веб-морда роутера открывается
        if ! probe_keenetic_web; then
            emergency_rollback "Веб-интерфейс Keenetic перестал отвечать на запросы (порт 80)"
        fi
        
        # 3. Проверяем, что свободная память не упала ниже критического порога (8 МБ)
        curr_avail=$(get_avail_mem_kb)
        if [ "$curr_avail" -gt 0 ] && [ "$curr_avail" -lt 8000 ]; then
            emergency_rollback "Критический дефицит RAM ($((curr_avail / 1024)) МБ свободно), угроза сбоя роутера"
        fi
        
        # 4. Проверяем здоровье самого KeenSniff
        if curl -fsS -m 2 http://127.0.0.1:8080/api/healthz >/dev/null 2>&1; then
            info "Демон KeenSniff успешно запущен и прошёл health-чек!"
            return 0
        fi
    done
    
    emergency_rollback "KeenSniff не ответил на health-чек за 20 секунд"
}

# --- Создание скрипта штатного удаления ---
create_uninstall_script() {
    cat <<'EOF' > "$ROOT/uninstall.sh"
#!/bin/sh
set -e
echo "[keensniff] Остановка службы..."
/opt/etc/init.d/S99sniffer-go stop 2>/dev/null || true
killall -9 keensniff 2>/dev/null || true
echo "[keensniff] Удаление автозапуска и файлов..."
rm -f /opt/etc/init.d/S99sniffer-go
rm -rf /opt/keensniff-go
echo "[keensniff] KeenSniff успешно удалён."
EOF
    chmod 755 "$ROOT/uninstall.sh"
}

# --- Главный процесс установки ---
main() {
    if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "--uninstall" ]; then
        if [ -f "$ROOT/uninstall.sh" ]; then
            sh "$ROOT/uninstall.sh"
            exit 0
        fi
        "$INIT" stop 2>/dev/null || true
        rm -f "$INIT"
        rm -rf "$ROOT"
        info "KeenSniff удалён."
        exit 0
    fi

    echo ""
    info "=========================================="
    info "      Установка KeenSniff (Go)"
    info "=========================================="
    echo ""

    ARCH=$(detect_arch) || die "Не удалось определить архитектуру CPU роутера."
    info "Архитектура процессора: $ARCH"

    check_resources_pre

    LAN_IP=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{split($2, a, "/"); print a[1]; exit}')
    [ -n "$LAN_IP" ] || LAN_IP="192.168.1.1"
    LAN_CIDR=$(ip -4 addr show br0 2>/dev/null | awk '/inet /{printf "%s%s", sep, $2; sep=","}')
    [ -n "$LAN_CIDR" ] || LAN_CIDR="192.168.1.0/24"

    # Если уже стояла старая Python-версия, останавливаем её
    if [ -x /opt/etc/init.d/S99sniffer ]; then
        info "Обнаружена предыдущая Python-версия. Останавливаем..."
        /opt/etc/init.d/S99sniffer stop 2>/dev/null || true
        chmod -x /opt/etc/init.d/S99sniffer 2>/dev/null || true
    fi

    TARBALL=$(fetch_package "$ARCH")
    
    info "Распаковка пакета..."
    EXTRACT_DIR="$TMP_STAGE/extract"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
    
    PKG_SRC=$(ls -d "$EXTRACT_DIR"/keensniff-go-* 2>/dev/null | head -n 1 || true)
    [ -n "$PKG_SRC" ] && [ -d "$PKG_SRC" ] || die "Некорректная структура архива."

    # Проверка совместимости бинарника с CPU
    if ! "$PKG_SRC/bin/keensniff" -h >/dev/null 2>&1; then
        emergency_rollback "Бинарник не запускается на этом процессоре (несовместимая архитектура)"
    fi

    info "Копирование файлов в $ROOT..."
    mkdir -p "$ROOT/bin" "$ROOT/state" "$ROOT/state/dns/cache"
    cp "$PKG_SRC/bin/keensniff" "$ROOT/bin/keensniff" && chmod 755 "$ROOT/bin/keensniff"
    [ ! -f "$PKG_SRC/bin/import-config" ] || { cp "$PKG_SRC/bin/import-config" "$ROOT/bin/import-config" && chmod 755 "$ROOT/bin/import-config"; }
    
    rm -rf "$ROOT/static"
    cp -R "$PKG_SRC/static" "$ROOT/static"
    [ ! -f "$PKG_SRC/VERSION" ] || cp "$PKG_SRC/VERSION" "$ROOT/VERSION"
    [ ! -f "$PKG_SRC/update.sh" ] || { cp "$PKG_SRC/update.sh" "$ROOT/update.sh" && chmod 755 "$ROOT/update.sh"; }

    create_uninstall_script

    # Генерация config.json при чистой установке
    if [ ! -f "$ROOT/config.json" ]; then
        info "Генерация конфигурации под роутер..."
        SEED="$TMP_STAGE/seed" && mkdir -p "$SEED"
        echo '{}' > "$SEED/settings.json"
        echo '{}' > "$ROOT/state/routing_policies.json"
        cp "$ROOT/state/routing_policies.json" "$SEED/routing_policies.json"
        # Список рекламы указан, но выключен: включается вручную во вкладке «Реклама».
        echo '{"provider_dns_servers": ["77.88.8.8", "9.9.9.9"], "tunnel_dns_servers": ["9.9.9.9", "8.8.8.8"], "subscriptions": [{"url": "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/light.txt", "kind": "blocklist", "enabled": false}]}' > "$ROOT/state/dns/config.json"

        if [ -x "$ROOT/bin/import-config" ]; then
            env -u LD_LIBRARY_PATH -u LD_PRELOAD "$ROOT/bin/import-config" -legacy-dir "$SEED" -source-dir "$ROOT" -root "$ROOT" \
                -discover -lan "$LAN_CIDR" -listen 0.0.0.0:8080 -output "$ROOT/config.json" >/dev/null 2>&1 || true
        fi

        # Если import-config создал конфиг, активируем его
        if [ -f "$ROOT/config.json" ]; then
            sed -i \
                -e "s#\"registry\": \".*\"#\"registry\": \"$ROOT/state/routing_policies.json\"#" \
                -e "s#\"apply_routes\": false,#\"apply_routes\": true,\n  \"dns_listen\": \"$LAN_IP:5300\",\n  \"dns_config\": \"$ROOT/state/dns/config.json\",\n  \"dns_cache_dir\": \"$ROOT/state/dns/cache\",\n  \"dns_intercept\": true,\n  \"dns_destination\": \"$LAN_IP\",#" \
                "$ROOT/config.json" 2>/dev/null || true
        fi
    fi

    # Установка init-скрипта
    if [ -f "$PKG_SRC/S99sniffer-go.tpl" ]; then
        sed "s#__ROOT__#$ROOT#" "$PKG_SRC/S99sniffer-go.tpl" > "$INIT" && chmod 755 "$INIT"
    fi

    # Запуск и строгий контроль стабильности роутера
    "$INIT" restart >/dev/null 2>&1 || "$INIT" start >/dev/null 2>&1 || true
    
    verify_and_guard

    # Очистка временных файлов
    rm -rf "$TMP_STAGE"

    echo ""
    info "============================================================"
    info "  KeenSniff успешно установлен и стабильно работает!"
    info "  Веб-интерфейс: http://${LAN_IP}:8080"
    info ""
    info "  Команда удаления (при необходимости):"
    info "    sh $ROOT/uninstall.sh"
    info "============================================================"
    echo ""
}

main "$@"
