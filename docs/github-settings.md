# Настройка репозитория GitHub

## 1. Политика публикации

GitHub используется для публикации исходного кода, release artifacts, результатов CI, security
analysis и технической документации. Репозиторий не является публичной площадкой совместной
разработки: внешние pull request, issues и запросы на внедрение не рассматриваются.

Публичный roadmap, release cadence и сроки обработки обращений не заявлены.

Перед публикацией владелец проверяет diff, commit metadata и отсутствие secrets. Автоматизированный
push выполняется только после отдельного явного одобрения владельца.

## 2. Общие свойства

В **Settings → General** используются следующие значения:

- Description: `Self-hosted E2E iOS messenger with a Rust backend`;
- Website: `https://copilot82.github.io/TellMe/`;
- Topics: `ios`, `swift`, `rust`, `self-hosted`, `e2ee`, `axum`, `webrtc`, `cryptography`;
- **Issues**, **Discussions**, **Projects** и **Wikis** отключены;
- funding links и внешние support channels не публикуются;
- Releases используются для фиксации проверенных версий исходного кода.

Отключение community-функций фиксирует модель доступа и не заменяется формальным приглашением к
contribution в README.

## 3. GitHub Pages

В **Settings → Pages → Build and deployment** выбран источник **GitHub Actions**. Workflow
`Documentation` выполняет strict build и проверку ссылок; публикация разрешена только для основной
ветки.

После изменения документации проверяются:

- главная страница и navigation;
- Mermaid-схемы на desktop и mobile viewport;
- внешние ссылки Apple, Docker, Caddy и TestFlight;
- отсутствие элементов интерфейса, предлагающих редактирование через pull request;
- корректность русскоязычного поиска.

## 4. Защита основной ветки

Ruleset основной ветки должен обеспечивать:

- запрет force push и удаления;
- linear history;
- выполнение обязательных status checks;
- ограничение прямой записи владельцем репозитория;
- signed commits, если используется стабильная signing-конфигурация.

Обязательные checks:

- Rust formatting, Clippy и tests;
- dependency и license policy;
- local Compose smoke;
- iOS unit tests;
- headless E2E;
- documentation strict build и link check;
- Swift CodeQL;
- Gitleaks history scan.

Требование pull request не включается. Отсутствие публичного review workflow является намеренным
ограничением модели репозитория.

## 5. Security features

Для repository включены:

- dependency graph и Dependabot alerts;
- secret scanning и push protection;
- private vulnerability reporting без заявленного response SLA;
- workflow `CodeQL` без параллельного GitHub default setup;
- Gitleaks для проверки публикуемой истории.

Результаты автоматических инструментов относятся к конкретному commit. Они не заменяют независимый
аудит протокола, iOS-клиента и production-инфраструктуры.

Code scanning alert закрывается как false positive только после статического разбора source,
sink, trust boundary и фактического контракта данных. Причина фиксируется в комментарии alert.

## 6. Release

Release `v2.0.0` содержит:

- назначение проекта как corporate self-hosted source base;
- полный commit hash;
- перечень выполненных CI/release gates;
- ссылку на deployment guide;
- TestFlight public link с указанием возможной недоступности до Apple review;
- ограничения: отсутствие независимого security audit и group messaging;
- сведения о лицензии.

В release assets не включаются `.env`, APNs keys, provisioning profiles, signing certificates,
device logs, `xcresult` с персональными данными и production backups.

## 7. Проверка приватности перед push

Минимальная проверка:

```bash
git status --short
git diff --check
git log --format='%an <%ae>' | sort -u
rg -n -i 'password|secret|token|private.?key' --glob '!**/.git/**'
gitleaks git --redact --no-banner
```

Последняя команда проверяет историю, а не только рабочее дерево. Если commit metadata содержит
персональное имя или email, одной правки README недостаточно: публикуемая история создаётся с
нейтральной project identity либо переписывается до push.

## 8. Контроль изменения настроек

После изменения repository settings через UI или API проверяются:

- `visibility`, default branch и URL GitHub Pages;
- состояние community-функций;
- ruleset основной ветки;
- состояние Dependabot, CodeQL, secret scanning и push protection;
- последний workflow run для каждого обязательного check;
- соответствие release tag проверенному commit.

Фактические настройки GitHub имеют приоритет над этим документом. Расхождение устраняется в том же
административном изменении, которым была изменена конфигурация repository.
