# AGENTS.md — контекст форка Cribe

> **Прочитать первым перед любыми изменениями в этом форке.**
>
> Этот файл — постоянная справка по отличиям `landco-debug/cribe` от оригинального
> `pnazarovich/cribe`. Он нужен, чтобы новый чат/агент быстро восстановил контекст и
> не отменил уже сделанные решения.
>
> После каждой новой функции или архитектурной правки обновлять этот файл в том же коммите
> или сразу следующим документационным коммитом.

## 1. Что это за репозиторий

- Fork: `landco-debug/cribe`
- Upstream: `pnazarovich/cribe`
- Исходная база форка: Cribe 0.4.1, upstream commit
  `b8efbe2233c8368dc32bdfdcdbefb76521859033`.
- Цель форка: сохранять штатное поведение Cribe и добавлять небольшие пользовательские
  функции с минимальным архитектурным отклонением от upstream.
- Основной принцип: **не переписывать рабочие механизмы, если задачу можно решить расширением
  уже существующей логики Cribe**.

## 2. Добавлено: левая пара Command / Option

### Задача

В оригинальном Cribe штатная схема использует:

- правый Command — обычная диктовка;
- правый Option — диктовка с переводом.

В форк добавлена симметричная схема:

- **левый Command** — обычная диктовка;
- **левый Option** — диктовка с переводом.

В настройках пользователь выбирает сторону:

- `Правый ⌘`
- `Левый ⌘`
- `Свой шорткат`

### Критическое требование поведения

Левый Command/Option должны ощущаться так же нативно, как штатная правая пара.

Cribe не должен запускать диктовку, когда модификатор используется в обычном сочетании:

- Cmd-C
- Cmd-V
- Cmd-A
- Cmd-Tab
- Option-Left / Option-Right
- Command-click
- Command-drag
- Command-scroll
- другие аккорды

Диктовка запускается только на **чистом одиночном нажатии и отпускании** выбранного
модификатора. Долгое удержание также не считается тапом.

### Реализация

Файлы:

- `Sources/CribeCore/Support/AppSettings.swift`
  - в `HotkeyMode` добавлен `.leftCommand`.

- `Sources/CribeCore/Support/ModifierTapDetector.swift`
  - добавлены физические коды и device flags:
    - left Command: keyCode `55`, flag `0x08`
    - left Option: keyCode `58`, flag `0x20`
  - штатные правые значения не изменялись:
    - right Command: keyCode `54`, flag `0x10`
    - right Option: keyCode `61`, flag `0x40`

- `Sources/Cribe/App.swift`
  - добавлены `leftCommandTap` и `leftOptionTap`;
  - они используют тот же `ModifierKeyTap`, что и правая сторона;
  - активна только выбранная сторона;
  - при выборе левой стороны правые modifier taps снимаются;
  - при выборе правой стороны левые modifier taps снимаются;
  - в режиме custom обе пары снимаются;
  - логирование Accessibility теперь учитывает выбранную сторону.

- `Sources/Cribe/SettingsView.swift`
  - в Picker добавлен пункт `Левый ⌘`;
  - подпись под настройкой сообщает, что левый Option запускает перевод.

- `Sources/Cribe/Panel/NoticePanel.swift`
  - подсказки корректно называют правый или левый Command.

- `Tests/CribeCoreTests/ModifierTapDetectorTests.swift`
  - добавлены тесты чистого тапа левого Command;
  - отмены при обычном аккорде;
  - поведения левого Option;
  - блокировки пары Command + Option.

### Что НЕ менять без отдельной причины

Не заменять этот механизм на обычный global hotkey.
Ключевая особенность реализации Cribe — `CGEventTap` + `flagsChanged` +
`ModifierTapDetector`, благодаря чему одиночный modifier tap не конфликтует с обычными
macOS-сочетаниями.

### Режим удержания (push-to-talk)

В форке добавлен второй вариант поведения для левой/правой пары:

- **Нажатие — старт / стоп** — прежнее поведение Cribe, остаётся по умолчанию.
- **Удержание — пока зажата** — запись живёт только пока выбранный ⌘ удерживается;
  соответствующий ⌥ делает то же самое с переводом.

Режим хранится в `AppSettings.dictationKeyBehavior`. На пользовательские шорткаты
`KeyboardShortcuts` он намеренно не распространяется: они сохраняют обычное toggle-поведение.

#### Как не ломаются сочетания macOS

Push-to-talk не стартует мгновенно на `flagsChanged`: сначала проходит защитное окно
`ModifierHoldDetector.activationDelay = 0.60` с. Это тот же порог, который upstream
использует как `ModifierTapDetector.holdLimit` для отличия короткого одиночного тапа
от долгого удержания. Если до его конца приходит другая клавиша, модификатор, клик,
drag, scroll или системная consumer-клавиша, ожидаемый старт снимается.

На самом первом событии выбранной ⌘/⌥ дополнительно проверяются уже зажатые Shift,
Control, Fn и другое семейство модификатора. Это важно для сценариев вроде
Shift+Option+Volume: Shift мог быть нажат раньше, поэтому после Option отдельного
`flagsChanged` для Shift уже не будет.

Специальные клавиши громкости/яркости/медиа в macOS приходят как `NSSystemDefined`,
а не как обычный `keyDown`. Их raw event type тоже включён в event mask и отменяет
ожидаемый/активный hold.

Если обычный аккорд начался уже после активации hold, текущая запись отменяется и
выбрасывается, а системное событие всё равно проходит дальше. `ModifierKeyTap` по-прежнему
создаётся как `.listenOnly`, поэтому Cribe не съедает Cmd-C, Cmd-V, Cmd-Tab,
Option-Left/Right, Command-click и другие системные действия.

Архитектурное ограничение: пассивный listener не умеет предсказывать будущее. Если человек
намеренно держит выбранный модификатор дольше 0,6 с и только потом нажимает вторую клавишу,
Cribe уже мог начать hold-сессию и затем отменит её на аккорде. Полностью исключить это
при любом интервале можно только активным перехватом/задержкой исходных событий и их
последующим replay (Karabiner-style lazy modifier). Для форка это пока сознательно не
используется: upstream построен на `.listenOnly`, чтобы не задерживать и не подменять
системные сочетания.

#### Escape и отпускание после отмены

Для push-to-talk в `DictationController` добавлены раздельные входы:

- `startDictation(...)` — может только начать;
- `finishDictation()` — может только закончить существующую запись.

Это нельзя заменять на `toggle()` для release-события. Иначе сценарий
«держим ⌘ → Esc отменил → отпустили ⌘» запустил бы новую запись на отпускании.

Esc остаётся глобальным listen-only `KeyDownTap` и во время удержания вызывает
`cancelDictation()`: звук выбрасывается, распознавание/чистка/вставка не запускаются,
а последующее отпускание — no-op.

#### Итоговая спецификация hold-to-dictate после реальных тестов

Этот подраздел — полный handoff по функции из отдельного чата. Его нужно читать целиком
перед любыми дальнейшими изменениями хоткеев: функция уже прошла несколько итераций
исправлений на реальном macOS Sequoia и не должна быть упрощена обратно до «таймер +
flagsChanged».

##### Пользовательское поведение

Для выбранной стороны (`Правый ⌘` или `Левый ⌘`) в настройках есть два режима:

- **Нажатие — старт / стоп** — прежнее поведение Cribe;
- **Удержание — пока зажата** — push-to-talk.

В hold-режиме:

- выбранный ⌘ запускает обычную диктовку после защитного удержания ~0,6 с;
- соответствующий ⌥ делает то же самое, но с переводом;
- отпускание физической клавиши завершает только существующую запись и отправляет её
  в распознавание;
- быстрый tap модификатора ничего не делает;
- пользовательские `KeyboardShortcuts` остаются toggle и к hold-режиму не привязаны;
- режим сохраняется через `AppSettings.dictationKeyBehavior`;
- default остаётся `.toggle`, чтобы обновление форка не меняло привычное поведение само.

##### Escape

Во время hold-сессии `Esc` должен полностью **отменить** запись:

- аудио выбрасывается;
- транскрибация/cleanup/вставка не запускаются;
- последующее отпускание всё ещё физически зажатого ⌘/⌥ является no-op.

Для этого в `DictationController` существуют отдельные методы:

- `startDictation(translating:)`;
- `finishDictation()`.

**Не заменять release-событие на `toggle()`**. Иначе после сценария
`hold → Esc → release` отпускание запустит новую пустую запись.

##### Совместимость с обычными сочетаниями macOS

Режим должен оставаться максимально нативным и не «съедать» системные действия.

`ModifierKeyTap` остаётся `CGEventTap(... options: .listenOnly ...)`, то есть Cribe не
подавляет исходные события и не делает synthetic replay.

Защитный порог hold — **0,60 с** (`ModifierHoldDetector.activationDelay`), совпадает с
upstream `ModifierTapDetector.holdLimit`.

До старта и во время hold аккорд отменяют:

- `keyDown` и `keyUp`;
- left/right/other mouse down/up;
- left/right/other mouse drag;
- scroll wheel;
- другой modifier;
- системные consumer keys (Volume/Brightness/Media), которые приходят как
  `NSSystemDefined`.

На первом `flagsChanged` выбранной ⌘/⌥ также проверяются уже удерживаемые Shift,
Control, Fn и противоположная клавиша того же семейства. Это закрывает случаи, когда
другой modifier был нажат раньше и нового события от него уже не будет.

Проверенные классы сочетаний, которые не должны запускать/оставлять диктовку:

- Cmd-C / Cmd-V / Cmd-A / Cmd-Tab;
- Option-Left / Option-Right;
- Command-click / drag / scroll;
- Shift+Option+Volume Up/Down;
- Option + работа с alternate-item в нативном меню macOS.

##### Отдельный баг: Option + модифицированное меню

Нативные `NSMenu` используют nested event-tracking loop. В реальном тесте это приводило
к сценарию:

`Option hold → неторопливый click по alternate menu item → release Option`

При одной только event-tap state machine конкретный mouse/flagsChanged callback мог
дойти с задержкой относительно фактического состояния WindowServer. Запись могла
остаться активной после физического release и требовать `Esc`.

Финальное исправление добавляет **резервную сверку с WindowServer**, не меняя
`.listenOnly` архитектуру:

- `CGEventSource.keyState(.combinedSessionState, key:)` — реально ли удерживается
  конкретная левая/правая ⌘/⌥;
- `CGEventSource.flagsState` — нет ли блокирующих modifiers;
- `CGEventSource.buttonState` — нет ли физически удерживаемой кнопки мыши;
- `CGEventSource.counterForEventType` — менялись ли key/mouse/drag/scroll события после
  снимка на press.

На press сохраняется baseline этих счётчиков. Перед стартом hold состояние сверяется
повторно. После старта работает watchdog примерно раз в 25 мс.

При конфликте приоритет такой:

1. обнаружен click/key/scroll/другой modifier → **cancel**;
2. только физический release выбранной клавиши → **finish**;
3. клавиша всё ещё удерживается и побочного ввода нет → **keep**.

Особенно важно: если после menu tracking одновременно видны и click, и уже отпущенный
Option, **cancel имеет приоритет над finish**. Это системный жест с Option, а не диктовка.

Перед обычным `finishHold()` выполняется ещё одна сверка WindowServer, чтобы задержанный
menu-click не был ошибочно принят за нормальное окончание записи.

##### Архитектурное ограничение

Пассивный `.listenOnly` listener не умеет знать будущее. Если человек намеренно держит
выбранный modifier дольше 0,6 с, дождался старта диктовки и только потом начал системный
аккорд, окно записи теоретически может кратко появиться до второго события. Как только
второе событие появляется, сессия отменяется.

Полностью устранить даже краткий старт можно только активной схемой уровня Karabiner
`lazy modifier`: задерживать исходный modifier, а затем решать, передавать его системе
или использовать как hold. Это намного более инвазивно и сознательно **не внедрено**,
пока нет отдельной задачи изменить базовую архитектуру ввода.

##### Файлы этой функции

- `Sources/CribeCore/Support/AppSettings.swift`
  - `DictationKeyBehavior { toggle, hold }`;
  - persistence `dictationKeyBehavior`.

- `Sources/CribeCore/Support/ModifierTapDetector.swift`
  - `ModifierHoldDetector`;
  - `ModifierHoldAction`;
  - activation delay = upstream hold limit 0,6 с.

- `Sources/Cribe/ModifierKeyTap.swift`
  - режимы tap/hold;
  - listen-only CGEventTap;
  - расширенная event mask;
  - `NSSystemDefined`;
  - pre-held modifier blocking;
  - WindowServer baseline + reconciliation + watchdog;
  - правило cancel > finish при menu interaction.

- `Sources/Cribe/App.swift`
  - wiring hold gestures для правой/левой пары ⌘/⌥;
  - обычная диктовка и диктовка с переводом;
  - реакция на изменение `dictationKeyBehavior`.

- `Sources/Cribe/SettingsView.swift`
  - Picker `Режим кнопки`;
  - подписи hold-режима.

- `Sources/CribeCore/Pipeline/DictationController.swift`
  - `startDictation(translating:)`;
  - `finishDictation()`;
  - release после Esc безопасен и не перезапускает запись.

- `Tests/CribeCoreTests/ModifierTapDetectorTests.swift`
  - hold threshold;
  - quick tap;
  - chord cancellation;
  - pre-held modifier blocking.

- `Tests/CribeCoreTests/AppSettingsTests.swift`
  - default `.toggle`;
  - persistence `.hold`.

- `Tests/CribeCoreTests/DictationControllerTests.swift`
  - hold start/release;
  - `Esc → release` не запускает новую запись.

- `Tests/CribeAppTests/ModifierHoldReconciliationTests.swift`
  - keep/release/cancel;
  - `menu click + release => cancel`.

##### Ключевые commits по этой функции

- `6dd2fb5209848478ac431be0c8b68532258ae3a8`
  — первая рабочая реализация hold-to-dictate;
- `2f28162923f3ed352e50777cdf077d0e6ef95556`
  — защита от системных shortcut conflicts, 0,6 с, consumer keys;
- `5c4505b16f61df09def13890bcba0efc37461933`
  — финальный на данный момент fix Option/menu tracking и stuck recording.

На commit `5c4505b16f61df09def13890bcba0efc37461933` успешно прошли:

- `swift build`;
- CribeCoreTests;
- CribeAppTests;
- официальный `scripts/build-app.sh`;
- `codesign --verify --deep --strict`;
- упаковка готового `Cribe.app`.

После установки этой сборки пользователь подтвердил в реальном использовании:
**«Вроде бы всё работает как надо»**.
## 3. GitHub Actions: готовый Cribe.app

В upstream уже был `.github/workflows/ci.yml`, который делает `swift build` и тесты,
но не формирует готовый `.app`.

В форке добавлен:

- `.github/workflows/build-app.yml`

Он:

1. запускается на `macos-26`;
2. вызывает официальный `bash scripts/build-app.sh`;
3. проверяет бандл через
   `codesign --verify --deep --strict --verbose=2 dist/Cribe.app`;
4. упаковывает `Cribe.app` через `ditto`;
5. публикует Artifact:
   `Cribe-macOS-Apple-Silicon`.

Таким образом локальный Xcode/toolchain пользователю не нужен.

### Проверенный результат

На commit `d616e9f1fe9d197662fa0f641b4880225a5928f6` успешно прошли:

- штатный `swift build`;
- CribeCoreTests;
- CribeAppTests;
- официальный `scripts/build-app.sh`;
- строгая проверка codesign;
- упаковка и upload готового Artifact.

## 4. Официальные автообновления upstream отключены

### Почему

Fork использует тот же Bundle ID, что оригинальный Cribe:

`online.nazarovych.cribe`

Если оставить официальный Sparkle feed upstream, приложение может предложить официальное
обновление и заменить fork версией без наших изменений.

### Что изменено

Commit:
`d616e9f1fe9d197662fa0f641b4880225a5928f6`
(`Disable upstream updates in fork build`)

- `Info.plist`
  - удалён официальный `SUFeedURL`;
  - удалён upstream `SUPublicEDKey`;
  - удалён `SUScheduledCheckInterval`;
  - `SUEnableAutomaticChecks` установлен в `false`.

- `Sources/Cribe/App.swift`
  - больше не вызывается `UpdateController.shared.start()`.

- `Sources/Cribe/MenuBarView.swift`
  - удалена строка найденного обновления;
  - удалён пункт ручной проверки обновлений;
  - `UpdateController` больше не передаётся в меню.

### Важно: известный хвост UI

На момент создания этого файла в
`Sources/Cribe/SettingsView.swift` всё ещё остался видимый тумблер:

`Проверять обновления автоматически`

и пояснение под ним.

Это **мёртвый UI**: updater в fork уже не стартует, а официальный feed удалён.
Сам тумблер ничего полезного не делает.

Следующая безопасная косметическая правка — удалить:

- `@ObservedObject private var updates = UpdateController.shared` из `GeneralPane`;
- сам Toggle автообновлений;
- пояснение «Проверка идёт раз в сутки…».

Это не должно затрагивать диктовку или остальные настройки.

### Почему Sparkle пока не удалён полностью

Зависимость Sparkle и `Updater.swift` пока оставлены намеренно, чтобы не расширять
изменения дальше необходимого. Полное удаление Sparkle — отдельная cleanup-задача:
оно затронет Package.swift, build scripts и упаковку framework.

Не делать это попутно с новой пользовательской функцией.

## 5. Установка fork поверх оригинального Cribe

Fork сохраняет:

- имя приложения `Cribe`;
- Bundle ID `online.nazarovych.cribe`;
- версию 0.4.1 / build 17 на текущей базе.

Поэтому fork устанавливается заменой оригинального
`/Applications/Cribe.app`.

Плюс этого подхода: существующие UserDefaults и данные Cribe сохраняются.

### Ad-hoc подпись и системные разрешения

GitHub-сборка использует ad-hoc подпись, если нет Developer certificate.

Из-за отличия подписи от официального приложения macOS может повторно попросить:

- доступ к записи Cribe в Keychain;
- Accessibility;
- Microphone.

Это ожидаемое поведение, а не ошибка приложения.

Если modifier hotkeys после замены приложения не работают:

1. System Settings → Privacy & Security → Accessibility;
2. выключить/включить Cribe;
3. если не помогло — удалить старую запись Cribe из списка и добавить заново
   `/Applications/Cribe.app`;
4. полностью перезапустить Cribe.

Для modifier taps отдельный Input Monitoring не требуется.

Пользователь уже подтвердил, что после обновления Accessibility левая схема работает.

## 6. Минимальный smoke-test после любой правки хоткеев

Перед тем как считать новую сборку готовой, проверить вручную на Mac:

1. `Левый ⌘`: чистый tap запускает/останавливает диктовку.
2. `Левый ⌥`: запускает диктовку с переводом.
3. Cmd-C / Cmd-V / Cmd-A / Cmd-Tab не запускают Cribe.
4. Option-Left / Option-Right не запускают Cribe.
5. в режиме «Нажатие» удержание левого Command примерно 1 секунду не запускает диктовку.
6. переключение на `Правый ⌘` возвращает штатную правую пару.
7. реальная диктовка вставляет текст в обычное поле.
8. выбранная сторона сохраняется после перезапуска Cribe.

Для режима «Удержание» дополнительно:

1. быстрый tap выбранного ⌘ ничего не запускает;
2. hold дольше ~0,6 с запускает запись, отпускание отправляет её в распознавание;
3. соответствующий ⌥ делает тот же hold с переводом;
4. Cmd-C / Cmd-V / Cmd-A / Cmd-Tab и Option-Left / Option-Right работают штатно и не
   оставляют диктовку;
5. Shift+Option+Volume Up/Down и другие consumer-key аккорды не показывают окно записи;
6. Option + неторопливый click по меню с alternate-item не оставляет запись висеть:
   click отменяет hold, а release после menu tracking не должен требовать Esc;
7. Esc во время hold отменяет запись, а последующее отпускание не запускает новую;
8. переключение «Нажатие ↔ Удержание» сохраняется после перезапуска.

## 7. Правила для следующих функций форка

Каждую новую функцию желательно вести отдельным чатом, но изменения должны накапливаться
в этом же fork.

Перед работой:

1. прочитать этот `AGENTS.md`;
2. сравнить текущий `main` с upstream, если задача касается существующего механизма;
3. не удалять предыдущие fork-правки;
4. использовать существующую архитектуру Cribe там, где это возможно.

После работы:

1. добавить/обновить тесты;
2. дождаться зелёного `CI`;
3. дождаться зелёного `Build Cribe.app`;
4. проверить Artifact;
5. **обновить раздел 8 этого файла**.

## 8. Журнал изменений fork

### 2026-09-23 — Hold menu-tracking stuck-recording fix

После реального теста найден отдельный класс бага: Option меняет alternate items в
нативных меню macOS, а nested menu-tracking loop может задержать доставку конкретного
mouse/flagsChanged события в нашем event tap. В результате hold мог стартовать, release
мог не дойти вовремя, и окно записи оставалось висеть до Esc.

Исправление не переводит Cribe на активный перехват. К пассивному `.listenOnly` event tap
добавлена резервная сверка с состоянием WindowServer:

- `CGEventSource.keyState(.combinedSessionState, key:)` подтверждает, что конкретный
  левый/правый ⌘/⌥ всё ещё реально зажат;
- `CGEventSource.flagsState` ловит блокирующие modifiers;
- `CGEventSource.buttonState` ловит уже удерживаемую кнопку мыши;
- `CGEventSource.counterForEventType` запоминает счётчики keyDown/mouseDown/drag/scroll
  на press и обнаруживает click даже если callback был задержан menu tracking;
- если одновременно обнаружены click и release, **cancel имеет приоритет над finish**:
  это системный аккорд, а не законченная диктовка;
- активный hold имеет watchdog, поэтому потерянный/задержанный release больше не может
  оставить вечную запись до Esc.

Подход соответствует практике зрелых macOS automation tools: Hammerspoon напрямую читает
состояние modifier-клавиш через `CGEventSourceKeyState`, а Karabiner отдельно ведёт
физическое pressed-state и защищается от несбалансированных key_down/key_up, чтобы не
получать stuck keys.

Основной commit:
`5c4505b16f61df09def13890bcba0efc37461933`.

Реальная проверка пользователем после установки: поведение подтверждено как рабочее.

### 2026-09-23 — Hold shortcut conflict hardening

После реального теста режима удержания исправлены ложные старты на системных сочетаниях:

- порог hold поднят с 0,20 до 0,60 с — совпадает с upstream `holdLimit`;
- уже зажатые Shift/Control/Fn/другое семейство блокируют старт сразу;
- `NSSystemDefined` (volume/brightness/media) добавлен в наблюдаемые события;
- добавлены right/other mouse drag как отменяющие аккорд;
- сохранён пассивный `.listenOnly` подход upstream без подавления и replay системных событий.

Причина исходного дефекта: 200 мс были слишком коротким окном, а consumer keys вообще
не входили в старую маску событий. В результате системный shortcut проходил корректно,
но hold-сессия успевала кратко стартовать параллельно.

Основной commit:
`2f28162923f3ed352e50777cdf077d0e6ef95556`.

### 2026-09-23 — Hold-to-dictate

Добавлен режим «Удержание — пока зажата» для выбранной левой/правой пары ⌘/⌥.
Он расширяет существующий listen-only CGEventTap, а не вводит перехватывающий
механизм. В первой реализации использовались защитные 200 мс; после реального тестирования
порог увеличен до 0,60 с и добавлены отдельные защиты для system shortcuts и menu tracking.
Esc выбрасывает живую запись, release после Esc ничего не делает.

Первоначальный commit:
`6dd2fb5209848478ac431be0c8b68532258ae3a8`.

### 2026-09-23 — Left Command / Option

Добавлен выбор левой пары модификаторов как нативная альтернатива штатной правой паре.
Реализация расширяет существующий ModifierKeyTap/ModifierTapDetector, а не вводит второй
механизм хоткеев.

Основной commit:
`fd75a67254359a49f3444648894da7504adeb50d`

### 2026-09-23 — GitHub build Artifact

Добавлен `.github/workflows/build-app.yml`, который собирает настоящий Cribe.app
официальным `scripts/build-app.sh` и публикует Apple Silicon Artifact.

Основной commit:
`fd75a67254359a49f3444648894da7504adeb50d`

### 2026-09-23 — защита fork от upstream auto-update

Официальный Sparkle feed отключён, чтобы официальный релиз Cribe не мог заменить fork.

Основной commit:
`d616e9f1fe9d197662fa0f641b4880225a5928f6`

---

Если фактический код расходится с этим файлом, считать код источником истины,
а затем немедленно актуализировать `AGENTS.md`.
