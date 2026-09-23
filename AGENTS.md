# AGENTS.md — контекст форка Cribe

> **Прочитать первым перед любыми изменениями в этом форке.**
>
> Этот файл — постоянная справка по отличиям `landco-debug/cribe` от оригинального
> `pnazarovich/cribe`. Он нужен, чтобы новый чат/агент быстро восстановил контекст и
> не отменил уже сделанные решения.
>
> После каждой новой функции или архитектурной правки обновлять этот файл в том же коммите
> или сразу следующим документационным коммитом.

## 0. Глобальное правило: говорящие имена артефактов и сборок

**Это правило действует для всего репозитория, всех текущих и будущих веток, всех подпроектов и всех отдельных сборок. Оно выше локальных соглашений конкретного подпроекта.**

Любой создаваемый бинарник и всё, что непосредственно связано с его сборкой или выдачей пользователю, должно иметь **говорящее имя**, по которому без открытия файла понятно, к какому подпроекту и варианту сборки оно относится.

К этому относятся, в частности:

- готовые бинарники и app bundles, если их внешнее имя можно менять безопасно;
- ZIP / DMG / PKG и другие выдаваемые архивы;
- GitHub Actions Artifacts и release assets;
- имена build-workflow/job, когда они относятся к отдельной сборке;
- каталоги и файлы, созданные специально для конкретного подпроекта/варианта сборки;
- связанные handoff/summary/отчёты и подразделы `AGENTS.md`, если они описывают конкретную сборку или подпроект.

### Требования к имени

Имя должно отражать минимум:

`Продукт + подпроект/функция + платформа/архитектура`

а если внутри одного подпроекта существует несколько различимых сборок — также вариант, назначение, версию или короткий commit SHA.

Примеры:

- `Cribe-GigaAM-GGUF-TranscribeCpp-macOS-Apple-Silicon.zip`
- `Cribe-HoldToDictate-macOS-Apple-Silicon.zip`
- `Cribe-GigaAM-GGUF-TranscribeCpp-smoke-<shortSHA>.zip`

**Не использовать безликие имена** вроде `build.zip`, `artifact.zip`, `final.zip`, `working.zip`, `Cribe-macOS-Apple-Silicon.zip`, если рядом могут существовать сборки разных подпроектов или стадий.

Все связанные сущности одной сборки должны по возможности использовать **один и тот же смысловой stem**. Например, если архив называется
`Cribe-GigaAM-GGUF-TranscribeCpp-macOS-Apple-Silicon.zip`, Artifact и соответствующий workflow/subsection должны также содержать `GigaAM-GGUF-TranscribeCpp`.

Исключение: внутреннее каноническое имя, которое нельзя безопасно менять без риска для bundle ID, подписи, runtime, путей обновления или пользовательского UX (например, `Cribe.app` внутри архива), может оставаться штатным. В этом случае **внешний контейнер/Artifact обязан быть говорящим**.

Перед выдачей любой новой сборки пользователю агент обязан проверить имя ещё раз. Если из имени нельзя однозначно понять, чем эта сборка отличается от других, имя считается неправильным и должно быть исправлено до выдачи.

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

### 2026-09-23 — Настраиваемый автостоп по тишине + страховочный лимит записи

Эта функция добавлена **поверх последней рабочей hold/menu-fix базы**
`5c4505b16f61df09def13890bcba0efc37461933`. Существующая логика hold-to-dictate,
левая/правая пара ⌘/⌥ и WindowServer watchdog не переписывались.

#### Пользовательское поведение

В разделе «Распознавание» вместо жёсткого `Автостоп по тишине (2 с)` теперь есть:

- `Автостоп по тишине` — отдельный включатель;
- `Пауза тишины` — настраиваемое значение **0,5…30 с** с шагом 0,5 с;
- default остаётся **2,0 с**;
- сам автостоп, как и раньше, по умолчанию **выключен**.

Добавлена независимая вторая страховка:

- `Страховочный стоп записи` — отдельный включатель;
- `Максимальная запись` — **15…600 с** с шагом 5 с;
- default — **60 с**;
- страховочный стоп по умолчанию **выключен**, чтобы обновление не обрезало привычные
  длинные диктовки без явного выбора пользователя.

Страховочный стоп не отменяет диктовку и не выбрасывает звук. Когда лимит истёк,
он вызывает штатный `stopAndProcess()`: уже записанное аудио идёт в обычное
распознавание, cleanup, историю и вставку так же, как при ручном стопе.

#### Архитектура и важные правила

Первый таймер остаётся частью VAD:

- `VadGate` больше не держит жёсткий `minSilenceDuration: 2.0`;
- `SpeechGating.resetStream(silenceDuration:)` получает порог для очередной записи;
- значение `settings.autoStopSilenceSeconds` снимается **один раз при старте сессии**;
- изменение настройки во время уже идущей диктовки начинает действовать только со
  следующей записи — VAD не перестраивается на полуслове.

Второй таймер реализован отдельно от VAD в `DictationController`:

- `recordingLimitTask` стартует **после фактического `recorder.start`**, поэтому
  подготовка/прогрев модели не съедает лимит;
- таймер привязан к конкретному объекту `DictationSession`;
- перед автостопом дополнительно проверяется `self.recording === session`;
- старый deadline предыдущей записи не имеет права остановить следующую;
- задача обязательно отменяется при ручном стопе, VAD-автостопе, Esc/discard,
  сбое захвата и перед стартом новой записи.

Это критическое правило: **не упрощать страховочный таймер до общего
`Task.sleep(...) { stopAndProcess() }` без привязки к сессии**, иначе при быстрых
последовательных диктовках просроченная задача способна оборвать уже другую запись.

#### Настройки и persistence

В `AppSettings` добавлены:

- `autoStopSilenceSeconds: Double` — default 2,0;
- `recordingLimitEnabled: Bool` — default false;
- `recordingLimitSeconds: Double` — default 60,0.

Все три значения сохраняются через `UserDefaults`. Старый
`autoStopEnabled` сохранён без миграции/переименования, поэтому существующий выбор
пользователя не сбрасывается.

#### Изменённые файлы

- `Sources/CribeCore/Support/AppSettings.swift`
  — новые настройки и persistence.
- `Sources/Cribe/SettingsView.swift`
  — два независимых таймера и их Stepper UI.
- `Sources/CribeCore/Audio/VadGate.swift`
  — настраиваемый `minSilenceDuration` на конкретную запись.
- `Sources/CribeCore/Pipeline/DictationController.swift`
  — независимый session-bound safety timeout и его lifecycle.
- `Tests/CribeCoreTests/AppSettingsTests.swift`
  — defaults и persistence обоих таймеров.
- `Tests/CribeCoreTests/DictationControllerTests.swift`
  — передача выбранной паузы в VAD, штатный стоп по абсолютному лимиту и регрессия
  «таймер предыдущей записи не останавливает следующую».
- `Tests/CribeCoreTests/RetranscribeTests.swift`
  — тестовый `FailingVad` обновлён под новый контракт `SpeechGating`.

#### Проверка и сборка

Во время первого CI после изменения контракта `SpeechGating` обнаружен только тестовый
регресс: `FailingVad` в `RetranscribeTests.swift` ещё реализовывал старый
`resetStream()`. Production-код к этому моменту уже собирался. Stub обновлён на
`resetStream(silenceDuration:)`, после чего полный CI прошёл успешно.

Код функции финализирован commit:
`b0d3ccd26d198bfb7a20522f33041ba4ce416839`.

Для него успешно прошли:

- `swift build`;
- CribeCoreTests;
- CribeAppTests;
- официальный `scripts/build-app.sh`;
- `codesign --verify --deep --strict`;
- упаковка и upload готового `Cribe.app` Artifact.

GitHub Actions:

- CI run `35898429860` — **success**;
- Build Cribe.app run `35898429577` — **success**;
- Artifact `Cribe-macOS-Apple-Silicon`, id `10767832902`.

Пользователь установил итоговую сборку и подтвердил:
**«Вроде бы всё работает как надо»**.

### 2026-09-23 — Подпроект GigaAM-GGUF-TranscribeCpp

Подпроект добавлен поверх `main`
`ba1e8e57d5deeea893eb04fd0a2d610033111e12` и не переписывает hold-to-dictate,
WindowServer watchdog или настраиваемые таймеры записи.

#### Что видит пользователь

В «Настройки → Общие → Модель распознавания» теперь живёт единый список:

- **Parakeet TDT v3** — прежний FluidAudio backend, остаётся default для существующих
  и новых установок;
- **GigaAM v3 E2E-RNN-T Q8_0** — штатная русская GGUF-модель;
- импортированные пользователем совместимые `.gguf`;
- кнопка **«Добавить GGUF…»**.

Для каждой модели UI показывает состояние, позволяет скачать/выбрать, а для GigaAM и
импортированных моделей — удалить. Выбор активной модели сохраняется в
`AppSettings.activeASRModelID`.

Импорт не доверяет расширению файла. Перед регистрацией Cribe реально открывает GGUF
через `transcribe.cpp`; неизвестные architecture/variant и повреждённые файлы
отбрасываются. Успешно импортированный файл копируется в управляемый каталог Cribe.

#### Runtime transcribe.cpp

Используется **handy-computer/transcribe.cpp v0.2.3**.

SwiftPM подключает официальный release artifact как binary target:

- asset: `TranscribeCpp.xcframework.zip`;
- SHA-256 / SwiftPM checksum:
  `944be4d5232f39c99608f676a2ddda2516e0ed3c9fb6db50685ffa8d20a8b9c9`;
- macOS arm64: Metal + CPU.

Поскольку отдельный SwiftPM mirror `TranscribeCpp` на момент интеграции ещё не
опубликован, официальный Swift wrapper **той же версии v0.2.3** vendored в
`Vendor/TranscribeCpp/Sources/TranscribeCpp`. Лицензия и third-party notices лежат
рядом в `Vendor/TranscribeCpp/`.

Не добавлять Python, localhost API, Tauri/Rust runtime или отдельный процесс:
`transcribe.cpp` работает внутри процесса Cribe.

#### Штатная GigaAM

Закреплена модель:

- `GigaAM v3 E2E-RNN-T Q8_0`;
- repo: `handy-computer/gigaam-v3-e2e-rnnt-gguf`;
- файл: `gigaam-v3-e2e-rnnt-Q8_0.gguf`;
- размер: `273724832` bytes (~261 MiB);
- SHA-256:
  `78d63b47723b7f8d78c6113a6ef983b5a86e2a86f6c273e1f5cb6967b1c4467a`;
- язык: русский;
- E2E-вариант сам выдаёт регистр и пунктуацию;
- translate/lang-detect модель не поддерживает.

Загрузка идёт во временный staging-файл. До переноса в постоянный каталог обязательно
проверяются SHA-256 и реальная загрузка через `TranscribeCppEngine.inspectModel`.
Повреждённый/подменённый файл активировать нельзя.

#### Где лежат модели

Управляемый каталог:

`~/Library/Application Support/Cribe/models/`

В нём:

- `gigaam-v3-e2e-rnnt-Q8_0.gguf` — штатная GigaAM;
- `imported/*.gguf` — пользовательские модели;
- `registry.json` — метаданные импортированных моделей.

Parakeet продолжает жить в штатном cache FluidAudio и не переносится в этот каталог.

#### Архитектура и lifecycle RAM

`TranscribeCppEngine` реализует существующий `TranscriptionEngine`. Поэтому основной
pipeline не раздвоен:

```text
DictationController
       ↓
EngineGate
       ↓
TranscriptionEngine
   ├── ParakeetEngine → FluidAudio
   └── TranscribeCppEngine → GGUF → transcribe.cpp → ggml/Metal
```

`EngineGate` теперь не владеет одной моделью пожизненно. Конкретный engine снимается в
`DictationSession` **на старте диктовки**. Это критично:

- переключение модели относится только к следующей диктовке;
- уже записанная/стоящая в очереди речь заканчивает обработку на старой модели;
- общий gate всё равно сериализует тяжёлые ASR-проходы;
- менеджер держит сильную ссылку только на текущий active engine;
- после переключения старый engine остаётся в RAM лишь пока существуют уже начатые с ним
  `DictationSession`, затем ARC освобождает модель/Metal resources.

Старый `DictationController(engine:...)` сохранён как convenience-init для тестов и CLI;
приложение использует новый `engineProvider`.

#### Ограничения совместимых GGUF

«GGUF» не означает «любая GGUF-модель». Cribe принимает только файл, который умеет
загрузить зафиксированная версия `transcribe.cpp` как ASR-модель.

Метаданные `general.architecture`, `stt.variant`, languages/capabilities читаются из
реально загруженной модели. Обычные текстовые LLM GGUF сюда не подходят.

GigaAM v3 обучена для сравнительно коротких utterance (ориентир transcribe.cpp — около
25 секунд). Runtime более длинную запись не отвергает, но предупреждает о возможном
снижении точности. Cribe пока не вводит отдельный GigaAM-only long-form splitter:
существующий VAD и общий pipeline остаются едиными для всех движков.

#### Изменённые/добавленные файлы

- `Package.swift`
  — binary target CTranscribe + vendored Swift wrapper target.
- `Vendor/TranscribeCpp/**`
  — официальный Swift binding v0.2.3, LICENSE и THIRD-PARTY-LICENSES.
- `Sources/CribeCore/ASR/TranscribeCppEngine.swift`
  — generic GGUF backend + runtime validation.
- `Sources/CribeCore/ASR/ASRModelID.swift`
  — стабильные persisted model IDs.
- `Sources/CribeCore/Support/AppSettings.swift`
  — persistence активной ASR-модели.
- `Sources/CribeCore/Pipeline/DictationController.swift`
  — engine snapshot на одну DictationSession и общий multi-engine gate.
- `Sources/Cribe/ModelInstall.swift`
  — единый registry/download/import/delete/lifecycle manager.
- `Sources/Cribe/App.swift`
  — provider активного движка и warm-up выбранной модели.
- `Sources/Cribe/SettingsView.swift`
  — список моделей, GigaAM download/select/delete, системный GGUF importer,
  transcribe.cpp credit.
- `Tests/CribeCoreTests/TranscribeCppEngineTests.swift`
  — invalid-GGUF gate + opt-in real-model smoke.
- `Tests/CribeCoreTests/AppSettingsTests.swift`
  — default/persistence выбора ASR.
- `Tests/CribeCoreTests/EngineGateTests.swift`
  — новый explicit-engine contract.
- `Tests/CribeAppTests/ModelInstallTests.swift`
  — built-ins, fallback при пропавшей модели, invalid import не попадает в registry.
- `.github/workflows/gigaam-smoke.yml`
  — отдельный real-model acceptance gate, чтобы обычный CI не скачивал ~261 MiB каждый раз.

#### Проверка до merge

Полный CI для feature-кода:

- run `35910850715` — **success**;
- `swift build` — success;
- CribeCoreTests — success;
- CribeAppTests — success.

Real-model GigaAM gate:

- run `35910850966` — **success**;
- скачан ровно закреплённый Q8_0;
- SHA-256 проверен;
- скачан официальный `transcribe.cpp/samples/ru.wav`;
- реальный `TranscribeCppEngine` на Q8_0 распознал:
  `Важно различать глаголы и дополнения.`
- результат совпал с опубликованным acceptance observable семейства GigaAM в
  `transcribe.cpp`.

#### Проверка после merge

В `main` подпроект вошёл squash-commit:
`26a17563f5c0a437b4b1dbd2e98588ba80cb8c71`.

Для этого exact tree успешно прошли:

- CI run `35911842210` — **success**;
- `swift build` — success;
- CribeCoreTests — success;
- CribeAppTests — success;
- `Build Cribe.app` run `35911842246` — **success**;
- `scripts/build-app.sh` — success;
- `codesign --verify --deep --strict` — success;
- упаковка и upload Artifact — success;
- Artifact исходной финальной проверки: `Cribe-macOS-Apple-Silicon` (id `10773881609`).

Именование итоговых сборок этого подпроекта далее: `Cribe-GigaAM-GGUF-TranscribeCpp-macOS-Apple-Silicon.zip`.

Итого: интеграция transcribe.cpp + GigaAM + universal GGUF находится в рабочем `main`,
а реальный GigaAM Q8_0 smoke и финальная .app-сборка подтверждены GitHub Actions.

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
