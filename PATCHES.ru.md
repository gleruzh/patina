[English](PATCHES.md) | Русский
<!-- en-source: PATCHES.md @ 60566cf18dcc7d107138a4de3039e67de3ef52b5 -->

# Патчи поверх upstream

Patina — это исходный проект (upstream)
[rustdesk/rustdesk-server](https://github.com/rustdesk/rustdesk-server) плюс
короткая серия коммитов. Пусть так и остаётся: никакого переформатирования,
никаких посторонних изменений, новый код — в новых файлах.

База: `master` upstream на коммите `680b60395ecf99a76f74a1d934e453bb6e5e0aa2`
(«fix(hbbr): match IPv4 clients against the relay lists in their IPv4 form (#748)», 1.1.17-dev), `libs/hbb_common` на `69cea8d`.

## Отличия от upstream

Всё ниже прочитано из `git diff upstream/master HEAD`; сверяйте после каждого
слияния. Файлы Patina: `src/ws_peers.rs`, `tests/ws_registration.rs`,
`tests/egress-check.sh` (новые); изменённые файлы upstream:
`src/rendezvous_server.rs`, `src/relay_server.rs`, `src/common.rs`,
`src/lib.rs`, `Cargo.toml` и `Cargo.lock` (dev-зависимость `tokio` с
`test-util`; registry-крейты в lock обновлены; git-зависимости на ревизиях
upstream). Всё остальное в `deploy/`, `tests/e2e/`, `docs/` и документах
верхнего уровня — собственные файлы Patina, код upstream они не затрагивают.

Пределы и тайм-ауты, которые отличаются:

| Что | Patina | Upstream | Зачем |
| --- | --- | --- | --- |
| Тайм-аут WebSocket-рукопожатия в `hbbs` (все WS-соединения, в том числе при `WS_REGISTER=N`) | 10 с (`ws_peers::HANDSHAKE_TIMEOUT`) | 30 с (474fbc7) | Молчащее соединение не должно занимать слот 30 с; лимит на IP его считает. |
| Срок записи в WebSocket в `hbbs` | 10 с на сообщение (`ws_peers::SEND_TIMEOUT`, задача записи) | нет (у задачи записи Patina нет аналога в upstream) | Устройство, которое перестало читать, не должно блокировать запись и копить кадры в очереди. |
| Предел сообщения и кадра WebSocket в `hbbs` | `MAX_MESSAGE_KB` (по умолчанию 64 КиБ, максимум 64 МиБ); кадр не более 16 МиБ; буферы чтения/записи 8 КиБ | так же, из `MAX_MESSAGE` и `WS_BUFFER_SIZE` upstream | После 0415b0e это не отличие; `ws_peers::accept` берёт значения upstream, чтобы регистрация была ограничена так же, как собственный WS-путь upstream. |
| Заголовки прокси в `hbbs` (`X-Real-IP`, `X-Real-Port`, `X-Forwarded-For`) | учитываются только от `TRUSTED_PROXY_CIDRS` (по умолчанию loopback); повторяющиеся, неразбираемые или противоречащие значения заменяются адресом прокси; порт из `X-Real-Port` или свой для соединения, никогда не `:0` | доверяются от любого узла (порт сохраняется с e5c0a42) | Подделка заголовков; уникальные адреса соединений. |
| WebSocket-соединения в `hbbs` | `MAX_WS_CONN_PER_IP` (по умолчанию 64), `MAX_WS_PEERS` (по умолчанию 10000, только регистрация через WebSocket) | без лимитов | Исчерпание памяти и соединений. |
| Срок записи в relay `hbbr`, оба направления | 30 с + min(len, 1 МиБ) / 16 КиБ/с, не более 94 с | плоские 30 с (1bd3938) | Большой кадр на медленном, но живом канале не должен обрываться; узел, который перестал читать, по-прежнему обрывается. |
| Проверка неактивности 30 с в `hbbr` | завершённая запись тоже считается активностью | считается только полученный кадр | Долгая запись не должна срабатывать как неактивность. |
| Предел сообщения после образования пары для плеча, которое остаётся framed или WebSocket (смешанные пары TCP-WS, WS-WS) | 32 МиБ на сообщение, 16 МиБ на кадр (`MAX_WS_RELAY_MESSAGE`) | `usize::MAX` для framed-плеча, 64 МиБ / 16 МиБ по умолчанию в tungstenite для WebSocket | Предел того, что один узел может заставить relay буферизовать. |
| Предел relay-запроса до образования пары, тайм-аут первого сообщения в `hbbr` | 128 КиБ, 30 с | так же (0415b0e) | Не отличие. |
| Исходящие вызовы | по умолчанию нет; проверка версии на `api.rustdesk.com` только при `SOFTWARE_UPDATE_CHECK=Y` | ежедневно, безусловно | Без обращений к третьим сторонам. |
| Регистрация устройств через WebSocket, статус онлайн, доставка `PunchHole` / `RequestRelay` / `FetchLocalAddr` | при `WS_REGISTER=Y` | `NOT_SUPPORT`, не отвечает | Смысл форка. |

Взято из upstream и больше не патчи Patina (upstream сделал то же самое, копия
Patina удалена при слиянии 680b603):

* проверка UUID relay: 44de977, 08cd442;
* истечение ожидающего пира после повторного использования id пары: 134008e;
* пределы размеров сообщений в `hbbs` и `hbbr`: 0415b0e (он же перевёл проект
  на tungstenite 0.29 через git-форк `tokio-tungstenite` из `rustdesk-org` и
  `[patch.crates-io]`; собственное обновление Patina до 0.26 удалено);
* предел времени WebSocket-рукопожатия и исправление порта в пути upstream:
  474fbc7, e5c0a42 (у пути `ws_peers` в Patina свои аналоги, см. таблицу);
* сроки записи ответов консоли `hbbs` и полная запись ответов консоли: 98ffcee,
  36a0996;
* сопоставление IPv4-клиентов со списками relay в форме IPv4: 680b603 (#748);
* плоский срок записи в relay 30 с: 1bd3938 (Patina теперь только масштабирует его).

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
| fix(hbbr): scale relay write deadlines, bound paired legs | `src/relay_server.rs` | Upstream (1bd3938, 0415b0e) теперь ограничивает записи в relay плоскими 30 с и размеры сообщений (128 КиБ для relay-запроса до образования пары, 64 МиБ / 16 МиБ по умолчанию в tungstenite после). Patina оставляет только отличия: срок записи — 30 с плюс len / 16 КиБ/с (масштабируемая часть считается не более чем для 1 МиБ, поэтому максимум 94 с); завершённая запись считается активностью для проверки неактивности в 30 с; плечо, которое после образования пары остаётся framed или WebSocket (смешанные пары TCP-WS, WS-WS), ограничено 32 МиБ на сообщение (кадры 16 МиБ) вместо «без ограничения» / 64 МиБ. |
| deps: tokio `test-util` dev-dependency; lock с обновлёнными registry-крейтами | `Cargo.toml`, `Cargo.lock` | Dev-зависимость нужна тестам с виртуальным временем в `src/relay_server.rs`. Обновление `tungstenite` / `tokio-tungstenite` больше не патч Patina: upstream перешёл на 0.29 (0415b0e). `src/ws_peers.rs` и `tests/ws_registration.rs` собираются с ней. |
| fix(hbbs): WebSocket registration honours MAX_MESSAGE_KB | `src/ws_peers.rs`, `src/rendezvous_server.rs` | `ws_peers::accept` использует `MAX_MESSAGE` upstream (по умолчанию 64 КиБ) как предел сообщения и кадра. Собственный тайм-аут рукопожатия в 10 с и обработка адреса от доверенного прокси (`X-Real-Port` или порт соединения, никогда не `:0`) закрывают для этого пути то, что upstream сделал в 474fbc7 / e5c0a42. |
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
  * `MAX_MESSAGE`, `WS_BUFFER_SIZE` и `WS_DEFAULT_MAX_FRAME_SIZE` сделаны
    `pub(crate)` для `ws_peers`;
  * модуль тестов: тесты Patina для WS добавлены после тестов upstream, а
    единственное изменение теста upstream — блокировка в `punch_reqs_bounded`.
* `src/relay_server.rs`: путь записи в relay (`send_bounded`, `write_deadline_ms`),
  обновление `last_recv_time` после завершённой записи, предел
  `MAX_WS_RELAY_MESSAGE` в `make_pair_` и константы рядом с ними.
* `Cargo.toml` и `Cargo.lock`: `Cargo.toml` отличается от upstream только
  dev-зависимостью `tokio` с `test-util`. `Cargo.lock` — это lock upstream, в котором крейты
  из реестра обновлены командой `cargo update`, поэтому версии из реестра в нём новее,
  чем у upstream; git-зависимости (reqwest, tokio-socks, async-speed-limit, confy,
  default_net, machine-uid, sysinfo, tungstenite, tokio-tungstenite) остаются на ревизиях
  upstream. Оба файла принадлежат Patina: они приходят из репозитория разработки. При
  rebase возьмите lock upstream, добавьте dev-зависимость Patina, выполните
  `cargo update`, затем верните каждую сдвинувшуюся git-зависимость на ревизию upstream:
  `cargo update -p <пакет>@<версия> --precise <полная-ревизия>` (`<версия>` берите из
  вывода `cargo update`, `<ревизия>` из `git show upstream/master:Cargo.lock`; режима
  «обновить только крейты из реестра» в cargo нет). Проверьте, что git-источники в
  `Cargo.lock` совпадают с upstream; старый lock upstream не сохраняйте.
* `src/lib.rs`: `mod ws_peers;`.
* `src/common.rs`: условие `SOFTWARE_UPDATE_CHECK` в начале
  `check_software_update()` и тест в конце модуля тестов.

`src/ws_peers.rs` и `tests/ws_registration.rs` — новые файлы, конфликтов в
них не будет. Но они зависят от `rendezvous_proto` из hbb_common,
`tokio-tungstenite` / `tungstenite` 0.29 (версия upstream) и `ipnetwork` 0.20 (из `Cargo.toml` upstream). Обновление любой из
этих зависимостей может сломать их при компиляции.

## Перенос на новый тег upstream

```bash
git fetch https://github.com/rustdesk/rustdesk-server --tags
# the old base is the upstream commit the series currently sits on
OLD_BASE=680b60395ecf99a76f74a1d934e453bb6e5e0aa2
NEW_BASE=<upstream tag or commit>
git switch -c rebase-$NEW_BASE <current patina branch>
git rebase --onto "$NEW_BASE" "$OLD_BASE"
git submodule update --init        # hbb_common at the new upstream pin
```

Затем, прежде всего остального:

1. **Прочитайте изменения upstream в перечисленных выше функциях**, а не
   только конфликты: `git diff $OLD_BASE $NEW_BASE -- src/rendezvous_server.rs
   src/peer.rs src/common.rs src/relay_server.rs Cargo.toml Cargo.lock`.
   В частности:
   * изменения upstream в relay в `src/relay_server.rs` должны сохранить
     масштабируемый срок записи (`send_bounded` заменяет плоский `timeout` в
     30 с вокруг `send_raw` у upstream, так что действует только один срок) и
     предел 32 МиБ для плеч после образования пары (`MAX_WS_RELAY_MESSAGE`
     вместо `usize::MAX` у upstream); предел upstream в 128 КиБ до образования
     пары остаётся;
   * если upstream меняет `tungstenite` / `tokio-tungstenite` в `Cargo.toml`,
     берите версию upstream (это больше не патч Patina) и чините
     `src/ws_peers.rs` и `tests/ws_registration.rs`, если они перестанут
     собираться;
   * любое изменение проверок UDP `RegisterPk` нужно внести в
     `register_pk()`, который теперь обслуживает оба транспорта;
   * для новых веток сообщений в `handle_tcp` нужно решить, относятся ли они
     к WebSocket-устройствам (`ws_conn`);
   * изменения ключей `tcp_punch` или того, как вычисляется `addr` для WS
     (upstream до e5c0a42 заменял его на `IP:0`, а с e5c0a42 сохраняет порт
     соединения с прокси), должны сохранять уникальность адресов для каждого
     соединения;
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
7. Обновите базовый коммит в начале этого файла и таблицы «Отличия от upstream» (предел, который upstream теперь обеспечивает сам, переходит в список «больше не патчи Patina» с номером коммита).

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
