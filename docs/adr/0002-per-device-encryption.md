# ADR-0002: Per-device encryption

Статус: принято

Дата: 2026-07-02

## Контекст

Шифрование на account-level public key не позволяет независимо отзывать устройство и не даёт
отдельное ratchet state для каждого endpoint. При добавлении второго устройства backend не должен
получать общий private key аккаунта.

## Решение

Каждое устройство имеет собственные signing/DH keys, device certificate, prekeys и ratchet
sessions. Отправитель получает список активных device bundles и формирует отдельный delivery для
каждого target device. Linking подтверждается существующим trusted device.

## Последствия

Положительные:

- revoke исключает устройство из новых deliveries;
- компрометация одного device key не раскрывает private material другого устройства;
- self-sync использует тот же encrypted delivery mechanism.

Отрицательные:

- fanout увеличивает число ciphertext deliveries;
- client хранит несколько sessions на одного пользователя;
- linking/revoke требуют отдельного trust UX;
- missed device bundle приводит к неполной синхронизации до обновления списка.

## Проверка

- device service валидирует certificate chain и state;
- prekey lookup возвращает bundle по устройствам;
- message service fanout исключает revoked devices;
- XCTest проверяет linking, revoke и session bootstrap.
