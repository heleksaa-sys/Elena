# Elena — управление OpenClaw на VPS с iPhone

Этот репозиторий — пульт управления личным AI‑ассистентом [OpenClaw](https://openclaw.ai), который живёт на твоём VPS. Всё описано как код. Любая правка в `main` → автоматический деплой через GitHub Actions.

## Архитектура

```
iPhone (GitHub mobile / Working Copy / Termius)
        │
        ▼
GitHub repo  ──push→  GitHub Actions  ──ssh→  VPS
                                                 │
                                                 ├── Caddy (80/443, авто Let's Encrypt)
                                                 │     └→ host.docker.internal:18789
                                                 │
                                                 └── OpenClaw gateway (loopback :18789)
                                                       └→ Anthropic / OpenAI / Ollama
```

- **OpenClaw** слушает только loopback — снаружи недоступен напрямую.
- **Caddy** терминирует TLS и проксирует на gateway. Сертификат обновляется сам.
- **Конфиг и workspace** живут в `/root/.openclaw` на VPS (volume).

## Первичная настройка (один раз)

### 1. Положи секреты в репозиторий

GitHub → Settings → Secrets and variables → Actions → New repository secret. Нужны:

| Секрет | Что |
|---|---|
| `VPS_HOST` | IP или домен VPS |
| `VPS_PORT` | SSH‑порт (если не 22) |
| `VPS_USER` | обычно `root` |
| `VPS_SSH_KEY` | приватный ключ целиком (`-----BEGIN OPENSSH PRIVATE KEY-----...`) |
| `DOMAIN` | домен с A‑записью на VPS (например `claw.example.com`); пусто = без TLS |
| `ACME_EMAIL` | твой email для Let's Encrypt |
| `OPENCLAW_GATEWAY_TOKEN` | оставь пустым — bootstrap сгенерирует и зафиксирует |
| `GOG_KEYRING_PASSWORD` | то же самое |
| `ANTHROPIC_API_KEY` | если используешь Claude |
| `OPENAI_API_KEY` | если используешь OpenAI |
| `TZ` | часовой пояс, по умолчанию `Europe/Moscow` |

### 2. Запусти первый деплой

Сделай любой коммит в `main` (например, поправь README) — Actions сами установят Docker, поднимут контейнер, выпустят сертификат.

Либо вручную: **Actions → Deploy to VPS → Run workflow**.

### 3. Проверь

- HTTPS: `https://<DOMAIN>` — должен открыться Control UI.
- SSH: `ssh root@<VPS> 'docker ps'` — увидишь `openclaw` и `caddy`.

## Ежедневная работа с iPhone

| Что | Как |
|---|---|
| Поправить конфиг | GitHub mobile → Edit → Commit → Actions сам выкатит |
| Глянуть логи | Actions → последний прогон Deploy → step "bootstrap" |
| Сделать бэкап сейчас | Actions → Backup OpenClaw config → Run workflow → скачать tgz из артефактов |
| Срочный SSH | Termius (сохранён ключ) → одна кнопка |
| Откатиться | GitHub mobile → revert коммита → авто‑деплой |

## Бэкапы

`/.github/workflows/backup.yml` пакует `/root/.openclaw` в tgz, кладёт в GitHub Artifacts (хранится 30 дней). По расписанию каждые сутки в 03:00 UTC + по кнопке.

## Восстановление из бэкапа

```bash
# на VPS
systemctl stop docker || docker compose -f /opt/elena/docker-compose.yml down
tar -C /root -xzf openclaw-YYYYMMDDTHHMMSSZ.tgz
docker compose -f /opt/elena/docker-compose.yml up -d
```

## Безопасность

- Gateway никогда не выставлен на 0.0.0.0 (`OPENCLAW_GATEWAY_BIND=loopback`).
- Авторизация по токену включена через `OPENCLAW_GATEWAY_TOKEN`.
- `~/.openclaw` имеет права `700`.
- Caddy ставит HSTS и базовые security‑заголовки.
- Регулярно: **Actions → Run workflow** — обновит до свежего образа `ghcr.io/openclaw/openclaw:latest`.

## Структура

```
.
├── .github/workflows/
│   ├── deploy.yml      # авто-деплой по push в main
│   └── backup.yml      # бэкап по расписанию + по кнопке
├── scripts/
│   └── bootstrap-vps.sh  # идемпотентная установка на VPS
├── docker-compose.yml  # только Caddy (OpenClaw поднимает upstream setup.sh)
├── Caddyfile           # reverse proxy + TLS
├── .env.example        # шаблон, на VPS .env собирается из секретов
└── README.md
```

## Полезное

- Docs: https://docs.openclaw.ai
- Repo: https://github.com/openclaw/openclaw
- Security hardening: https://docs.openclaw.ai/gateway/security
