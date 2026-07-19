# Техническая документация TellMe

Документы описывают состояние protocol v2 и Rust backend на уровне release `2.0.0`. Исходный код
и автоматические тесты имеют приоритет при расхождении с текстом.

## Карта документов

| Документ | Назначение | Основная аудитория |
| --- | --- | --- |
| [Требования](requirements.md) | Apple, устройства, домен, VPS, сеть | технический руководитель |
| [Развёртывание](deployment.md) | установка с чистого VPS до iOS release | инженер внедрения |
| [Apple и iOS](apple-setup.md) | identifiers, APNs, signing, TestFlight | iOS/release engineer |
| [Проверка установки](deployment-verification.md) | production acceptance gates | инженер эксплуатации |
| [Backup и restore](backup-and-restore.md) | согласованный backup и recovery exercise | инженер эксплуатации |
| [Диагностика](troubleshooting.md) | типовые ошибки TLS, Docker, TURN, APNs | инженер эксплуатации |
| [Архитектура](architecture.md) | компоненты, границы и потоки данных | разработчик, архитектор |
| [Модель угроз](threat-model.md) | активы, доверие, угрозы и ограничения | security reviewer |
| [Протокол](protocol.md) | identity, X3DH, ratchet, fanout, media, calls | client/backend developer |
| [API](api.md) | HTTP/WebSocket surface и authentication | разработчик клиента |
| [Локальная разработка](local-development.md) | запуск и конфигурация | разработчик |
| [Тестирование](testing.md) | уровни тестов и release gates | разработчик, reviewer |
| [Эксплуатация](operations.md) | runtime model и наблюдаемость | инженер эксплуатации |
| [Стиль кода](code-style.md) | правила кода и комментариев | разработчик |
| [ADR](adr/README.md) | принятые архитектурные решения | architect, reviewer |
| [Стабилизация PiP](case-studies/pip-stabilization.md) | разбор диагностики на устройствах | iOS developer |
| [Настройка GitHub](github-settings.md) | Pages, release, security и архивирование | владелец репозитория |

## Правила актуализации

При продолжении проекта во внутреннем fork документ обновляется в том же change set, что и
изменение соответствующего contract. Минимальные связи:

- новый endpoint → `api.md` и contract tests;
- изменение plaintext/ciphertext boundary → `architecture.md` и `threat-model.md`;
- изменение key derivation или device trust → `protocol.md` и отдельный ADR;
- новая runtime dependency → `local-development.md`, `operations.md` и Compose;
- новый test harness → `testing.md` и CI workflow.

Сырые credentials, production IP, seed-фразы, private keys и содержимое runtime `.env` в
документацию не включаются.
