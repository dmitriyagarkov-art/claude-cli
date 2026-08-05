#!/usr/bin/env bash
# =============================================================================
#  Claude или ChatGPT Codex на своём сервере — установщик
#  dmitriymarketing
#
#  Запускать НА СЕРВЕРЕ (Ubuntu 22.04 / 24.04) от root:
#    bash -c "$(curl -fsSL https://claude-cli-iota.vercel.app/install-ai.sh)"
#
#  Ставит ОДНОГО агента на выбор. Если запустить второй раз на том же сервере,
#  предложит доставить второго рядом с первым.
#
#  Неинтерактивно:
#    AGENT=claude DOMAIN=ai.site.ru EMAIL=me@mail.ru bash -c "$(curl -fsSL ...)"
#    AGENT: claude | codex
# =============================================================================

set -Eeuo pipefail

VERSION="2.1.0"
PANEL_PORT="${PANEL_PORT:-3001}"
CLAUDE_PKG="@anthropic-ai/claude-code"
CODEX_PKG="@openai/codex"
PANEL_PKG="@cloudcli-ai/cloudcli"
NODE_MAJOR=22
LOG="/var/log/claude-server-install.log"
INFO_FILE="/root/claude-server-info.txt"
SERVICE="claude-panel"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
AGENT="${AGENT:-}"        # claude | codex
SITE_OK=0

# ---------- оформление ----------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; D=""; R=""; GRN=""; YLW=""; RED=""; CYN=""
fi

STEP_N=0
STEP_TOTAL=13

say()   { printf '%s\n' "$*"; }
step()  { STEP_N=$((STEP_N+1)); printf '\n%s[%s/%s]%s %s%s%s\n' "$D" "$STEP_N" "$STEP_TOTAL" "$R" "$B" "$*" "$R"; }
ok()    { printf '      %s✓%s %s\n' "$GRN" "$R" "$*"; }
info()  { printf '      %s·%s %s\n' "$D" "$R" "$*"; }
warn()  { printf '      %s!%s %s\n' "$YLW" "$R" "$*"; }
die()   { printf '\n%s✗ ОШИБКА:%s %s\n\n' "$RED" "$R" "$*" >&2; exit 1; }

on_err() {
  local code=$? line=${1:-?}
  printf '\n%s✗ Установка прервалась%s (строка %s, код %s)\n' "$RED" "$R" "$line" "$code" >&2
  printf '  Полный лог: %s\n' "$LOG" >&2
  printf '  Скиньте последние 40 строк лога в нейросеть, вам помогут:\n' >&2
  printf '    tail -40 %s\n\n' "$LOG" >&2
}
trap 'on_err $LINENO' ERR

run() { echo "+ $*" >>"$LOG" 2>&1; "$@" >>"$LOG" 2>&1; }

banner() {
cat <<'EOF'

  ┌───────────────────────────────────────────────┐
  │                                               │
  │      СВОЙ ИИ НА СВОЁМ СЕРВЕРЕ                 │
  │      Claude или ChatGPT Codex                 │
  │                                               │
  │      dmitriymarketing                         │
  │                                               │
  └───────────────────────────────────────────────┘
EOF
printf '  %sверсия установщика %s%s\n' "$D" "$VERSION" "$R"
}

agent_name() { case "$1" in claude) echo "Claude" ;; codex) echo "ChatGPT Codex" ;; esac; }

# =============================================================================
#  Что уже стоит на сервере
# =============================================================================
have_claude() { command -v claude >/dev/null 2>&1; }
have_codex()  { command -v codex  >/dev/null 2>&1; }
have_panel()  { command -v cloudcli >/dev/null 2>&1 && [ -f "/etc/systemd/system/${SERVICE}.service" ]; }

claude_logged_in() {
  have_claude && claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1
}
codex_logged_in() {
  have_codex && codex login status 2>/dev/null | head -1 | grep -qiE '^[[:space:]]*logged in'
}

domain_from_caddy() {
  [ -f /etc/caddy/Caddyfile ] || return 1
  grep -oE '^[a-z0-9][a-z0-9.-]*[a-z0-9] \{' /etc/caddy/Caddyfile 2>/dev/null | head -1 | tr -d ' {'
}

# =============================================================================
#  0. Проверки
# =============================================================================
preflight() {
  [ "$(id -u)" -eq 0 ] || die "Запустите от root. Подключитесь к серверу как: ssh root@ВАШ-IP"
  command -v apt-get >/dev/null 2>&1 || die "Нужен Ubuntu или Debian. На этом сервере другая система."

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) : ;;
      *) warn "Система ${PRETTY_NAME:-неизвестна}. Скрипт рассчитан на Ubuntu 24.04, возможны сбои." ;;
    esac
  fi

  case "$(uname -m)" in
    x86_64|aarch64|arm64) : ;;
    *) die "Процессор $(uname -m) не поддерживается." ;;
  esac

  mkdir -p "$(dirname "$LOG")"; : >"$LOG"; chmod 600 "$LOG"

  local mem_mb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  if [ "$mem_mb" -lt 1800 ]; then
    die "На сервере ${mem_mb} МБ памяти. Нужно минимум 2 ГБ, рекомендуется 4 ГБ."
  elif [ "$mem_mb" -lt 3600 ]; then
    warn "На сервере ${mem_mb} МБ памяти. Работать будет, но возможны подтормаживания."
  fi

  local free_gb
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge 5 ] || die "На диске меньше 5 ГБ свободного места."
}

# =============================================================================
#  1. Что ставим
# =============================================================================
ask_agent() {
  say ""
  say "  ${B}Какой ИИ будем ставить?${R}"
  say ""
  say "    ${B}1${R}  Claude          ${D}нужна подписка Claude Pro${R}"
  say "    ${B}2${R}  ChatGPT Codex   ${D}нужна подписка ChatGPT Plus${R}"
  say ""
  say "  ${D}Ставим одного. Второго при желании доставите потом, просто запустив${R}"
  say "  ${D}эту же команду ещё раз. Всё встанет на тот же сервер.${R}"
  say ""
  local c=""
  while [ -z "$AGENT" ]; do
    printf '  Ваш выбор [1/2]: '
    read -r c || true
    case "$(echo "${c:-}" | tr -d '[:space:]')" in
      1|claude|Claude) AGENT="claude" ;;
      2|codex|Codex|chatgpt) AGENT="codex" ;;
      *) warn "Введите 1 или 2" ;;
    esac
  done
}

ask_domain_email() {
  if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    say ""
    say "  ${B}Ещё два ответа, дальше всё сделаю сам.${R}"
    say ""
  fi

  while [ -z "$DOMAIN" ]; do
    printf '  Ваш домен (например ai.moysite.ru): '
    read -r DOMAIN || true
    DOMAIN="$(echo "${DOMAIN:-}" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##' | tr 'A-Z' 'a-z')"
    if ! echo "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
      warn "Это не похоже на домен. Пример правильного: ai.moysite.ru"
      DOMAIN=""
    fi
  done

  while [ -z "$EMAIL" ]; do
    printf '  Ваша почта (для сертификата, спама не будет): '
    read -r EMAIL || true
    EMAIL="$(echo "${EMAIL:-}" | tr -d '[:space:]')"
    if ! echo "$EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$'; then
      warn "Это не похоже на почту. Пример: me@mail.ru"
      EMAIL=""
    fi
  done

  say ""
  info "домен: ${B}${DOMAIN}${R}"
  info "почта: ${B}${EMAIL}${R}"
  info "ставим: ${B}$(agent_name "$AGENT")${R}"
}

# =============================================================================
#  2. Подкачка
# =============================================================================
setup_swap() {
  step "Настраиваю подкачку памяти"
  local mem_mb swap_kb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)

  if [ "${swap_kb:-0}" -gt 262144 ]; then ok "подкачка уже есть, пропускаю"; return; fi
  if [ "$mem_mb" -ge 7000 ]; then ok "памяти достаточно, подкачка не нужна"; return; fi

  if [ ! -f /swapfile ]; then
    run fallocate -l 2G /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    run mkswap /swapfile
  fi
  swapon /swapfile >>"$LOG" 2>&1 || true
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  ok "добавил 2 ГБ подкачки"
}

# =============================================================================
#  3. Система, Node, агент, панель
# =============================================================================
install_base() {
  step "Обновляю систему и ставлю базовые пакеты"
  export DEBIAN_FRONTEND=noninteractive
  run apt-get update
  run apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release apt-transport-https \
    debian-keyring debian-archive-keyring \
    ufw fail2ban dnsutils jq git \
    build-essential python3 make g++
  ok "базовые пакеты установлены"
}

install_node() {
  step "Ставлю Node.js ${NODE_MAJOR}"
  local have=""
  command -v node >/dev/null 2>&1 && have="$(node -v 2>/dev/null | tr -dc '0-9.' | cut -d. -f1)"
  if [ -n "$have" ] && [ "$have" -ge "$NODE_MAJOR" ] 2>/dev/null; then
    ok "уже стоит Node $(node -v)"; return
  fi
  run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
  run apt-get install -y nodejs
  command -v node >/dev/null 2>&1 || die "Node.js не установился. Смотрите $LOG"
  ok "Node $(node -v) установлен"
}

install_agent() {
  local a="$1"
  step "Ставлю $(agent_name "$a")"
  case "$a" in
    claude)
      run npm install -g --no-audit --no-fund "${CLAUDE_PKG}@latest"
      have_claude || die "Claude Code не установился. Смотрите $LOG"
      ok "Claude Code $(claude --version 2>/dev/null | head -1)"
      ;;
    codex)
      run npm install -g --no-audit --no-fund "${CODEX_PKG}@latest"
      have_codex || die "Codex не установился. Смотрите $LOG"
      ok "$(codex --version 2>/dev/null | head -1)"
      ;;
  esac
}

install_panel() {
  step "Ставлю веб-панель"
  info "это самая долгая часть, 2–4 минуты"
  run npm install -g --no-audit --no-fund "${PANEL_PKG}@latest"
  command -v cloudcli >/dev/null 2>&1 || die "Панель не установилась. Смотрите $LOG"
  ok "панель установлена"
}

# =============================================================================
#  4. Домен
# =============================================================================
public_ip() {
  local ip=""
  ip="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -4 -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -4 -fsS --max-time 8 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  [ -z "$ip" ] && ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
  echo "$ip"
}

resolve_domain() {
  local d="$1" r=""
  r="$(dig +short +time=3 +tries=1 @1.1.1.1 "$d" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  [ -z "$r" ] && r="$(dig +short +time=3 +tries=1 @8.8.8.8 "$d" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true)"
  echo "$r"
}

wait_dns() {
  step "Проверяю домен ${DOMAIN}"
  local myip resolved waited=0 interval=20
  myip="$(public_ip)"
  [ -n "$myip" ] || die "Не удалось определить IP этого сервера."
  info "IP этого сервера: ${B}${myip}${R}"

  while :; do
    resolved="$(resolve_domain "$DOMAIN")"
    if [ "$resolved" = "$myip" ]; then
      [ "$waited" -gt 0 ] && printf '\n'
      ok "домен смотрит на этот сервер"
      return
    fi

    if [ "$waited" -eq 0 ]; then
      if [ -z "$resolved" ]; then
        info "домен пока не отвечает, жду. Это нормально, ничего делать не надо"
      else
        warn "домен смотрит на ${resolved}, а нужно на ${myip}"
      fi
    fi

    if [ "$waited" -ge 3600 ]; then
      say ""
      warn "Жду уже час, домен так и не заработал."
      warn "Проверьте A-запись: имя ${DOMAIN}, значение ${myip}"
      printf '  Продолжить всё равно? [y/N]: '
      local a=""; read -r a || true
      case "${a:-n}" in y|Y|д|Д) warn "продолжаю без проверки"; return ;; *) die "Поправьте A-запись и запустите заново." ;; esac
    fi

    sleep "$interval"; waited=$((waited+interval))
    printf '\r      %s·%s жду домен... %s мин   ' "$D" "$R" "$((waited/60))"
  done
}

# =============================================================================
#  5. Панель как служба
# =============================================================================
# Панель разрешает создавать проекты только внутри своего "корня рабочих папок".
# По умолчанию это домашний каталог, а у root это /root, который она же сама
# считает системным и запрещает. Получается замкнутый круг: создать проект
# нельзя нигде. Поэтому явно назначаем отдельный каталог под проекты.
ensure_workspace() {
  mkdir -p "$WORKSPACE_DIR"
  mkdir -p "/etc/systemd/system/${SERVICE}.service.d"
  cat >"/etc/systemd/system/${SERVICE}.service.d/workspace.conf" <<EOF
[Service]
Environment=WORKSPACES_ROOT=${WORKSPACE_DIR}
EOF
  run systemctl daemon-reload
}

setup_service() {
  step "Настраиваю автозапуск панели"
  local bin; bin="$(command -v cloudcli)"
  mkdir -p /root/.claude /root/.codex

  cat >/etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=CloudCLI — веб-панель для Claude и Codex
Documentation=https://cloudcli.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=NODE_ENV=production
Environment=HOME=/root
Environment=SERVER_PORT=${PANEL_PORT}
Environment=WORKSPACES_ROOT=${WORKSPACE_DIR}
WorkingDirectory=/root
ExecStart=${bin} start
Restart=always
RestartSec=5
StandardOutput=append:/var/log/claude-panel.log
StandardError=append:/var/log/claude-panel.log

[Install]
WantedBy=multi-user.target
EOF

  ensure_workspace
  run systemctl enable ${SERVICE}
  systemctl restart ${SERVICE} >>"$LOG" 2>&1 || true

  local i=0
  until curl -fsS --max-time 3 "http://127.0.0.1:${PANEL_PORT}/api/auth/status" >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -gt 40 ] && die "Панель не поднялась. Смотрите: journalctl -u ${SERVICE} -n 50"
    sleep 2
  done
  ok "панель запущена и работает в фоне"
}

# =============================================================================
#  6. Caddy + HTTPS
# =============================================================================
setup_caddy() {
  step "Настраиваю адрес и HTTPS-сертификат"

  local busy=""
  busy="$(ss -ltnp 2>/dev/null | grep -E ':(80|443)[[:space:]]' | grep -v caddy || true)"
  if [ -n "$busy" ]; then
    warn "порты 80 или 443 уже кем-то заняты:"
    printf '%s\n' "$busy" | sed 's/^/        /'
    local s
    for s in nginx apache2 httpd lighttpd; do
      if systemctl is-active --quiet "$s" 2>/dev/null; then
        warn "останавливаю $s, он мешает Caddy"
        run systemctl disable --now "$s"
      fi
    done
  fi

  if ! command -v caddy >/dev/null 2>&1; then
    run bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    run bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list"
    run apt-get update
    run apt-get install -y caddy
  fi

  install -d -o caddy -g caddy -m 755 /var/log/caddy 2>/dev/null || mkdir -p /var/log/caddy

  mkdir -p /etc/caddy
  cat >/etc/caddy/Caddyfile <<EOF
{
	email ${EMAIL}
}

${DOMAIN} {
	encode zstd gzip

	reverse_proxy 127.0.0.1:${PANEL_PORT} {
		flush_interval -1
	}

	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "strict-origin-when-cross-origin"
	}

	log {
		output file /var/log/caddy/access.log
	}
}
EOF

  mkdir -p /etc/systemd/system/caddy.service.d
  cat >/etc/systemd/system/caddy.service.d/restart.conf <<'EOF'
[Service]
Restart=on-failure
RestartSec=5
EOF
  run systemctl daemon-reload

  caddy validate --config /etc/caddy/Caddyfile >>"$LOG" 2>&1 \
    || die "Caddyfile не прошёл проверку. Смотрите $LOG"

  # caddy validate работает от root и создаёт access.log как root:root 0600.
  # Служба крутится под пользователем caddy и после этого не может писать в лог.
  # Поэтому права выставляем ПОСЛЕ валидации.
  chown -R caddy:caddy /var/log/caddy 2>/dev/null || true
  chmod 755 /var/log/caddy 2>/dev/null || true
  [ -f /var/log/caddy/access.log ] && { chmod 644 /var/log/caddy/access.log 2>/dev/null || true; }

  if id caddy >/dev/null 2>&1; then
    if ! su -s /bin/sh -c 'test -w /var/log/caddy' caddy 2>/dev/null; then
      die "Пользователь caddy не может писать в /var/log/caddy.
  Выполните: chown -R caddy:caddy /var/log/caddy && chmod 755 /var/log/caddy"
    fi
  fi

  run systemctl enable caddy
  systemctl restart caddy >>"$LOG" 2>&1 || true

  local i=0
  while [ "$i" -lt 10 ]; do
    systemctl is-active --quiet caddy && break
    i=$((i+1)); sleep 2
  done

  if ! systemctl is-active --quiet caddy; then
    say ""
    printf '%s  Веб-сервер Caddy не запустился. Последние строки лога:%s\n\n' "$RED" "$R" >&2
    journalctl -u caddy -n 20 --no-pager 2>&1 | sed 's/^/      /' >&2
    say ""
    die "Без Caddy сайт открываться не будет. Скиньте строки выше в нейросеть, вам помогут."
  fi
  ok "веб-сервер запущен"
}

# =============================================================================
#  7. Защита
# =============================================================================
setup_security() {
  step "Включаю защиту сервера"
  run ufw --force reset
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow 22/tcp
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  run ufw --force enable
  ok "фаервол включён, наружу открыты только 22, 80 и 443"

  mkdir -p /etc/fail2ban
  cat >/etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
backend  = systemd
EOF
  run systemctl enable fail2ban
  systemctl restart fail2ban >>"$LOG" 2>&1 || warn "fail2ban не стартовал, не критично"
  ok "защита от подбора пароля включена"
}

# =============================================================================
#  8. Учётка в панели
# =============================================================================
PANEL_USER="admin"
PANEL_PASS=""

gen_password() {
  local raw
  raw="$(head -c 96 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')"
  raw="${raw:0:16}"
  echo "${raw:0:4}-${raw:4:4}-${raw:8:4}-${raw:12:4}"
}

setup_panel_user() {
  step "Создаю логин и пароль для панели"
  local status needs
  status="$(curl -fsS --max-time 5 "http://127.0.0.1:${PANEL_PORT}/api/auth/status" 2>/dev/null || echo '{}')"
  needs="$(echo "$status" | jq -r '.needsSetup // false' 2>/dev/null || echo false)"

  if [ "$needs" != "true" ]; then
    PANEL_PASS=""
    warn "учётка в панели уже создана раньше, оставляю как есть"
    [ -f "$INFO_FILE" ] && info "старый пароль лежит в ${INFO_FILE}" || info "забыли пароль? выполните: ai-password"
    return
  fi

  PANEL_PASS="$(gen_password)"
  local resp
  resp="$(curl -fsS --max-time 10 -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}" \
      "http://127.0.0.1:${PANEL_PORT}/api/auth/register" 2>/dev/null || echo '{}')"

  if [ "$(echo "$resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
    warn "не получилось создать учётку автоматически"
    warn "откройте панель в браузере и придумайте логин с паролем сами"
    PANEL_PASS=""
    return
  fi
  ok "учётка создана"
}

# =============================================================================
#  9. Вход в аккаунт агента
# =============================================================================
# Перенос входа с компьютера пользователя через scp.
transfer_login() {
  local src="$1" dst="$2" checkfn="$3" ip=""
  ip="$(public_ip)"
  mkdir -p "$(dirname "$dst")"

  local tries=0 a=""
  while [ "$tries" -lt 3 ]; do
    say ""
    say "  Откройте ${B}второе окно терминала у себя на компьютере${R}."
    say "  Не на сервере, а именно у себя. Выполните там одну команду:"
    say ""
    say "      ${CYN}scp ${src} root@${ip}:${dst}${R}"
    say ""
    say "  Она спросит пароль от сервера, тот же, что вы вводили при входе."
    say "  Когда отработает, вернитесь сюда."
    say ""
    printf '  Сделали? Нажмите Enter: '
    read -r a || true

    if [ -f "$dst" ]; then
      chmod 600 "$dst" 2>/dev/null || true
      if "$checkfn"; then ok "вход перенесён, VPN не понадобился"; return 0; fi
      warn "файл долетел, но вход не подтвердился"
    else
      warn "файла на сервере пока нет"
    fi

    tries=$((tries+1))
    [ "$tries" -ge 3 ] && break
    printf '  Попробовать ещё раз? [Enter — да, н — нет]: '
    a=""; read -r a || true
    case "${a:-}" in [нНnN]*) break ;; esac
  done

  warn "перенести не получилось"
  return 1
}

auth_agent() {
  local a="$1" name; name="$(agent_name "$a")"

  case "$a" in
    claude) claude_logged_in && { ok "${name} уже подключён"; return 0; } ;;
    codex)  codex_logged_in  && { ok "${name} уже подключён"; return 0; } ;;
  esac

  say ""
  say "  ${B}Подключаем аккаунт ${name}.${R} Это делается один раз. Два способа:"
  say ""
  say "    ${B}1${R}  Перенести вход с компьютера   ${D}VPN не нужен${R}"
  say "       ${D}подходит, если ${name} уже стоит у вас на компьютере${R}"
  say "    ${B}2${R}  Войти прямо здесь             ${D}нужен VPN на минуту${R}"
  say "    ${B}3${R}  Пропустить, подключу позже${R}"
  say ""
  local c=""
  printf '  Ваш выбор [1/2/3]: '
  read -r c || true

  case "${c:-1}" in
    2) browser_login "$a" ;;
    3) warn "${name} пока не подключён, потом выполните: ai-login" ; return 0 ;;
    *)
      # тильда собирается через переменную, чтобы её не раскрыл наш шелл:
      # раскрывать её должен шелл пользователя на его компьютере
      local HOME_MARK='~'
      case "$a" in
        claude) transfer_login "${HOME_MARK}/.claude/.credentials.json" "/root/.claude/.credentials.json" claude_logged_in || browser_login "$a" ;;
        codex)  transfer_login "${HOME_MARK}/.codex/auth.json"          "/root/.codex/auth.json"          codex_logged_in  || browser_login "$a" ;;
      esac
      ;;
  esac

  case "$a" in
    claude) claude_logged_in && ok "аккаунт ${name} подключён" || warn "${name} не подключён, потом выполните: ai-login" ;;
    codex)  codex_logged_in  && ok "аккаунт ${name} подключён" || warn "${name} не подключён, потом выполните: ai-login" ;;
  esac
  return 0
}

browser_login() {
  say ""
  say "  ${YLW}Включите VPN в браузере, сейчас появится ссылка.${R}"
  say ""
  case "$1" in
    claude) claude auth login --claudeai || warn "вход не завершён" ;;
    codex)  mkdir -p /root/.codex; codex login --device-auth || warn "вход не завершён" ;;
  esac
}

setup_agent_auth() {
  step "Подключаю ваш аккаунт"
  auth_agent "$AGENT"
  systemctl restart ${SERVICE} >>"$LOG" 2>&1 || true
}

# =============================================================================
#  10. Команды-помощники
# =============================================================================
install_helpers() {
  step "Ставлю команды-помощники"

  cat >/usr/local/bin/ai-status <<EOF
#!/usr/bin/env bash
export LC_ALL=C.UTF-8 2>/dev/null || true
D="\033[2m"; R="\033[0m"; G="\033[32m"; Y="\033[33m"; B="\033[1m"
DOMAIN="${DOMAIN}"
PORT="${PANEL_PORT}"
EOF
  cat >>/usr/local/bin/ai-status <<'EOF'

line() {
  local label="$1" pad="" n=$(( 26 - ${#1} ))
  [ "$n" -gt 0 ] && pad="$(printf '%*s' "$n" '')"
  printf "  %s%s %b\n" "$label" "$pad" "$2"
}
yn() { if [ "$1" = "0" ]; then printf "${G}работает${R}"; else printf "${Y}НЕ работает${R}"; fi; }

echo ""
printf "  ${B}Свой ИИ на сервере — состояние${R}\n"
echo "  ------------------------------------------------"

systemctl is-active --quiet claude-panel; line "Веб-панель" "$(yn $?)"
systemctl is-active --quiet caddy;        line "Веб-сервер (HTTPS)" "$(yn $?)"
systemctl is-active --quiet fail2ban;     line "Защита fail2ban" "$(yn $?)"

if command -v claude >/dev/null 2>&1; then
  if claude auth status --json 2>/dev/null | grep -q '"loggedIn": *true'; then
    line "Claude" "${G}подключён${R}"
  else
    line "Claude" "${Y}не подключён (ai-login)${R}"
  fi
else
  line "Claude" "${D}не установлен${R}"
fi

if command -v codex >/dev/null 2>&1; then
  if codex login status 2>/dev/null | head -1 | grep -qiE '^[[:space:]]*logged in'; then
    line "ChatGPT Codex" "${G}подключён${R}"
  else
    line "ChatGPT Codex" "${Y}не подключён (ai-login)${R}"
  fi
else
  line "ChatGPT Codex" "${D}не установлен${R}"
fi

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/" 2>/dev/null)
case "$CODE" in
  2*|3*|401|403) line "Адрес https://${DOMAIN}" "${G}открывается${R}" ;;
  *)             line "Адрес https://${DOMAIN}" "${Y}не отвечает (код ${CODE:-нет})${R}" ;;
esac

echo "  ------------------------------------------------"
line "Память" "$(free -h | awk '/Mem:/{print $3" из "$2}')"
line "Диск" "$(df -h / | awk 'NR==2{print $3" из "$2" (свободно "$4")"}')"

if ! systemctl is-active --quiet caddy; then
  echo ""
  printf "  ${Y}Веб-сервер лежит, поэтому сайт и не открывается.${R}\n"
  echo "  Частая причина: у пользователя caddy нет прав на свой лог."
  echo "    chown -R caddy:caddy /var/log/caddy && chmod 755 /var/log/caddy"
  echo "    systemctl restart caddy"
  echo "  Подробности: journalctl -u caddy -n 30 --no-pager"
fi

echo ""
echo "  Логи панели:  tail -50 /var/log/claude-panel.log"
echo "  Логи Caddy:   journalctl -u caddy -n 50"
echo ""
EOF

  cat >/usr/local/bin/ai-update <<'EOF'
#!/usr/bin/env bash
set -e
echo ""
echo "  Обновляю то, что установлено..."
command -v claude >/dev/null 2>&1 && npm install -g --no-audit --no-fund @anthropic-ai/claude-code@latest
command -v codex  >/dev/null 2>&1 && npm install -g --no-audit --no-fund @openai/codex@latest
npm install -g --no-audit --no-fund @cloudcli-ai/cloudcli@latest
systemctl restart claude-panel
sleep 3
echo ""
echo "  Готово."
ai-status
EOF

  cat >/usr/local/bin/ai-login <<'EOF'
#!/usr/bin/env bash
HAS_C=0; HAS_X=0
command -v claude >/dev/null 2>&1 && HAS_C=1
command -v codex  >/dev/null 2>&1 && HAS_X=1

if [ "$HAS_C" = "0" ] && [ "$HAS_X" = "0" ]; then
  echo ""; echo "  На сервере не установлен ни один ИИ."; echo ""; exit 1
fi

TARGET=""
if [ "$HAS_C" = "1" ] && [ "$HAS_X" = "1" ]; then
  echo ""
  echo "  В какой аккаунт входим?"
  echo "    1  Claude"
  echo "    2  ChatGPT Codex"
  echo ""
  printf "  Ваш выбор [1/2]: "
  read -r c
  case "$c" in 2) TARGET=codex ;; *) TARGET=claude ;; esac
elif [ "$HAS_C" = "1" ]; then TARGET=claude
else TARGET=codex
fi

IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null)
echo ""
if [ "$TARGET" = "claude" ]; then
  echo "  Способ без VPN: выполните у СЕБЯ на компьютере"
  echo "    scp ~/.claude/.credentials.json root@${IP}:/root/.claude/.credentials.json"
else
  echo "  Способ без VPN: выполните у СЕБЯ на компьютере"
  echo "    scp ~/.codex/auth.json root@${IP}:/root/.codex/auth.json"
fi
echo ""
printf "  Или войти здесь через браузер (нужен VPN)? [y/N]: "
read -r a
case "${a:-n}" in
  y|Y|д|Д)
    if [ "$TARGET" = "claude" ]; then claude auth login --claudeai
    else mkdir -p /root/.codex; codex login --device-auth; fi
    ;;
  *) echo "  Хорошо. После переноса файла выполните: systemctl restart claude-panel" ;;
esac
systemctl restart claude-panel 2>/dev/null
echo ""
ai-status
EOF

  cat >/usr/local/bin/ai-password <<EOF
#!/usr/bin/env bash
set -e
PORT="${PANEL_PORT}"
EOF
  cat >>/usr/local/bin/ai-password <<'EOF'
echo ""
echo "  Это сотрёт все учётки панели и создаст новую."
printf "  Продолжить? [y/N]: "
read -r a
case "${a:-n}" in y|Y|д|Д) ;; *) echo "  Отменено."; exit 0 ;; esac

systemctl stop claude-panel
sleep 2
rm -f /root/.cloudcli/auth.db
systemctl start claude-panel

READY=""
for i in $(seq 1 45); do
  S=$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/auth/status" 2>/dev/null || true)
  case "$S" in *'"needsSetup":true'*) READY=1; break ;; esac
  sleep 2
done
if [ -z "$READY" ]; then
  echo ""; echo "  Панель не сбросилась. Смотрите: journalctl -u claude-panel -n 30"; exit 1
fi

RAW=$(head -c 96 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')
RAW="${RAW:0:16}"
PASS="${RAW:0:4}-${RAW:4:4}-${RAW:8:4}-${RAW:12:4}"
RESP=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASS}\"}" \
  "http://127.0.0.1:${PORT}/api/auth/register" || echo '{}')

if echo "$RESP" | grep -q '"success":true'; then
  echo ""; echo "  Новый логин:  admin"; echo "  Новый пароль: ${PASS}"; echo ""
  sed -i "s/^  Пароль:.*/  Пароль: ${PASS}/" /root/claude-server-info.txt 2>/dev/null || true
else
  echo "  Не получилось. Откройте панель в браузере и создайте учётку вручную."
fi
EOF

  cat >/usr/local/bin/ai-uninstall <<'EOF'
#!/usr/bin/env bash
echo ""
echo "  Это удалит панель, всех ИИ, Caddy и все настройки."
printf "  Точно удалить? Напишите 'удалить': "
read -r a
[ "$a" = "удалить" ] || { echo "  Отменено."; exit 0; }

systemctl disable --now claude-panel 2>/dev/null || true
systemctl disable --now caddy 2>/dev/null || true
rm -f /etc/systemd/system/claude-panel.service
systemctl daemon-reload
npm uninstall -g @cloudcli-ai/cloudcli @anthropic-ai/claude-code @openai/codex 2>/dev/null || true
apt-get purge -y caddy 2>/dev/null || true
rm -f /etc/caddy/Caddyfile /root/claude-server-info.txt
rm -f /usr/local/bin/ai-status /usr/local/bin/ai-update /usr/local/bin/ai-login \
      /usr/local/bin/ai-password \
      /usr/local/bin/claude-status /usr/local/bin/claude-update \
      /usr/local/bin/claude-login /usr/local/bin/claude-reset-password /usr/local/bin/codex-login

echo ""
printf "  Удалить также ваши проекты и переписки? [y/N]: "
read -r b
case "${b:-n}" in y|Y|д|Д) rm -rf /root/.claude /root/.codex /root/.cloudcli; echo "  Удалено." ;; *) echo "  Оставил на месте." ;; esac

rm -f /usr/local/bin/ai-uninstall
echo ""
echo "  Готово. Сервер можно удалять у хостера."
echo ""
EOF

  chmod +x /usr/local/bin/ai-status /usr/local/bin/ai-update /usr/local/bin/ai-login \
           /usr/local/bin/ai-password /usr/local/bin/ai-uninstall

  # старые имена продолжают работать
  ln -sf /usr/local/bin/ai-status   /usr/local/bin/claude-status
  ln -sf /usr/local/bin/ai-update   /usr/local/bin/claude-update
  ln -sf /usr/local/bin/ai-login    /usr/local/bin/claude-login
  ln -sf /usr/local/bin/ai-login    /usr/local/bin/codex-login
  ln -sf /usr/local/bin/ai-password /usr/local/bin/claude-reset-password
  ln -sf /usr/local/bin/ai-uninstall /usr/local/bin/claude-uninstall

  ok "команды ai-status, ai-login, ai-update, ai-uninstall готовы"
}

# =============================================================================
#  11. Финальная проверка
# =============================================================================
verify_site() {
  step "Проверяю, что сайт реально открывается"
  info "жду выпуск сертификата, обычно 10–60 секунд"

  local i=0 code=""
  while [ "$i" -lt 40 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/" 2>/dev/null || true)"
    case "$code" in
      2*|3*|401|403) SITE_OK=1; ok "https://${DOMAIN} отвечает, сертификат выпущен"; return ;;
    esac
    i=$((i+1)); sleep 3
  done

  SITE_OK=0
  say ""
  warn "сайт https://${DOMAIN} пока не отвечает (код ${code:-нет ответа})"
  warn "всё остальное установлено и работает"
  say ""
  say "      Что проверить:"
  say "      1. Домен ${DOMAIN} должен указывать на IP $(public_ip)"
  say "      2. В панели хостера должны быть открыты входящие порты 80 и 443"
  say "      3. Иногда Let's Encrypt просто медленный, подождите 5 минут"
  say ""
  say "      Потом выполните ${CYN}ai-status${R}."
}

# =============================================================================
#  Итог
# =============================================================================
finish() {
  local pass_line old_pass=""
  if [ -n "${PANEL_PASS:-}" ]; then
    pass_line="  Пароль: ${PANEL_PASS}"
  else
    [ -f "$INFO_FILE" ] && old_pass="$(grep -m1 '^  Пароль: ' "$INFO_FILE" | sed 's/^  Пароль: //')"
    case "$old_pass" in
      ""|"тот, что вы задали раньше") pass_line="  Пароль: тот, что вы задали раньше" ;;
      *) pass_line="  Пароль: ${old_pass}" ;;
    esac
  fi

  local agents=""
  claude_logged_in && agents="Claude"
  codex_logged_in  && agents="${agents:+$agents и }ChatGPT Codex"
  [ -z "$agents" ] && agents="пока никто"

  {
    echo "Свой ИИ на своём сервере"
    echo "========================================"
    echo "  Адрес:  https://${DOMAIN}"
    echo "  Логин:  ${PANEL_USER}"
    echo "$pass_line"
    echo "  Подключено: ${agents}"
    echo "========================================"
    echo "Команды на сервере:"
    echo "  ai-status      проверить, всё ли работает"
    echo "  ai-login       подключить аккаунт Claude или Codex"
    echo "  ai-update      обновить до свежих версий"
    echo "  ai-password    сбросить пароль от панели"
    echo "  ai-uninstall   удалить всё"
    echo ""
    echo ""
    echo "Проекты создавайте внутри папки ${WORKSPACE_DIR}"
    echo "например ${WORKSPACE_DIR}/moy-proekt"
    echo ""
    echo "Чтобы доставить второго ИИ, просто запустите установщик ещё раз."
  } >"$INFO_FILE"
  chmod 600 "$INFO_FILE"

  local head_color head_text
  if [ "${SITE_OK:-0}" = "1" ]; then
    head_color="$GRN"; head_text="                    ВСЁ ГОТОВО                        "
  else
    head_color="$YLW"; head_text="        УСТАНОВЛЕНО, НО САЙТ ЕЩЁ НЕ ОТВЕЧАЕТ          "
  fi

  local other=""
  if have_claude && ! have_codex; then
    other=$'\n  '"${D}Хотите добавить ChatGPT Codex? Запустите эту же команду ещё раз.${R}"
  elif have_codex && ! have_claude; then
    other=$'\n  '"${D}Хотите добавить Claude? Запустите эту же команду ещё раз.${R}"
  fi

  cat <<EOF

${head_color}  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║${head_text}║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝${R}

  ${B}Адрес:${R}  ${CYN}https://${DOMAIN}${R}
  ${B}Логин:${R}  ${PANEL_USER}
  ${B}${pass_line#  }${R}

  ${B}Подключено:${R} ${agents}

  ${YLW}Сохраните пароль прямо сейчас.${R}
  Копия лежит на сервере в файле ${D}${INFO_FILE}${R}
${other}

  ${D}Команды на будущее:${R}
  ${D}ai-status${R}      проверить, всё ли работает
  ${D}ai-login${R}       подключить аккаунт
  ${D}ai-update${R}      обновить до свежих версий
  ${D}ai-password${R}    сбросить пароль от панели
  ${D}ai-uninstall${R}   удалить всё

  ${B}Первый проект:${R} в панели нажмите «Create New Project» и в поле
  Workspace Path впишите ${CYN}${WORKSPACE_DIR}/moy-proekt${R}
  ${D}Проекты должны лежать внутри ${WORKSPACE_DIR}, это папка для ваших файлов.${R}

  Откройте адрес в браузере и пользуйтесь. VPN не нужен.

EOF
}

# =============================================================================
#  Ветка: доставить второго ИИ на уже готовый сервер
# =============================================================================
add_agent_flow() {
  local missing=""
  if have_claude && have_codex; then
    say ""
    ok "На этом сервере уже стоят и Claude, и ChatGPT Codex"
    say ""
    say "  Ничего доставлять не нужно. Проверю, что всё работает."
    STEP_TOTAL=1
    verify_site
    finish
    exit 0
  fi

  if have_claude; then missing="codex"; else missing="claude"; fi

  say ""
  say "  ${B}На этом сервере уже стоит $(agent_name "$( [ "$missing" = "codex" ] && echo claude || echo codex )").${R}"
  say ""
  printf '  Добавить %s рядом? [y/N]: ' "$(agent_name "$missing")"
  local a=""; read -r a || true
  case "${a:-n}" in
    y|Y|д|Д|да) : ;;
    *)
      say ""
      say "  Хорошо, ничего не меняю. Проверю, что всё работает."
      STEP_TOTAL=1
      verify_site
      finish
      exit 0
      ;;
  esac

  AGENT="$missing"
  STEP_TOTAL=4

  ensure_workspace
  systemctl restart ${SERVICE} >>"$LOG" 2>&1 || true

  install_agent "$AGENT"
  setup_agent_auth
  install_helpers
  verify_site
  finish
  exit 0
}

# =============================================================================
main() {
  banner
  preflight

  if have_panel; then

    DOMAIN="${DOMAIN:-$(domain_from_caddy || true)}"
    if [ -z "$DOMAIN" ]; then
      warn "не смог прочитать домен из настроек Caddy"
      ask_domain_email
    else
      info "домен этого сервера: ${B}${DOMAIN}${R}"
    fi
    add_agent_flow
  fi

  ask_agent
  ask_domain_email

  setup_swap
  install_base
  install_node
  install_agent "$AGENT"
  install_panel
  wait_dns
  setup_service
  setup_caddy
  setup_security
  setup_panel_user
  install_helpers
  setup_agent_auth
  verify_site
  finish
}

main "$@"
