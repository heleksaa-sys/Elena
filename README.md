# Elena — управление OpenClaw на VPS с iPhone

Этот репозиторий — пульт управления личным AI‑ассистентом [OpenClaw](https://openclaw.ai), который живёт на VPS. Всё описано как код. Любая правка в `main` → автоматический деплой через GitHub Actions.

## Что развёрнуто

```
iPhone (Safari / GitHub mobile)
        │
        ▼
GitHub repo  ──push→  GitHub Actions  ──ssh→  VPS
                                                 │
                                                 ├── Caddy (80/443, host network, авто Let's Encrypt)
                                                 │     └→ 127.0.0.1:18789
                                                 │
                                                 └── OpenClaw gateway (lan-bind на порту 18789)
                                                       └→ Anthropic / OpenAI / Ollama
```

- **OpenClaw** слушает на порту 18789, защищён firewall‑правилом DOCKER‑USER от внешнего доступа.
- **Caddy** терминирует TLS и проксирует на gateway. Сертификат обновляется сам.
- **Конфиг и workspace** лежат в `/root/.openclaw` на VPS (бэкапятся ежедневно).
- **Стабильный токен** хранится в `/root/.openclaw/.elena-secrets.env` — не сбрасывается при деплое.

## Доступ

После каждого деплоя на странице run в Actions есть блок **«OpenClaw deployed»** с актуальной ссылкой и токеном.

Доступны **две HTTPS ссылки** одновременно (для обхода блокировок DNS у провайдера):

- основная: `https://<IP-через-дефис>.sslip.io`
- запасная: `https://<IP-через-дефис>.nip.io`

Если ни одна не открывается — провайдер блокирует обе. Тогда:
- купить домен и положить в секрет `DOMAIN`,
- или использовать SSH‑туннель через Termius: `ssh -L 18789:127.0.0.1:18789 root@<IP>` → потом `http://127.0.0.1:18789` в Safari.

## Секреты GitHub (Settings → Secrets → Actions)

| Секрет | Что |
|---|---|
| `VPS_HOST` | IP или домен VPS |
| `VPS_PASSWORD` | пароль root (используется sshpass из CI) |
| `VPS_PORT` | SSH‑порт, опционально (по умолчанию 22) |
| `VPS_USER` | имя пользователя, опционально (по умолчанию root) |
| `DOMAIN` | свой домен с A‑записью на VPS, опционально (если пусто — будет sslip.io+nip.io по IP) |
| `DOMAIN_ALT` | второй домен, опционально |
| `ACME_EMAIL` | email для уведомлений Let's Encrypt, опционально |
| `ANTHROPIC_API_KEY` | если используешь Claude |
| `OPENAI_API_KEY` | если используешь OpenAI |
| `TZ` | часовой пояс, по умолчанию `Europe/Moscow` |

`OPENCLAW_GATEWAY_TOKEN` и `GOG_KEYRING_PASSWORD` создаются автоматически на VPS при первом деплое — задавать в секретах **не нужно**.

## Ежедневная работа с iPhone

| Что | Как |
|---|---|
| Поправить конфиг / Caddyfile / скрипт | GitHub mobile → Edit → Commit → Actions сам выкатит |
| Обновить OpenClaw до свежего образа | Actions → Deploy to VPS → Run workflow |
| Глянуть логи | Actions → последний прогон → шаг "Run bootstrap on VPS" |
| Посмотреть актуальный токен | Actions → последний прогон → блок Summary внизу |
| Сделать бэкап сейчас | Actions → Backup OpenClaw config → Run workflow → скачать tgz из артефактов |
| Срочный SSH | Termius (сохранён host) → одна кнопка |
| Откатиться | GitHub mobile → revert коммита → авто‑деплой |

## Бэкапы

`.github/workflows/backup.yml` пакует `/root/.openclaw` в tgz, кладёт в GitHub Artifacts (хранится 30 дней). По расписанию каждые сутки в 03:00 UTC + по кнопке.

## Восстановление из бэкапа

Скачать tgz из Actions, через Termius / SCP положить на VPS, на VPS:

```bash
cd /opt/elena && docker compose down
tar -C /root -xzf openclaw-YYYYMMDDTHHMMSSZ.tgz
docker compose up -d
```

## Безопасность

- Gateway не выставлен на 0.0.0.0 наружу: firewall блокирует порт 18789 на внешнем интерфейсе.
- Авторизация по токену (64-символьная hex‑строка), сохраняется между деплоями.
- `~/.openclaw` имеет права `700`.
- Caddy ставит HSTS и базовые security‑заголовки.
- TLS только современные шифры (Caddy дефолты).
- Pаз в неделю запускай **Run workflow** — обновляется до свежего образа `ghcr.io/openclaw/openclaw:latest`.

## Структура

```
.
├── .github/workflows/
│   ├── deploy.yml      # авто-деплой по push в main
│   └── backup.yml      # бэкап по расписанию + по кнопке
├── scripts/
│   └── bootstrap-vps.sh  # идемпотентная установка на VPS
├── docker-compose.yml  # Caddy в host networking
├── Caddyfile           # reverse proxy + TLS на оба домена
├── .env.example        # шаблон, на VPS .env собирается из секретов
└── README.md
```

## Полезные ссылки

- Docs: https://docs.openclaw.ai
- Repo: https://github.com/openclaw/openclaw
- Security hardening: https://docs.openclaw.ai/gateway/security
