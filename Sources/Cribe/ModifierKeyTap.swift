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
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
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

    private let onGesture: (ModifierKeyGesture) -> Void
    private var behavior: DictationKeyBehavior
    private var tapDetector: ModifierTapDetector
    private var holdDetector: ModifierHoldDetector
    private var holdStartTask: Task<Void, Never>?
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
        self.behavior = behavior
        // В upstream blockingFlags содержал только соседний хоткей-модификатор. Для hold
        // этого мало: если Shift/Ctrl/Fn уже зажаты ДО нашей ⌘/⌥, отдельного flagsChanged
        // после нажатия нашей клавиши уже не будет. Поэтому на самом press проверяем и
        // общие CGEventFlags всех остальных семейств модификаторов.
        let allBlockingFlags = blockingFlags | Self.initialBlockingFlags(for: keyCode)
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
        return true
    }

    /// Идемпотентна: снимает тап, если он стоял.
    func stop() {
        cancelPendingHoldStart()
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
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
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
                    scheduleHoldStart()
                case .finish:
                    cancelPendingHoldStart()
                    fire(.holdEnded)
                case .cancel:
                    cancelPendingHoldStart()
                    fire(.holdCancelled)
                case .none:
                    // Быстрое отпускание или чужой модификатор до старта: отложенный
                    // старт больше не имеет права сработать.
                    cancelPendingHoldStart()
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
            guard self.holdDetector.activate(at: ProcessInfo.processInfo.systemUptime) else { return }
            self.onGesture(.holdBegan)
        }
    }

    private func cancelForChordInput() {
        switch behavior {
        case .toggle:
            tapDetector.cancel()
        case .hold:
            cancelPendingHoldStart()
            if holdDetector.cancel() {
                fire(.holdCancelled)
            }
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
