# Публикация и архивирование репозитория GitHub

## 1. Политика

Репозиторий публикуется как read-only инженерный snapshot. Проект не сопровождается, внешние pull
request и issues не рассматриваются. GitHub используется для хранения исходного кода, CI evidence,
release artifact, security analysis и технической документации.

До первой публикации владелец лично проверяет diff, commit metadata и отсутствие secrets. Push не
выполняется автоматизированным процессом без отдельного явного одобрения.

## 2. Порядок первой публикации

1. Создать публичный repository без автоматически добавленных README/License.
2. Отправить подготовленную основную ветку только после ручного approval.
3. Дождаться успешного выполнения всех GitHub Actions.
4. Включить GitHub Pages и проверить опубликованные страницы на desktop/mobile.
5. Создать release `v2.0.0` из проверенного commit.
6. Проверить CodeQL, dependency graph и secret scanning.
7. Отключить community-функции.
8. После фиксации Pages/release перевести repository в archived state.

Архивирование делает repository read-only и наиболее точно отражает отсутствие сопровождения.
Если сначала требуется повторный CI run или исправление метаданных, архивирование выполняется после
этих операций.

## 3. Общие свойства

В **Settings → General** до архивирования:

- Description: `Self-hosted E2E iOS messenger with a Rust backend`;
- Website: `https://copilot82.github.io/TellMe/`;
- Topics: `ios`, `swift`, `rust`, `self-hosted`, `e2ee`, `axum`, `webrtc`, `cryptography`;
- отключить **Issues**, **Discussions**, **Projects** и **Wikis**;
- оставить Releases и Packages только если они действительно используются;
- не добавлять funding links и внешние support channels.

README и `SECURITY.md` должны явно сообщать, что maintenance и response SLA отсутствуют.

## 4. GitHub Pages

В **Settings → Pages → Build and deployment** выбрать **GitHub Actions**. Workflow
`Documentation` выполняет strict build и link check, а публикацию запускает только основная ветка.

Перед архивированием проверить:

- главную страницу и navigation;
- Mermaid-схему на desktop и mobile viewport;
- внешние ссылки Apple/Docker/Caddy;
- отсутствие кнопки редактирования, подразумевающей приём PR;
- корректность русскоязычного поиска.

## 5. Branch ruleset до архивирования

Для основной ветки на период подготовки рекомендуется ruleset:

- запрет force push и удаления;
- обязательные status checks;
- linear history;
- ограничение push владельцем репозитория;
- signed commits, если используется стабильная signing-конфигурация.

Обязательные checks:

- Rust formatting/Clippy/tests;
- dependency and license policy;
- local Compose smoke;
- iOS unit tests;
- headless E2E;
- documentation strict build/link check;
- Swift CodeQL;
- Gitleaks history scan.

Требование pull request не нужно, если repository не принимает внешние изменения и сразу
архивируется. Ruleset служит защитой подготовительного этапа, а не обещанием review workflow.

## 6. Security features

До архивирования включить доступные функции:

- dependency graph;
- Dependabot alerts;
- secret scanning и push protection;
- private vulnerability reporting, если владелец готов принимать приватные сообщения без SLA;
- workflow `CodeQL`; GitHub default setup одновременно не включать, чтобы не дублировать анализ.

Результаты security tools относятся к проверенному snapshot и не означают постоянный мониторинг или
независимый криптографический аудит.

## 7. Release

Release `v2.0.0` должен содержать:

- назначение как corporate self-hosted source base;
- commit hash;
- перечень выполненных CI/release gates;
- ссылку на deployment guide;
- TestFlight public link и отметку о возможной недоступности до review;
- ограничения: отсутствие security audit, group messaging и дальнейшей поддержки;
- license.

Не прикладывайте `.env`, APNs key, provisioning profiles, signing certificates, device logs,
xcresult с персональными данными или production backup.

## 8. Проверка приватности перед push

Минимальный pre-push audit:

```bash
git status --short
git diff --check
git log --format='%an <%ae>' | sort -u
rg -n -i 'password|secret|token|private.?key' --glob '!**/.git/**'
gitleaks git --redact --no-banner
```

Последняя команда проверяет историю, а не только рабочее дерево. Если commit metadata содержит
персональное имя/email, одной правки README недостаточно: публикуемая история должна быть создана
с нейтральной project identity либо переписана до первого push.

## 9. Архивирование

После финальной ручной проверки откройте **Settings → General → Danger Zone → Archive this
repository**. Убедитесь, что release и Pages доступны без авторизации, а README сразу объясняет
read-only статус.

Для критического исправления владелец может временно снять archive, внести проверенное изменение,
повторить CI и снова архивировать repository. Это исключительная операция и не означает
возобновление публичной поддержки.
