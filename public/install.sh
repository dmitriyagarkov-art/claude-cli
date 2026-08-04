#!/usr/bin/env bash
# =============================================================================
#  Claude на своём сервере — установщик
#  dmitriymarketing
#
#  Запускать НА СЕРВЕРЕ (Ubuntu 22.04 / 24.04) от root:
#    bash -c "$(curl -fsSL https://claude-server.vercel.app/install.sh)"
#
#  Неинтерактивный режим:
#    DOMAIN=claude.site.ru EMAIL=me@mail.ru bash -c "$(curl -fsSL .../install.sh)"
# =============================================================================

set -Eeuo pipefail

VERSION="1.0.0"
PANEL_PORT="${PANEL_PORT:-3001}"
CLAUDE_PKG="@anthropic-ai/claude-code"
PANEL_PKG="@cloudcli-ai/cloudcli"
NODE_MAJOR=22
LOG="/var/log/claude-server-install.log"
INFO_FILE="/root/claude-server-info.txt"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"

# ---------- оформление ----------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; D=""; R=""; GRN=""; YLW=""; RED=""; CYN=""
fi

STEP_N=0
STEP_TOTAL=12

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
  printf '  Скиньте последние 40 строк лога в Claude или ChatGPT, вам помогут:\n' >&2
  printf '    tail -40 %s\n\n' "$LOG" >&2
}
trap 'on_err $LINENO' ERR

run() { echo "+ $*" >>"$LOG" 2>&1; "$@" >>"$LOG" 2>&1; }

banner() {
cat <<'EOF'

  ┌───────────────────────────────────────────────┐
  │                                               │
  │      CLAUDE НА СВОЁМ СЕРВЕРЕ                  │
  │      установка одной командой                 │
  │                                               │
  │      dmitriymarketing                         │
  │                                               │
  └───────────────────────────────────────────────┘
EOF
printf '  %sверсия установщика %s%s\n' "$D" "$VERSION" "$R"
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
    *) die "Процессор $(uname -m) не поддерживается. Нужен обычный x86_64 сервер." ;;
  esac

  mkdir -p "$(dirname "$LOG")"
  : >"$LOG"
  chmod 600 "$LOG"

  local mem_mb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  if [ "$mem_mb" -lt 1800 ]; then
    die "На сервере ${mem_mb} МБ памяти. Нужно минимум 2 ГБ, рекомендуется 4 ГБ."
  elif [ "$mem_mb" -lt 3600 ]; then
    warn "На сервере ${mem_mb} МБ памяти. Работать будет, но возможны подтормаживания. Рекомендуется 4 ГБ."
  fi

  local free_gb
  free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge 5 ] || die "На диске меньше 5 ГБ свободного места."
}

# =============================================================================
#  1. Вопросы пользователю
# =============================================================================
ask_input() {
  if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    say ""
    say "  ${B}Мне нужны два ответа, дальше всё сделаю сам.${R}"
    say ""
  fi

  while [ -z "$DOMAIN" ]; do
    printf '  Ваш домен (например claude.moysite.ru): '
    read -r DOMAIN || true
    DOMAIN="$(echo "${DOMAIN:-}" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/.*$##' | tr 'A-Z' 'a-z')"
    if ! echo "$DOMAIN" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
      warn "Это не похоже на домен. Пример правильного: claude.moysite.ru"
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
}

# =============================================================================
#  2. Подкачка (swap)
# =============================================================================
setup_swap() {
  step "Настраиваю подкачку памяти"
  local mem_mb swap_kb
  mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)

  if [ "${swap_kb:-0}" -gt 262144 ]; then
    ok "подкачка уже есть, пропускаю"
    return
  fi
  if [ "$mem_mb" -ge 7000 ]; then
    ok "памяти достаточно, подкачка не нужна"
    return
  fi

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
#  3. Система и зависимости
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
    ok "уже стоит Node $(node -v)"
    return
  fi
  run bash -c "curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -"
  run apt-get install -y nodejs
  command -v node >/dev/null 2>&1 || die "Node.js не установился. Смотрите $LOG"
  ok "Node $(node -v) установлен"
}

install_claude() {
  step "Ставлю Claude Code"
  run npm install -g --no-audit --no-fund "$CLAUDE_PKG@latest"
  command -v claude >/dev/null 2>&1 || die "Claude Code не установился. Смотрите $LOG"
  ok "Claude Code $(claude --version 2>/dev/null | head -1)"
}

install_panel() {
  step "Ставлю веб-панель"
  info "это самая долгая часть, 2–4 минуты"
  run npm install -g --no-audit --no-fund "$PANEL_PKG@latest"
  command -v cloudcli >/dev/null 2>&1 || die "Панель не установилась. Смотрите $LOG"
  ok "панель установлена"
}

# =============================================================================
#  4. Ожидание домена
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
  [ -n "$myip" ] || die "Не удалось определить IP этого сервера. Проверьте интернет на сервере."
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
        info "жду, вдруг запись ещё расходится по интернету"
      fi
    fi

    if [ "$waited" -ge 3600 ]; then
      say ""
      warn "Жду уже час, а домен так и не заработал."
      warn "Проверьте A-запись у регистратора: имя ${DOMAIN}, значение ${myip}"
      printf '  Продолжить всё равно (сертификат может не выпуститься)? [y/N]: '
      local a=""; read -r a || true
      case "${a:-n}" in y|Y|д|Д) warn "продолжаю без проверки домена"; return ;; *) die "Установка остановлена. Поправьте A-запись и запустите команду заново." ;; esac
    fi

    sleep "$interval"
    waited=$((waited+interval))
    printf '\r      %s·%s жду домен... %s мин   ' "$D" "$R" "$((waited/60))"
  done
}

# =============================================================================
#  5. Панель как служба
# =============================================================================
setup_service() {
  step "Настраиваю автозапуск панели"
  local bin
  bin="$(command -v cloudcli)"

  mkdir -p /root/.claude /root/projects

  cat >/etc/systemd/system/claude-panel.service <<EOF
[Unit]
Description=CloudCLI — веб-панель Claude Code
Documentation=https://cloudcli.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=NODE_ENV=production
Environment=HOME=/root
Environment=SERVER_PORT=${PANEL_PORT}
WorkingDirectory=/root
ExecStart=${bin} start
Restart=always
RestartSec=5
StandardOutput=append:/var/log/claude-panel.log
StandardError=append:/var/log/claude-panel.log

[Install]
WantedBy=multi-user.target
EOF

  run systemctl daemon-reload
  run systemctl enable claude-panel
  systemctl restart claude-panel >>"$LOG" 2>&1 || true

  local i=0
  until curl -fsS --max-time 3 "http://127.0.0.1:${PANEL_PORT}/api/auth/status" >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -gt 40 ] && die "Панель не поднялась. Смотрите: journalctl -u claude-panel -n 50"
    sleep 2
  done
  ok "панель запущена и работает в фоне"
}

# =============================================================================
#  6. Caddy + HTTPS
# =============================================================================
setup_caddy() {
  step "Настраиваю адрес и HTTPS-сертификат"

  if ! command -v caddy >/dev/null 2>&1; then
    run bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg"
    run bash -c "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list"
    run apt-get update
    run apt-get install -y caddy
  fi

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

  mkdir -p /var/log/caddy
  chown -R caddy:caddy /var/log/caddy 2>/dev/null || true

  run systemctl enable caddy
  caddy validate --config /etc/caddy/Caddyfile >>"$LOG" 2>&1 || die "Caddyfile не прошёл проверку. Смотрите $LOG"
  run systemctl restart caddy
  ok "веб-сервер настроен"

  info "жду выпуск сертификата, обычно 10–60 секунд"
  local i=0 code=""
  while [ "$i" -lt 60 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://${DOMAIN}/" 2>/dev/null || true)"
    case "$code" in 2*|3*|401|403) ok "сертификат выпущен, https работает"; return ;; esac
    i=$((i+1)); sleep 3
  done
  warn "сертификат ещё не выпустился. Обычно догоняет за 2–5 минут, просто подождите и обновите страницу."
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
gen_password() {
  # без пайпа в head: иначе tr ловит SIGPIPE и падает под pipefail
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
    PANEL_USER="admin"
    PANEL_PASS=""
    warn "учётка в панели уже создана раньше, оставляю как есть"
    if [ -f "$INFO_FILE" ]; then
      info "старый пароль лежит в ${INFO_FILE}"
    else
      info "если забыли пароль, выполните: claude-reset-password"
    fi
    return
  fi

  PANEL_USER="admin"
  PANEL_PASS="$(gen_password)"

  local resp
  resp="$(curl -fsS --max-time 10 -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"username\":\"${PANEL_USER}\",\"password\":\"${PANEL_PASS}\"}" \
      "http://127.0.0.1:${PANEL_PORT}/api/auth/register" 2>/dev/null || echo '{}')"

  if [ "$(echo "$resp" | jq -r '.success // false' 2>/dev/null)" != "true" ]; then
    warn "не получилось создать учётку автоматически"
    warn "ничего страшного: откройте панель в браузере и придумайте логин с паролем сами"
    PANEL_PASS=""
    return
  fi
  ok "учётка создана"
}

# =============================================================================
#  9. Подключение аккаунта Claude
# =============================================================================
claude_logged_in() {
  claude auth status --json 2>/dev/null | jq -e '.loggedIn == true' >/dev/null 2>&1
}

import_credentials() {
  say ""
  say "  На своём компьютере выполните в терминале эту команду"
  say "  и скопируйте ${B}весь${R} вывод:"
  say ""
  say "      ${CYN}cat ~/.claude/.credentials.json${R}"
  say ""
  say "  Вставьте сюда и нажмите Enter ${B}два раза${R}:"
  say ""

  local line buf=""
  while IFS= read -r line; do
    [ -z "$line" ] && [ -n "$buf" ] && break
    [ -z "$line" ] && continue
    buf="${buf}${line}"
    if echo "$buf" | jq -e . >/dev/null 2>&1; then break; fi
  done

  if ! echo "$buf" | jq -e . >/dev/null 2>&1; then
    warn "это не похоже на содержимое файла, пропускаю"
    return 1
  fi
  if ! echo "$buf" | jq -e '.claudeAiOauth // .accessToken // .access_token' >/dev/null 2>&1; then
    warn "файл прочитался, но данных для входа в нём нет, пропускаю"
    return 1
  fi

  mkdir -p /root/.claude
  printf '%s' "$buf" >/root/.claude/.credentials.json
  chmod 600 /root/.claude/.credentials.json

  if claude_logged_in; then
    ok "аккаунт подключён, VPN не понадобился"
    return 0
  fi
  warn "данные записал, но проверка входа не прошла. Попробуйте вариант 1."
  return 1
}

setup_claude_auth() {
  step "Подключаю ваш аккаунт Claude"

  if claude_logged_in; then
    ok "аккаунт уже подключён"
    return
  fi

  say ""
  say "  Осталось сказать серверу, каким аккаунтом Claude вы пользуетесь."
  say "  Это делается ${B}один раз${R}. Два способа:"
  say ""
  say "    ${B}1${R}  Войти прямо сейчас. Сервер даст ссылку, вы откроете её"
  say "       в браузере и вставите код обратно."
  say "       ${D}Нужен включённый VPN на одну минуту.${R}"
  say ""
  say "    ${B}2${R}  Перенести вход с вашего компьютера."
  say "       ${D}Подходит, если Claude Code уже стоит у вас на компьютере.${R}"
  say "       ${D}VPN не нужен вообще.${R}"
  say ""
  say "    ${B}3${R}  Пропустить, подключу позже командой ${CYN}claude-login${R}"
  say ""

  local choice=""
  printf '  Ваш выбор [1/2/3]: '
  read -r choice || true

  case "${choice:-1}" in
    2)
      import_credentials || {
        say ""
        say "  Пробуем первый способ."
        claude auth login --claudeai || warn "вход не завершён, потом выполните: claude-login"
      }
      ;;
    3)
      warn "пропускаю. Панель откроется, но Claude отвечать не будет"
      info "когда будете готовы, выполните на сервере: ${CYN}claude-login${R}"
      ;;
    *)
      say ""
      say "  ${YLW}Включите VPN в браузере, дальше откроется ссылка.${R}"
      say ""
      claude auth login --claudeai || warn "вход не завершён, потом выполните: claude-login"
      ;;
  esac

  if claude_logged_in; then
    ok "аккаунт Claude подключён"
    systemctl restart claude-panel >>"$LOG" 2>&1 || true
  fi
}

# =============================================================================
#  10. Команды-помощники
# =============================================================================
install_helpers() {
  step "Ставлю команды-помощники"

  cat >/usr/local/bin/claude-status <<EOF
#!/usr/bin/env bash
export LC_ALL=C.UTF-8 2>/dev/null || true
D="\033[2m"; R="\033[0m"; G="\033[32m"; Y="\033[33m"; B="\033[1m"
DOMAIN="${DOMAIN}"
PORT="${PANEL_PORT}"
EOF
  cat >>/usr/local/bin/claude-status <<'EOF'

# выравниваем по символам, а не по байтам: кириллица весит 2 байта
line() {
  local label="$1" pad="" n=$(( 26 - ${#1} ))
  [ "$n" -gt 0 ] && pad="$(printf '%*s' "$n" '')"
  printf "  %s%s %b\n" "$label" "$pad" "$2"
}
yn() { if [ "$1" = "0" ]; then printf "${G}работает${R}"; else printf "${Y}НЕ работает${R}"; fi; }

echo ""
printf "  ${B}Claude на своём сервере — состояние${R}\n"
echo "  ------------------------------------------------"

systemctl is-active --quiet claude-panel; line "Веб-панель" "$(yn $?)"
systemctl is-active --quiet caddy;        line "Веб-сервер (HTTPS)" "$(yn $?)"
systemctl is-active --quiet fail2ban;     line "Защита fail2ban" "$(yn $?)"

if claude auth status --json 2>/dev/null | grep -q '"loggedIn": *true'; then
  line "Аккаунт Claude" "${G}подключён${R}"
else
  line "Аккаунт Claude" "${Y}НЕ подключён — выполните claude-login${R}"
fi

CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "https://${DOMAIN}/" 2>/dev/null)
case "$CODE" in
  2*|3*|401|403) line "Адрес https://${DOMAIN}" "${G}открывается${R}" ;;
  *)             line "Адрес https://${DOMAIN}" "${Y}не отвечает (код ${CODE:-нет})${R}" ;;
esac

echo "  ------------------------------------------------"
line "Claude Code" "$(claude --version 2>/dev/null | head -1)"
line "Панель" "$(cloudcli version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
line "Память" "$(free -h | awk '/Mem:/{print $3" из "$2}')"
line "Диск" "$(df -h / | awk 'NR==2{print $3" из "$2" (свободно "$4")"}')"
echo ""
echo "  Логи панели:  journalctl -u claude-panel -n 50"
echo "  Логи Caddy:   journalctl -u caddy -n 50"
echo ""
EOF

  cat >/usr/local/bin/claude-update <<'EOF'
#!/usr/bin/env bash
set -e
echo ""
echo "  Обновляю Claude Code и панель..."
npm install -g --no-audit --no-fund @anthropic-ai/claude-code@latest
npm install -g --no-audit --no-fund @cloudcli-ai/cloudcli@latest
systemctl restart claude-panel
sleep 3
echo ""
echo "  Готово."
claude-status
EOF

  cat >/usr/local/bin/claude-login <<'EOF'
#!/usr/bin/env bash
echo ""
echo "  Сейчас откроется ссылка для входа в аккаунт Claude."
echo "  Включите VPN в браузере, войдите и вставьте код обратно сюда."
echo ""
claude auth login --claudeai
if claude auth status --json 2>/dev/null | grep -q '"loggedIn": *true'; then
  systemctl restart claude-panel
  echo ""
  echo "  Аккаунт подключён. Панель перезапущена."
else
  echo ""
  echo "  Вход не завершён. Попробуйте ещё раз."
fi
echo ""
EOF

  cat >/usr/local/bin/claude-reset-password <<EOF
#!/usr/bin/env bash
set -e
PORT="${PANEL_PORT}"
EOF
  cat >>/usr/local/bin/claude-reset-password <<'EOF'
echo ""
echo "  Это сотрёт все учётки панели и создаст новую."
printf "  Продолжить? [y/N]: "
read -r a
case "${a:-n}" in y|Y|д|Д) ;; *) echo "  Отменено."; exit 0 ;; esac

systemctl stop claude-panel
sleep 2
rm -f /root/.cloudcli/auth.db
systemctl start claude-panel

# ждём, пока панель поднимется И отдаст needsSetup=true
READY=""
for i in $(seq 1 45); do
  S=$(curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/auth/status" 2>/dev/null || true)
  case "$S" in *'"needsSetup":true'*) READY=1; break ;; esac
  sleep 2
done
if [ -z "$READY" ]; then
  echo ""
  echo "  Панель не сбросилась. Проверьте: journalctl -u claude-panel -n 30"
  exit 1
fi

RAW=$(head -c 96 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-HJ-NP-Za-km-z2-9')
RAW="${RAW:0:16}"
PASS="${RAW:0:4}-${RAW:4:4}-${RAW:8:4}-${RAW:12:4}"
RESP=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${PASS}\"}" \
  "http://127.0.0.1:${PORT}/api/auth/register" || echo '{}')

if echo "$RESP" | grep -q '"success":true'; then
  echo ""
  echo "  Новый логин:  admin"
  echo "  Новый пароль: ${PASS}"
  echo ""
  sed -i "s/^  Пароль:.*/  Пароль: ${PASS}/" /root/claude-server-info.txt 2>/dev/null || true
else
  echo "  Не получилось. Откройте панель в браузере и создайте учётку вручную."
fi
EOF

  cat >/usr/local/bin/claude-uninstall <<'EOF'
#!/usr/bin/env bash
echo ""
echo "  Это удалит панель, Claude Code, Caddy и все настройки."
printf "  Точно удалить? Напишите 'удалить': "
read -r a
[ "$a" = "удалить" ] || { echo "  Отменено."; exit 0; }

systemctl disable --now claude-panel 2>/dev/null || true
systemctl disable --now caddy 2>/dev/null || true
rm -f /etc/systemd/system/claude-panel.service
systemctl daemon-reload
npm uninstall -g @cloudcli-ai/cloudcli @anthropic-ai/claude-code 2>/dev/null || true
apt-get purge -y caddy 2>/dev/null || true
rm -f /etc/caddy/Caddyfile /root/claude-server-info.txt
rm -f /usr/local/bin/claude-status /usr/local/bin/claude-update /usr/local/bin/claude-login /usr/local/bin/claude-reset-password

echo ""
printf "  Удалить также ваши проекты и переписки (/root/.claude, /root/.cloudcli)? [y/N]: "
read -r b
case "${b:-n}" in y|Y|д|Д) rm -rf /root/.claude /root/.cloudcli; echo "  Удалено." ;; *) echo "  Оставил на месте." ;; esac

rm -f /usr/local/bin/claude-uninstall
echo ""
echo "  Готово. Сервер можно удалять у хостера."
echo ""
EOF

  chmod +x /usr/local/bin/claude-status /usr/local/bin/claude-update \
           /usr/local/bin/claude-login /usr/local/bin/claude-uninstall \
           /usr/local/bin/claude-reset-password
  ok "команды claude-status, claude-update, claude-login, claude-uninstall готовы"
}

# =============================================================================
#  Итог
# =============================================================================
finish() {
  local pass_line old_pass=""
  if [ -n "${PANEL_PASS:-}" ]; then
    pass_line="  Пароль: ${PANEL_PASS}"
  else
    # повторный запуск: не затираем ранее сохранённый пароль
    [ -f "$INFO_FILE" ] && old_pass="$(grep -m1 '^  Пароль: ' "$INFO_FILE" | sed 's/^  Пароль: //')"
    case "$old_pass" in
      ""|"тот, что вы задали раньше") pass_line="  Пароль: тот, что вы задали раньше" ;;
      *) pass_line="  Пароль: ${old_pass}" ;;
    esac
  fi

  {
    echo "Claude на своём сервере"
    echo "========================================"
    echo "  Адрес:  https://${DOMAIN}"
    echo "  Логин:  ${PANEL_USER:-admin}"
    echo "$pass_line"
    echo "========================================"
    echo "Команды на сервере:"
    echo "  claude-status          проверить, всё ли работает"
    echo "  claude-update          обновить до свежих версий"
    echo "  claude-login           подключить аккаунт Claude"
    echo "  claude-reset-password  сбросить пароль от панели"
    echo "  claude-uninstall       удалить всё"
  } >"$INFO_FILE"
  chmod 600 "$INFO_FILE"

  local auth_note=""
  claude_logged_in || auth_note=$'\n  '"${YLW}Аккаунт Claude пока не подключён.${R}"$'\n  Выполните на сервере: '"${CYN}claude-login${R}"

  cat <<EOF

${GRN}  ╔══════════════════════════════════════════════════════╗
  ║                                                      ║
  ║                    ВСЁ ГОТОВО                        ║
  ║                                                      ║
  ╚══════════════════════════════════════════════════════╝${R}

  ${B}Адрес:${R}  ${CYN}https://${DOMAIN}${R}
  ${B}Логин:${R}  ${PANEL_USER:-admin}
  ${B}${pass_line#  }${R}

  ${YLW}Сохраните пароль прямо сейчас.${R}
  Копия лежит на сервере в файле ${D}${INFO_FILE}${R}
${auth_note}

  ${D}Команды на будущее:${R}
  ${D}claude-status${R}          проверить, всё ли работает
  ${D}claude-update${R}          обновить до свежих версий
  ${D}claude-login${R}           подключить аккаунт Claude
  ${D}claude-reset-password${R}  сбросить пароль от панели
  ${D}claude-uninstall${R}       удалить всё

  Откройте адрес в браузере и пользуйтесь. VPN не нужен.

EOF
}

# =============================================================================
main() {
  banner
  preflight
  ask_input
  setup_swap
  install_base
  install_node
  install_claude
  install_panel
  wait_dns
  setup_service
  setup_caddy
  setup_security
  setup_panel_user
  install_helpers
  setup_claude_auth
  finish
}

main "$@"
