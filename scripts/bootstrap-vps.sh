#!/usr/bin/env bash
# bootstrap-vps.sh — идемпотентная установка OpenClaw на свежий Ubuntu/Debian VPS.
# Запускается из CI (GitHub Actions) после ssh. Можно запускать повторно — всё чинит на месте.
#
# Требуется .env в текущей директории (это директория клона репо Elena).

set -euo pipefail

REPO_DIR="${REPO_DIR:-$PWD}"
UPSTREAM_DIR="${UPSTREAM_DIR:-/opt/openclaw}"

log() { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$REPO_DIR/.env" ]] || die "Нет $REPO_DIR/.env — деплой должен его положить."

# shellcheck disable=SC1091
set -a; . "$REPO_DIR/.env"; set +a

# --- 1. Docker ---
if ! command -v docker >/dev/null; then
  log "Устанавливаю Docker"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates git
  curl -fsSL https://get.docker.com | sh
fi
docker compose version >/dev/null || die "docker compose недоступен"

# --- 2. Upstream openclaw репо ---
if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
  log "Клонирую openclaw/openclaw в $UPSTREAM_DIR"
  git clone --depth 1 https://github.com/openclaw/openclaw.git "$UPSTREAM_DIR"
else
  log "Обновляю openclaw upstream"
  git -C "$UPSTREAM_DIR" fetch --depth 1 origin main
  git -C "$UPSTREAM_DIR" reset --hard origin/main
fi

# --- 3. Persistent dirs ---
mkdir -p "${OPENCLAW_CONFIG_DIR:-/root/.openclaw}/workspace"
chmod 700 "${OPENCLAW_CONFIG_DIR:-/root/.openclaw}"
chown -R 1000:1000 "${OPENCLAW_CONFIG_DIR:-/root/.openclaw}"

# --- 4. Стабильные секреты: храним вне репо, не перегенерируем при каждом деплое ---
SECRETS_DIR="${OPENCLAW_CONFIG_DIR:-/root/.openclaw}"
SECRETS_FILE="$SECRETS_DIR/.elena-secrets.env"
mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"
touch "$SECRETS_FILE"
chmod 600 "$SECRETS_FILE"

ensure_secret() {
  local key="$1"
  local current="${!key:-}"
  # из CI секрет может прийти заданным — тогда сохраняем его
  if [[ -n "$current" ]]; then
    if grep -q "^$key=" "$SECRETS_FILE"; then
      sed -i "s|^$key=.*|$key=$current|" "$SECRETS_FILE"
    else
      printf '%s=%s\n' "$key" "$current" >> "$SECRETS_FILE"
    fi
    return
  fi
  # из CI пусто — берём из локального файла, иначе генерим
  if grep -q "^$key=" "$SECRETS_FILE"; then
    current=$(grep "^$key=" "$SECRETS_FILE" | tail -1 | cut -d= -f2-)
    log "Читаю $key из $SECRETS_FILE"
  else
    current="$(openssl rand -hex 32)"
    log "Генерирую $key (первый раз)"
    printf '%s=%s\n' "$key" "$current" >> "$SECRETS_FILE"
  fi
  export "$key"="$current"
}
ensure_secret OPENCLAW_GATEWAY_TOKEN
ensure_secret GOG_KEYRING_PASSWORD

# подставить актуальные значения в .env (для setup.sh)
for key in OPENCLAW_GATEWAY_TOKEN GOG_KEYRING_PASSWORD; do
  if grep -q "^$key=" "$REPO_DIR/.env"; then
    sed -i "s|^$key=.*|$key=${!key}|" "$REPO_DIR/.env"
  else
    printf '%s=%s\n' "$key" "${!key}" >> "$REPO_DIR/.env"
  fi
done

# --- 4.5 Firewall: блокируем порт gateway от внешних интерфейсов ---
# Снаружи доступ только через 80/443 (Caddy), gateway открыт только через docker bridge.
GW_PORT_FW="${OPENCLAW_GATEWAY_PORT:-18789}"
if command -v iptables >/dev/null; then
  # очищаем старое правило если было
  iptables -D DOCKER-USER -p tcp --dport "$GW_PORT_FW" -i eth0 -j DROP 2>/dev/null || true
  iptables -I DOCKER-USER -p tcp --dport "$GW_PORT_FW" -i eth0 -j DROP 2>/dev/null || true
  # на случай если интерфейс называется иначе
  EXT_IF=$(ip route | awk '/^default/ {print $5; exit}')
  if [[ -n "$EXT_IF" && "$EXT_IF" != "eth0" ]]; then
    iptables -D DOCKER-USER -p tcp --dport "$GW_PORT_FW" -i "$EXT_IF" -j DROP 2>/dev/null || true
    iptables -I DOCKER-USER -p tcp --dport "$GW_PORT_FW" -i "$EXT_IF" -j DROP 2>/dev/null || true
  fi
  log "Firewall: порт $GW_PORT_FW заблокирован снаружи (DOCKER-USER)"
fi

# --- 5. Поднять OpenClaw через официальный setup.sh ---

# Сначала определим публичный IP/домены чтобы пробросить allowedOrigins в setup.sh.
# Caddy и доменная конфигурация будут позже, но allowedOrigins нужен setup.sh уже сейчас.
if [[ -z "${DOMAIN:-}" ]]; then
  PUB_IP=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null \
        || curl -fsS -m 5 https://ifconfig.me 2>/dev/null \
        || hostname -I | awk '{print $1}')
  if [[ -n "$PUB_IP" ]]; then
    DOMAIN="${PUB_IP//./-}.sslip.io"
    DOMAIN_ALT="${PUB_IP//./-}.nip.io"
    log "Автоматические домены: $DOMAIN + $DOMAIN_ALT"
    export DOMAIN DOMAIN_ALT
    for k in DOMAIN DOMAIN_ALT; do
      v="${!k}"
      if grep -q "^$k=" "$REPO_DIR/.env"; then
        sed -i "s|^$k=.*|$k=$v|" "$REPO_DIR/.env"
      else
        printf '%s=%s\n' "$k" "$v" >> "$REPO_DIR/.env"
      fi
    done
  fi
fi

# Собираем список разрешённых origin для Control UI (HTTPS-домены + localhost для отладки)
ORIGINS_JSON='['
for d in "${DOMAIN:-}" "${DOMAIN_ALT:-}"; do
  [[ -z "$d" ]] && continue
  ORIGINS_JSON+="\"https://$d\","
done
ORIGINS_JSON+='"http://localhost:18789"]'
export OPENCLAW_GATEWAY_CONTROLUI_ALLOWEDORIGINS="$ORIGINS_JSON"
log "AllowedOrigins для Control UI: $ORIGINS_JSON"

log "Запускаю официальный setup.sh с OPENCLAW_IMAGE=$OPENCLAW_IMAGE"
cp "$REPO_DIR/.env" "$UPSTREAM_DIR/.env"
(
  cd "$UPSTREAM_DIR"
  export OPENCLAW_IMAGE OPENCLAW_GATEWAY_PORT OPENCLAW_GATEWAY_BIND \
         OPENCLAW_CONFIG_DIR OPENCLAW_WORKSPACE_DIR OPENCLAW_TZ \
         OPENCLAW_GATEWAY_TOKEN GOG_KEYRING_PASSWORD \
         OPENCLAW_GATEWAY_CONTROLUI_ALLOWEDORIGINS \
         OPENCLAW_SKIP_ONBOARDING="${OPENCLAW_SKIP_ONBOARDING:-0}"
  bash scripts/docker/setup.sh
) || log "WARN: setup.sh завершился с ошибкой, но gateway-контейнер обычно остаётся работать"

# --- 6. Caddy reverse proxy ---
# (DOMAIN/DOMAIN_ALT уже определены выше, до setup.sh)

if [[ -z "${ACME_EMAIL:-}" ]]; then
  export ACME_EMAIL="admin@${DOMAIN:-localhost}"
fi

GW_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"

if [[ -n "${DOMAIN:-}" ]]; then
  log "Поднимаю Caddy для $DOMAIN"
  (
    cd "$REPO_DIR"
    for i in 1 2 3; do
      if docker compose pull caddy; then break; fi
      log "Попытка pull $i/3 не удалась, жду 10 сек..."
      sleep 10
    done
    docker compose down --remove-orphans 2>/dev/null || true
    docker compose up -d --force-recreate caddy
  ) || log "WARN: Caddy не стартовал — посмотри 'docker logs <caddy-container>'"
else
  log "Не удалось определить публичный IP — Caddy не поднимаю"
fi

# --- 7. Healthcheck ---
log "Проверяю gateway"
sleep 3
if curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/healthz" >/dev/null 2>&1 \
  || curl -fsS -m 5 "http://127.0.0.1:$GW_PORT/" >/dev/null 2>&1; then
  log "Gateway отвечает на 127.0.0.1:$GW_PORT"
else
  log "WARN: gateway пока не отвечает на 127.0.0.1:$GW_PORT"
fi

for d in "${DOMAIN:-}" "${DOMAIN_ALT:-}"; do
  [[ -z "$d" ]] && continue
  if curl -ksS -m 10 "https://$d/" >/dev/null 2>&1; then
    log "HTTPS на https://$d работает"
  else
    log "WARN: https://$d ещё не отвечает (Caddy может выпускать сертификат, подожди 30-60 сек)"
  fi
done

# --- 8. Вытащить актуальный gateway token из onboarded конфига и положить в .env ---
TOKEN_FROM_CONFIG=""
if command -v jq >/dev/null 2>&1 && [[ -f "${OPENCLAW_CONFIG_DIR:-/root/.openclaw}/openclaw.json" ]]; then
  TOKEN_FROM_CONFIG=$(jq -r '.gateway.auth.token // empty' "${OPENCLAW_CONFIG_DIR:-/root/.openclaw}/openclaw.json" 2>/dev/null || true)
fi
[[ -n "$TOKEN_FROM_CONFIG" ]] && export OPENCLAW_GATEWAY_TOKEN="$TOKEN_FROM_CONFIG"

# Печатаем итог в формате, который deploy.yml положит в GitHub job summary.
echo "::notice::OpenClaw gateway token: ${OPENCLAW_GATEWAY_TOKEN:-<unknown>}"
echo "::notice::Gateway port: $GW_PORT"
[[ -n "${DOMAIN:-}" ]] && echo "::notice::HTTPS URL: https://$DOMAIN"
[[ -n "${DOMAIN_ALT:-}" ]] && echo "::notice::HTTPS URL (alt): https://$DOMAIN_ALT"

log "Готово."
