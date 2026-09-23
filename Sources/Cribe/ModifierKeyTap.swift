import AppKit
import CoreGraphics
import Foundation
import CribeCore

/// Слушает «голый» модификатор (по умолчанию правый ⌘) через CGEventTap.
///
/// В режиме toggle чистый короткий tap распознаёт `ModifierTapDetector`; в режиме hold
/// `ModifierHoldDetector` даёт push-to-talk с защитным окном от обычных системных аккордов.
/// Event tap только слушающий (`.listenOnly`): чужие ⌘/⌥-события проходят нетронутыми.
/// Нужен Accessibility — тот же, что и для вставки текста.
enum ModifierKeyGesture: Sendable {
    case tap
    case holdBegan
    case holdEnded
    case holdCancelled
}

/// Решение резервной сверки с состоянием WindowServer.
/// Порядок принципиален: если click и release обнаружились одновременно после menu
/// tracking, click означает системный аккорд, поэтому отмена сильнее обычного завершения.
enum ModifierHoldReconciliation: Equatable {
    case keep
    case cancel
    case release
}

func modifierHoldReconciliation(
    inputChanged: Bool,
    blockingModifierDown: Bool,
    mouseButtonDown: Bool,
    keyDown: Bool
) -> ModifierHoldReconciliation {
    if inputChanged || blockingModifierDown || mouseButtonDown {
        return .cancel
    }
    return keyDown ? .keep : .release
}

@MainActor
final class ModifierKeyTap {
    /// NSSystemDefined (raw 14) — именно этим типом AppKit/HID доставляет специальные
    /// системные клавиши вроде громкости и яркости. В CGEventType у него нет именованного
    /// case, но event tap этот raw type видит.
    private static let systemDefinedRawValue = UInt32(NSEvent.EventType.systemDefined.rawValue)

    /// Клавиатура, системные consumer keys и мышь: всё, чем можно составить аккорд с
    /// модификатором. Само содержимое события нас не интересует — только факт, что оно было.
    private static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .flagsChanged,
            .keyDown,
            .keyUp,
            .leftMouseDown,
            .leftMouseUp,
            .rightMouseDown,
            .rightMouseUp,
            .otherMouseDown,
            .otherMouseUp,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .scrollWheel,
        ]
        var mask = types.reduce(into: CGEventMask(0)) { $0 |= CGEventMask(1) << $1.rawValue }
        mask |= CGEventMask(1) << systemDefinedRawValue
        return mask
    }()

    /// Модификаторы, которые делают нажатие нашей ⌘/⌥ частью системного аккорда.
    /// Caps Lock намеренно не входит: его включённое состояние не должно запрещать диктовку.
    private static let chordModifierFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn,
    ]

    /// Расхождение со `systemUptime`, после которого штамп события считаем недостоверным.
    private static let timestampTolerance: TimeInterval = 5

    /// Счётчики WindowServer — резервный источник истины на случай, если nested menu
    /// tracking задержал доставку конкретного mouse/key события в наш event tap.
    /// Нам не важно содержание события: любое изменение означает, что modifier уже стал
    /// частью аккорда и hold-сессия должна быть отменена.
    private struct InputCounters: Equatable {
        let keyDown: UInt32
        let keyUp: UInt32
        let leftMouseDown: UInt32
        let leftMouseUp: UInt32
        let rightMouseDown: UInt32
        let rightMouseUp: UInt32
        let otherMouseDown: UInt32
        let otherMouseUp: UInt32
        let leftMouseDragged: UInt32
        let rightMouseDragged: UInt32
        let otherMouseDragged: UInt32
        let scrollWheel: UInt32

        static func current() -> Self {
            let state: CGEventSourceStateID = .combinedSessionState
            return Self(
                keyDown: CGEventSource.counterForEventType(state, eventType: .keyDown),
                keyUp: CGEventSource.counterForEventType(state, eventType: .keyUp),
                leftMouseDown: CGEventSource.counterForEventType(state, eventType: .leftMouseDown),
                leftMouseUp: CGEventSource.counterForEventType(state, eventType: .leftMouseUp),
                rightMouseDown: CGEventSource.counterForEventType(state, eventType: .rightMouseDown),
                rightMouseUp: CGEventSource.counterForEventType(state, eventType: .rightMouseUp),
                otherMouseDown: CGEventSource.counterForEventType(state, eventType: .otherMouseDown),
                otherMouseUp: CGEventSource.counterForEventType(state, eventType: .otherMouseUp),
                leftMouseDragged: CGEventSource.counterForEventType(state, eventType: .leftMouseDragged),
                rightMouseDragged: CGEventSource.counterForEventType(state, eventType: .rightMouseDragged),
                otherMouseDragged: CGEventSource.counterForEventType(state, eventType: .otherMouseDragged),
                scrollWheel: CGEventSource.counterForEventType(state, eventType: .scrollWheel)
            )
        }
    }

    private let keyCode: CGKeyCode
    private let blockingFlags: UInt64
    private let onGesture: (ModifierKeyGesture) -> Void
    private var behavior: DictationKeyBehavior
    private var tapDetector: ModifierTapDetector
    private var holdDetector: ModifierHoldDetector
    private var holdStartTask: Task<Void, Never>?
    private var holdWatchTask: Task<Void, Never>?
    private var holdInputBaseline: InputCounters?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// blockingFlags — device-биты остальных хоткей-модификаторов: при удержанном соседе
    /// жест не начинается, иначе аккорд двух хоткеев запускал бы диктовку.
    init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag,
        blockingFlags: UInt64 = 0,
        behavior: DictationKeyBehavior = .toggle,
        onGesture: @escaping (ModifierKeyGesture) -> Void
    ) {
        // В upstream blockingFlags содержал только соседний хоткей-модификатор. Для hold
        // этого мало: если Shift/Ctrl/Fn уже зажаты ДО нашей ⌘/⌥, отдельного flagsChanged
        // после нажатия нашей клавиши уже не будет. Поэтому на самом press проверяем и
        // общие CGEventFlags всех остальных семейств модификаторов.
        let allBlockingFlags = blockingFlags | Self.initialBlockingFlags(for: keyCode)
        self.keyCode = CGKeyCode(keyCode)
        self.blockingFlags = allBlockingFlags
        self.behavior = behavior
        self.tapDetector = ModifierTapDetector(
            keyCode: keyCode,
            deviceFlag: deviceFlag,
            blockingFlags: allBlockingFlags
        )
        self.holdDetector = ModifierHoldDetector(
            keyCode: keyCode,
            deviceFlag: deviceFlag,
            blockingFlags: allBlockingFlags
        )
        self.onGesture = onGesture
    }

    /// Режим меняется без пересоздания CGEventTap. Если настройку переключили прямо
    /// посреди активного удержания, запись отменяем.
    func setBehavior(_ behavior: DictationKeyBehavior) {
        guard self.behavior != behavior else { return }
        cancelPendingHoldStart()
        stopHoldWatch()
        holdInputBaseline = nil
        if self.behavior == .hold, holdDetector.cancel() {
            onGesture(.holdCancelled)
        }
        self.behavior = behavior
        tapDetector.reset()
        holdDetector.reset()
    }

    /// `false` — тап не поднялся (обычно нет разрешения Accessibility). Повторный вызов на
    /// работающем тапе ничего не делает.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard TextInserter.hasAccessibility else { return false }

        // `self` уходит в колбэк неудержанным: владелец (AppCore) держит объект до выхода
        // из приложения, а `stop()` снимает тап раньше, чем объект мог бы исчезнуть.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                // Источник висит на главном run loop — колбэк приходит на главный поток.
                if let userInfo {
                    let listener = Unmanaged<ModifierKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                    MainActor.assumeIsolated { listener.handle(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        tapDetector.reset()
        holdDetector.reset()
        holdInputBaseline = nil
        stopHoldWatch()
        return true
    }

    /// Идемпотентна: снимает тап, если он стоял.
    func stop() {
        cancelPendingHoldStart()
        stopHoldWatch()
        holdInputBaseline = nil
        if behavior == .hold, holdDetector.cancel() {
            onGesture(.holdCancelled)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
        tapDetector.reset()
        holdDetector.reset()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Громкость/яркость/медиа приходят не как keyDown, а как NSSystemDefined. Без этого
        // Option+Shift+Volume проходит в систему, но Cribe успевает принять Option за hold.
        if type.rawValue == Self.systemDefinedRawValue {
            cancelForChordInput()
            return
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            cancelPendingHoldStart()
            stopHoldWatch()
            holdInputBaseline = nil
            if behavior == .hold, holdDetector.cancel() {
                fire(.holdCancelled)
            }
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            tapDetector.reset()
            holdDetector.reset()

        // Содержимое чужого ввода не читаем. Для toggle достаточно погасить ожидаемый тап.
        // Для hold pending гасится молча, а уже начавшаяся запись отменяется: человек
        // превратил модификатор в обычный системный аккорд.
        case .keyDown, .keyUp,
             .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel:
            cancelForChordInput()

        case .flagsChanged:
            let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.rawValue
            let time = Self.seconds(of: event)

            switch behavior {
            case .toggle:
                if tapDetector.flagsChanged(keyCode: eventKeyCode, flags: flags, at: time) {
                    fire(.tap)
                }

            case .hold:
                switch holdDetector.flagsChanged(keyCode: eventKeyCode, flags: flags, at: time) {
                case .arm:
                    // Снимок делаем на самом press. Даже если menu tracking потом задержит
                    // mouseDown в нашем run loop, WindowServer-счётчик уже изменится.
                    holdInputBaseline = InputCounters.current()
                    scheduleHoldStart()
                case .finish:
                    finishHold()
                case .cancel:
                    cancelHold()
                case .none:
                    // Быстрое отпускание или чужой модификатор до старта: отложенный
                    // старт больше не имеет права сработать.
                    cancelPendingHoldStart()
                    stopHoldWatch()
                    holdInputBaseline = nil
                }
            }

        default:
            break
        }
    }

    /// Реальный старт вынесен из CGEventTap. Порог тот же 0,6 с, который upstream уже
    /// использует как границу между «коротким одиночным нажатием» и долгим удержанием.
    /// Это заметно надёжнее 200 мс для обычных Cmd/Option-сочетаний, где человек часто
    /// нажимает модификатор чуть раньше основной клавиши.
    private func scheduleHoldStart() {
        cancelPendingHoldStart()
        holdStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .milliseconds(Int64(ModifierHoldDetector.activationDelay * 1_000))
            )
            guard !Task.isCancelled, let self, self.behavior == .hold else { return }
            self.holdStartTask = nil

            // Критическая страховка перед самым стартом. Event tap может быть задержан
            // вложенным AppKit menu-tracking loop, но WindowServer уже знает и про click,
            // и про фактическое состояние клавиши.
            guard self.holdIsStillEligible else {
                self.cancelHold()
                return
            }

            guard self.holdDetector.activate(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.onGesture(.holdBegan)
            self.startHoldWatch()
        }
    }

    private func cancelForChordInput() {
        switch behavior {
        case .toggle:
            tapDetector.cancel()
        case .hold:
            cancelHold()
        }
    }

    /// Источник истины — не только доставленные callback-события. Apple даёт текущее
    /// состояние клавиш и глобальные event counters через CGEventSource; Hammerspoon
    /// использует тот же keyState-подход для проверки физически удерживаемых modifiers.
    private var holdIsStillEligible: Bool {
        guard let baseline = holdInputBaseline else { return false }
        return reconciliation(since: baseline) == .keep
    }

    /// Страховка от «вечной записи». Во время активного hold периодически сверяемся с
    /// состоянием WindowServer. Если flagsChanged на release потерялся/задержался из-за
    /// menu tracking, keyState всё равно покажет, что Option/Command уже физически отпущен.
    /// Если во время hold был click/key/scroll, counters имеют приоритет: это аккорд,
    /// поэтому запись отменяем, а не отправляем на распознавание.
    private func startHoldWatch() {
        stopHoldWatch()
        holdWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, let self, self.behavior == .hold else { return }

                guard let baseline = self.holdInputBaseline else { return }
                switch self.reconciliation(since: baseline) {
                case .keep:
                    continue
                case .cancel:
                    self.cancelHold()
                    return
                case .release:
                    self.releaseHoldFromSystemState()
                    return
                }
            }
        }
    }

    private func reconciliation(since baseline: InputCounters) -> ModifierHoldReconciliation {
        let state: CGEventSourceStateID = .combinedSessionState
        let mouseDown =
            CGEventSource.buttonState(state, button: .left)
            || CGEventSource.buttonState(state, button: .right)
            || CGEventSource.buttonState(state, button: .center)

        return modifierHoldReconciliation(
            inputChanged: InputCounters.current() != baseline,
            blockingModifierDown: CGEventSource.flagsState(state).rawValue & blockingFlags != 0,
            mouseButtonDown: mouseDown,
            keyDown: CGEventSource.keyState(state, key: keyCode)
        )
    }

    private func releaseHoldFromSystemState() {
        cancelPendingHoldStart()
        stopHoldWatch()
        holdInputBaseline = nil

        let action = holdDetector.flagsChanged(
            keyCode: Int64(keyCode),
            flags: 0,
            at: ProcessInfo.processInfo.systemUptime
        )
        if action == .finish {
            fire(.holdEnded)
        }
    }

    private func finishHold() {
        // Даже если release callback пришёл раньше задержанного menu-click callback,
        // WindowServer counters уже отражают click. Поэтому перед finish ещё раз сверяем
        // снимок и даём системному аккорду приоритет над транскрибацией.
        if let baseline = holdInputBaseline,
           reconciliation(since: baseline) == .cancel
        {
            cancelPendingHoldStart()
            stopHoldWatch()
            holdInputBaseline = nil
            holdDetector.reset()
            fire(.holdCancelled)
            return
        }

        cancelPendingHoldStart()
        stopHoldWatch()
        holdInputBaseline = nil
        fire(.holdEnded)
    }

    private func cancelHold() {
        cancelPendingHoldStart()
        stopHoldWatch()
        holdInputBaseline = nil
        if holdDetector.cancel() {
            fire(.holdCancelled)
        }
    }

    /// Блокеры, которые уже могут быть зажаты в момент press нашей клавиши.
    /// Свой generic-флаг разрешён (Command для ⌘, Alternate для ⌥), остальные запрещены.
    /// Device-бит противоположной клавиши того же семейства добавляется отдельно, потому
    /// что generic mask не отличает левую ⌘ от правой ⌘ (и так же для ⌥).
    private static func initialBlockingFlags(for keyCode: Int64) -> UInt64 {
        var blocked = chordModifierFlags

        switch keyCode {
        case ModifierTapDetector.leftCommandKeyCode:
            blocked.remove(.maskCommand)
            return blocked.rawValue | ModifierTapDetector.rightCommandFlag
        case ModifierTapDetector.rightCommandKeyCode:
            blocked.remove(.maskCommand)
            return blocked.rawValue | ModifierTapDetector.leftCommandFlag
        case ModifierTapDetector.leftOptionKeyCode:
            blocked.remove(.maskAlternate)
            return blocked.rawValue | ModifierTapDetector.rightOptionFlag
        case ModifierTapDetector.rightOptionKeyCode:
            blocked.remove(.maskAlternate)
            return blocked.rawValue | ModifierTapDetector.leftOptionFlag
        default:
            return blocked.rawValue
        }
    }

    private func cancelPendingHoldStart() {
        holdStartTask?.cancel()
        holdStartTask = nil
    }

    private func stopHoldWatch() {
        holdWatchTask?.cancel()
        holdWatchTask = nil
    }

    /// Ни запуск аудиодвижка, ни остановка/отмена не выполняются внутри CGEventTap.
    private func fire(_ gesture: ModifierKeyGesture) {
        Task { @MainActor [onGesture] in onGesture(gesture) }
    }

    /// Аппаратное время события в секундах: оно не врёт, даже если run loop подвис
    /// и колбэк пришёл с опозданием.
    ///
    /// `CGEventTimestamp` в SDK описан как «наносекунды с момента старта системы» — та же
    /// точка отсчёта, что у `systemUptime` (это не mach-тики: на Apple Silicon перевод через
    /// timebase разошёлся бы в 41.7 раза и превратил любой тап в «долгое удержание»).
    /// Заметное расхождение со `systemUptime` означает событие без штампа — берём часы колбэка.
    private static func seconds(of event: CGEvent) -> TimeInterval {
        let uptime = ProcessInfo.processInfo.systemUptime
        let stamp = TimeInterval(event.timestamp) / 1_000_000_000
        return abs(uptime - stamp) < timestampTolerance ? stamp : uptime
    }
}
