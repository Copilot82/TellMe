# Стабилизация Picture in Picture для WebRTC-звонка

## Исходная проблема

PiP запускался нестабильно при переводе приложения в background: AVKit мог оставить чёрный кадр,
не начать PiP либо потерять связь с активной WebRTC-сессией после возврата приложения. Обычный
simulator smoke не воспроизводил полный набор условий CallKit, camera capture и process lifecycle.

## Наблюдаемая система

Для диагностики были разделены четыре состояния:

1. WebRTC media session и получение remote frames;
2. source view readiness для `AVPictureInPictureVideoCallViewController`;
3. lifecycle `AVPictureInPictureController`;
4. process/call identity до background и после foreground restore.

Каждая запись diagnostics связывалась с call id и launch id. В evidence сохранялись XCTest log,
JSONL events и screenshots до Home, на Home и поверх другого приложения.

## Проверенные гипотезы

### Автоматизация уничтожает исходную call session

`XCUIApplication.activate()` после Home в отдельных запусках создавал новый process/launch id.
Такой run нельзя было считать доказательством сохранения PiP, даже если финальный экран выглядел
корректно. Gate был изменён: evidence принимается только при совпадении call/launch identity.

### AVKit source view не готов к старту

PiP start был привязан к подтверждённому remote video source, а не только к состоянию signaling.
Diagnostics получили отдельные события configure/start/didStart/failure и bounded timeout.

### Неверная геометрия кадра

`resizeAspectFill` и размер full-screen portrait source давали сильный crop. Для PiP-only renderer
использован `resizeAspect`, а preferred content size задан как `160x90`. Full-screen renderer
сохранил собственную presentation policy.

## Автоматический evidence

Physical regression выполнялся на двух iPhone и проверял:

- connected audio/video media;
- remote frame до background;
- PiP window на Home и поверх Settings;
- отсутствие black placeholder;
- сохранение call/launch id;
- отсутствие start failure/timeout events;
- возврат в foreground без новой call session.

Visual analyzer вычислял luminance и изменение кадров как диагностический сигнал. Motion не стал
жёстким gate: реальный участник может оставаться неподвижным. Обязательными остались non-black
frame и сохранение session identity.

## Результат

Production-shaped path с `activeVideoCallSourceView` и
`AVPictureInPictureVideoCallViewController` прошёл повторные physical runs, включая удержание PiP
поверх другого приложения. Отдельный sample-buffer path сохранён как диагностический fallback, но
не используется как основной UI flow.

## Выводы

- UI automation action может менять исследуемую lifecycle-систему;
- visual pass без identity correlation не доказывает сохранение исходной call session;
- simulator и physical device являются разными test layers;
- timeout увеличивается только после измерения события, которого не хватает;
- evidence должен сохранять как успешные, так и неуспешные фазы.

Сырой рабочий журнал намеренно не публикуется: он содержал environment-specific run identifiers и
пути к локальным artifacts. Этот документ сохраняет проверяемые инженерные решения без привязки к
частному стенду.
