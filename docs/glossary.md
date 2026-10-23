# Glossary / Глоссарий

English ↔ Russian terms used across the Patina documentation. Every `.ru.md`
file uses these renderings. If you change a term here, update the Russian docs
in the same commit.

Термины, которыми пользуется вся документация Patina, на английском и русском.
Каждый файл `.ru.md` переводит их так, как указано здесь. Если вы меняете термин
в этом файле, исправьте русские документы в том же коммите.

## Conventions / Соглашения

- Code, commands, paths, env var names, config keys and protocol messages
  (`RegisterPk`, `PunchHole`, `WS_REGISTER`, …) are never translated.
- Client UI labels are quoted as they appear in the Russian UI of RustDesk 1.5.0
  (`src/lang/ru.rs` at tag `1.5.0`), with the English label in parentheses:
  «Сервер ID» (ID Server). The `Key` field has no Russian translation in 1.5.0,
  so it shows as `Key` in the Russian UI too.
- Russian text uses «ёлочки» for quotes, keeps «ё», and addresses the reader as
  «вы» (lowercase).

## Servers and roles / Серверы и роли

| English | Русский | Notes / Примечания |
| --- | --- | --- |
| ID server, rendezvous server (`hbbs`) | сервер ID (`hbbs`) | Client UI: «Сервер ID» (ID Server). Error messages in the client say «промежуточный сервер»; in prose we use «сервер ID». |
| relay server (`hbbr`) | ретранслятор, сервер-ретранслятор (`hbbr`) | Client UI: «Ретранслятор» (Relay Server). |
| relay (n.), relayed connection | ретрансляция, подключение через ретранслятор | |
| API server | сервер API | Client UI: «Сервер API» (API Server). |
| key, public key | ключ, открытый ключ | Client UI field `Key` (untranslated). |
| controlled device, target | управляемое устройство | The device that is being connected to. |
| controller | управляющее устройство, управляющий клиент | The side that initiates the connection. |
| device owner | владелец устройства | |
| operator (of the server) | администратор сервера | |
| peer | узел (peer) | Write «peer» in parentheses on first use in a document. |
| upstream | upstream (исходный проект `rustdesk/rustdesk-server`) | Kept in English; explain on first use. |
| fork | форк | |
| stock client | стандартный (неизменённый) клиент | |

## Protocol and networking / Протокол и сеть

| English | Русский | Notes / Примечания |
| --- | --- | --- |
| registration (of a device) | регистрация (устройства) | |
| register (v.) | зарегистрироваться, регистрировать | |
| ready (device status) | «Готов» (Ready) | Client UI status. |
| online status, online dot | статус «в сети», индикатор «в сети» | |
| keepalive | keepalive (сигнал поддержания соединения) | Keep the English word; explain on first use. |
| empty binary frame | пустой бинарный кадр | |
| frame (WebSocket) | кадр | |
| echo (v./n.) | эхо, отвечать эхом | The client echoes the server's empty frames. |
| heartbeat | heartbeat (контрольный сигнал) | |
| read timeout | тайм-аут чтения | |
| idle connection | простаивающее соединение | |
| reconnect | переподключение, переподключиться | |
| connection id (`conn_id`) | идентификатор соединения (`conn_id`) | |
| writer task | задача записи (writer task) | |
| channel (`mpsc`) | канал (`mpsc`) | |
| sink | приёмник (sink) | |
| routing | маршрутизация | |
| hole punching | hole punching (пробивка NAT) | Client UI keeps «UDP hole punching». |
| NAT | NAT | |
| reverse proxy | обратный прокси | |
| trusted proxy | доверенный прокси | |
| CIDR, CIDR range | CIDR, диапазон CIDR | |
| last hop (of `X-Forwarded-For`) | последний узел цепочки (`X-Forwarded-For`) | |
| spoofed header | подделанный заголовок | |
| proxy header | заголовок прокси | `X-Real-IP`, `X-Forwarded-For`, `X-Real-Port`. |
| handshake | рукопожатие | WebSocket or TLS handshake. |
| route (to a device) | маршрут (к устройству) | The connection that receives traffic for an id. |
| TLS certificate | TLS-сертификат | |
| local CA | локальный центр сертификации (CA) | |
| domain, subdomain | домен, поддомен | |
| port | порт | |
| throttle, rate limit | ограничение частоты | |
| limit, cap | ограничение, лимит | |
| outbound connection | исходящее соединение | One the server opens on its own, not a reply on a socket a client opened. |
| packet capture | захват пакетов | |

## Security / Безопасность

| English | Русский | Notes / Примечания |
| --- | --- | --- |
| threat model | модель угроз | |
| id hijack | перехват ID | |
| ownership check | проверка владельца | |
| fail closed | отказ в безопасную сторону (fail closed) | Keep the English in parentheses on first use. |
| IP blocker | блокировка по IP | Upstream's `check_ip_blocker`. |
| licence key | лицензионный ключ | Field of `PunchHoleRequest`; in practice the server key. |
| MITM | посредник (MITM) | |
| denial of service | отказ в обслуживании | |
| accepted risk | принятый риск | |
| owner-checked cleanup | очистка с проверкой владельца | |
| 2FA, two-factor authentication | двухфакторная аутентификация (2FA) | Client UI: «Использовать двухфакторную аутентификацию». |
| click-to-approve | подтверждение нажатием | Client UI: «Принимать сеансы нажатием кнопки» (Accept sessions via click). |
| ID whitelist | белый список ID | Client UI: «Использовать белый список ID» (Use ID whitelisting). |
| IP whitelist | белый список IP | Client UI: «Использовать белый список IP» (Use IP Whitelisting). |
| one-time password | одноразовый пароль | |
| permanent password | постоянный пароль | |
| trusted devices | доверенные устройства | |
| session | сеанс | The client UI uses «сеанс». |
| phone home | обращаться к третьим сторонам по своей инициативе | Not «звонить домой». |
| fingerprint (of a host) | отпечаток (хоста) | `device_id` in upstream's version check. |

## Project and process / Проект и процесс

| English | Русский | Notes / Примечания |
| --- | --- | --- |
| patch | патч | |
| rebase | rebase (перенос изменений на новую базу) | |
| tag, release | тег, релиз | |
| commit | коммит | |
| unit test | модульный тест | |
| integration test | интеграционный тест | |
| idle soak | длительная проверка простоя | |
| probe (e2e) | пробник | `tests/e2e/probe`. |
| bench (e2e) | стенд | |
| baseline run | базовый прогон | |
| positive control | положительный контроль | A run that must trip the check, to show the check works (`tests/egress-check.sh`). |
| end-to-end (e2e) test | сквозной (e2e) тест | |
| deployment | развёртывание | |
| known limitations | известные ограничения | |
| Corresponding Source (AGPL) | Соответствующий исходный код (AGPL) | Term from the AGPL; keep the capital letter. |
| source offer | предложение исходного кода | |
| attribution | указание авторства | |
