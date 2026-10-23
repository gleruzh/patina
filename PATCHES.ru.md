[English](PATCHES.md) | Русский
<!-- en-source: PATCHES.md @ 8fb1407aa4f89728bae8635a49070179a25dc5ea -->

# Патчи поверх upstream

Patina — это исходный проект (upstream)
[rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server) плюс
короткая серия коммитов. Пусть так и остаётся: никакого переформатирования,
никаких посторонних изменений, новый код — в новых файлах.

База: `master` upstream на коммите `873230e35a8805de7fd057e7eb763c46f7a174ef`
(«fix: key file perm (#705)», 1.1.17-dev), `libs/hbb_common` на `69cea8d`.

## Серия коммитов

Заголовки коммитов оставлены на английском, как в истории git.

| Коммит | Затрагивает | Что делает |
| --- | --- | --- |
| refactor(hbbs): share the RegisterPk checks | `src/rendezvous_server.rs` | Переносит тело UDP-обработчика `RegisterPk` в `register_pk()`; поведение UDP не меняется. |
| feat(hbbs): add ws_peers, state for WebSocket device registration | `src/ws_peers.rs` (новый), `src/lib.rs` | Задача записи, `WsTx`, `WsPeers`, доверенные прокси, лимиты, модульные тесты. |
| feat(hbbs): WebSocket writer task, trusted proxies, connection limits | `src/rendezvous_server.rs` | `Sink::Ws` становится `Sink::Chan`. Ветка WS в `handle_listener_inner` использует `ws_peers::accept` и задачу записи. |
| feat(hbbs): register devices over WebSocket (WS_REGISTER=Y) | `src/rendezvous_server.rs` | `handle_tcp` получает `ws_conn`, добавлены функции `handle_ws_*`. Маршрутизация в `handle_tcp_punch_hole_request` и в ветке `RequestRelay`. `online_states()`. Модульные тесты. |
| test(hbbs): in-process WebSocket registration integration test | `tests/ws_registration.rs` (новый) | `hbbs` в том же процессе + tokio-tungstenite. |
| fix(hbbs): fail closed on ambiguous proxy headers | `src/ws_peers.rs` | Повторяющиеся, неразбираемые или противоречащие друг другу `X-Real-IP` / `X-Forwarded-For` заменяются адресом прокси. |
| fix(hbbs): refuse RequestRelay to WS devices unless the relay is in -r | `src/rendezvous_server.rs` | `ws_relay_allowed()`. |
| fix(hbbs): a superseded WebSocket cannot take its id back | `src/rendezvous_server.rs` | `RegisterPk` от соединения, у которого более новое соединение забрало id, закрывает его. |
| fix(hbbs): no version check to api.rustdesk.com unless SOFTWARE_UPDATE_CHECK=Y | `src/common.rs` | `software_update_check_enabled()` управляет вызовом `check_software_update()`, плюс модульный тест. |
| test: egress check, hbbs and hbbr send nothing on their own | `tests/egress-check.sh` (новый) | Проверка с tcpdump в Docker, с положительным контролем. |
| коммиты документации | `docs/ws-registration.md`, `PATCHES.md` (новые) | |
| коммиты сборки, развёртывания, e2e и README | `Dockerfile`, `.dockerignore`, `deploy/`, `tests/e2e/`, `README.md`, `*.ru.md`, `docs/glossary.md` | Новые файлы, кроме `README.md`. Держите их отдельно от коммитов с кодом, чтобы коммиты с кодом переносились на новую базу сами по себе. |

Затронутый код upstream — именно здесь будут конфликты:

* `src/rendezvous_server.rs`
  * импорты, `enum Sink`, `struct RendezvousServer` (поле `ws_peers`) и его
    создание в `start_with_bind`;
  * `handle_udp`: ветка `RegisterPk` (теперь вызов `register_pk`);
  * `handle_tcp`: сигнатура (`ws_conn`), ветки `RequestRelay` и `RegisterPk`,
    новые ветки `RegisterPeer` / `OnlineRequest` с условием
    `ws_conn.is_some()`;
  * `handle_online_request` (тело перенесено в `online_states`);
  * `send_to_sink` (ветка `Sink::Chan`);
  * `handle_tcp_punch_hole_request` (сначала маршрут через `ws_peers`);
  * `handle_listener_inner` (ветка `if ws`);
  * модуль тестов (новые тесты и блокировка в `punch_reqs_bounded`).
* `src/lib.rs`: `mod ws_peers;`.
* `src/common.rs`: условие `SOFTWARE_UPDATE_CHECK` в начале
  `check_software_update()` и тест в конце модуля тестов.

`src/ws_peers.rs` и `tests/ws_registration.rs` — новые файлы, конфликтов в
них не будет. Но они зависят от `rendezvous_proto` из hbb_common,
`tokio-tungstenite` / `tungstenite` 0.17 и `ipnetwork` 0.20 (всё из
`Cargo.toml` upstream). Обновление любой из этих зависимостей может сломать
их при компиляции.

## Перенос на новый тег upstream

```bash
git fetch https://github.com/rustdesk/rustdesk-server --tags
# the old base is the upstream commit the series currently sits on
OLD_BASE=873230e35a8805de7fd057e7eb763c46f7a174ef
NEW_BASE=<upstream tag or commit>
git switch -c rebase-$NEW_BASE <current patina branch>
git rebase --onto "$NEW_BASE" "$OLD_BASE"
git submodule update --init        # hbb_common at the new upstream pin
```

Затем, прежде всего остального:

1. **Прочитайте изменения upstream в перечисленных выше функциях**, а не
   только конфликты: `git diff $OLD_BASE $NEW_BASE -- src/rendezvous_server.rs
   src/peer.rs src/common.rs`. В частности:
   * любое изменение проверок UDP `RegisterPk` нужно внести в
     `register_pk()`, который теперь обслуживает оба транспорта;
   * для новых веток сообщений в `handle_tcp` нужно решить, относятся ли они
     к WebSocket-устройствам (`ws_conn`);
   * изменения ключей `tcp_punch` или того, как вычисляется `addr` для WS
     (upstream заменял его на `IP:0`), должны сохранять уникальность адресов
     для каждого соединения;
   * новые исправления безопасности upstream (ограничения частоты, лимиты id,
     исправления против атак отражения) должны остаться нетронутыми. Никогда
     не включайте снова UDP `PunchHoleRequest`;
   * любое новое исходящее обращение (HTTP, телеметрия, проверка обновлений
     или лицензии, изменённый `version_check_request`) должно быть выключено
     по умолчанию, как проверка версии. Ищите `reqwest`, `hyper`, `connect`,
     `send_to` и `lookup_host` в `src/` и в коде hbb_common, до которого
     доходит сервер. Обновите таблицу в
     [docs/ws-registration.ru.md](docs/ws-registration.ru.md#исходящие-соединения).
2. Если upstream обновляет `libs/hbb_common`, проверьте в
   `protos/rendezvous.proto` изменения `RegisterPk`,
   `RegisterPkResponse.keep_alive`, `OnlineRequest` и `RelayResponse`.
3. Проверьте, не изменилось ли то, чего ожидает клиент. Прочитайте в
   `rustdesk/rustdesk` `src/rendezvous_mediator.rs` (`start_tcp`,
   `handle_resp`, `create_relay`, `register_pk`) и в `hbb_common`
   `src/websocket.rs` (`check_ws`) для текущего релиза клиента: эхо пустых
   кадров, тайм-аут `keep_alive` × 1,5, `/ws/id` и `/ws/relay`, правило https
   для `api-server`.
4. Запустите тесты в Docker (инструменты на хосте не нужны). Используйте
   образ Rust, закреплённый в `Dockerfile`:

   ```bash
   docker run --rm -v "$PWD":/src -w /src -e CARGO_TARGET_DIR=/tmp/target \
     rust:1.99.1-slim-trixie sh -c \
     'apt-get update -qq &&
      apt-get install -y -qq --no-install-recommends make pkg-config libssl-dev &&
      cargo test --locked &&
      cargo test --locked --test ws_registration -- --ignored'
   ```

   Второй запуск — длительная проверка простоя: зарегистрированное
   соединение должно продержаться больше 5 минут. Она занимает около 5,5
   минуты.

5. Соберите образ и запустите `tests/egress-check.sh <image>`. Он должен
   вывести три строки `ok`.
6. Запустите сквозной тест со стандартным клиентом (см. `tests/e2e/`) и
   сравните результат с последним отчётом о тестировании.
7. Обновите базовый коммит в начале этого файла.

Если upstream когда-нибудь сам добавит регистрацию через WebSocket, сравните
её с этой серией и отдайте предпочтение upstream, сохранив те меры защиты,
которых в нём нет (доверенные прокси, очистка с проверкой владельца, запрет
привязки через `RegisterPeer`).

## Указание авторства

Из двух других форков под AGPL-3.0 взяты идеи, а не код:

* [ymg2006/rustdesk-server](https://github.com/ymg2006/rustdesk-server):
  маршруты WebSocket с ключом из id узла и идентификатора соединения
  (побеждает новейшее, очистка с проверкой владельца), маршрутизация
  `PunchHole` / `FetchLocalAddr` / `RequestRelay` в WebSocket и
  `TRUSTED_PROXY_CIDRS`. Не взято: откат коммита upstream 80d3a50 (UDP
  `PunchHoleRequest`), набор JWT / `MUST_LOGIN` и `RegisterPeer` через
  TCP/WebSocket, который обновляет адрес и `last_reg_time` любого id,
  замеченного с того же IP, не проверяя, что это соединение его
  зарегистрировало.
* [bropines/rustdesk-server](https://github.com/bropines/rustdesk-server),
  ветка `rdpanel`: идея `TCP_KEEPALIVE` — пустой бинарный кадр примерно
  каждые 12 с, на который клиент отвечает эхом, что обновляет
  `last_reg_time`. Не взято: ключи `IP:0`, таблица WS, которая никогда не
  очищается, блокировка, удерживаемая через `send().await`, и безусловное
  доверие к `X-Forwarded-For`.

## Лицензия

AGPL-3.0, как в upstream. При каждом переносе на новую базу оставляйте
`LICENSE` и уведомления об авторских правах upstream без изменений. Сохраняйте
заголовки новых файлов (`src/ws_peers.rs`, `tests/ws_registration.rs`,
`tests/egress-check.sh`) и указание авторства выше. Действует §13 AGPL:
пользователи, которые обращаются к серверу по сети, должны иметь возможность
получить исходный код работающей версии. Ссылка на него есть в
[`deploy/client-settings.ru.md`](deploy/client-settings.ru.md).
