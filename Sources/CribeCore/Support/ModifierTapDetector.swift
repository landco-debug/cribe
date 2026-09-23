import Foundation

/// Распознаёт «тап» по модификатору: нажали и отпустили, а между этим — ничего.
/// Чистая логика без CoreGraphics: события подаёт `ModifierKeyTap`.
///
/// Отменяют тап любое действие пользователя между нажатием и отпусканием — клавиша (⌘C правым
/// ⌘ не должен запускать диктовку), клик или скролл мышью, — а также смена любого другого
/// модификатора и удержание дольше `holdLimit`. А если в момент нажатия удержан чужой
/// хоткей-модификатор (`blockingFlags`), ожидание тапа не заводится вовсе.
public struct ModifierTapDetector {
    /// Левый ⌘: keyCode 55 (`kVK_Command`), device-бит `NX_DEVICELCMDKEYMASK`.
    public static let leftCommandKeyCode: Int64 = 55
    public static let leftCommandFlag: UInt64 = 0x08
    /// Правый ⌘: keyCode 54, device-бит `NX_DEVICERCMDKEYMASK`.
    public static let rightCommandKeyCode: Int64 = 54
    public static let rightCommandFlag: UInt64 = 0x10
    /// Левый ⌥: keyCode 58 (`kVK_Option`), device-бит `NX_DEVICELALTKEYMASK`.
    public static let leftOptionKeyCode: Int64 = 58
    public static let leftOptionFlag: UInt64 = 0x20
    /// Правый ⌥: keyCode 61 (`kVK_RightOption`), device-бит `NX_DEVICERALTKEYMASK`.
    public static let rightOptionKeyCode: Int64 = 61
    public static let rightOptionFlag: UInt64 = 0x40
    /// Дольше — это долгий аккорд с ⌘, а не намеренный тап.
    public static let holdLimit: TimeInterval = 0.6

    private let keyCode: Int64
    private let deviceFlag: UInt64
    /// Device-биты чужих хоткей-модификаторов. Зажатая соседняя хоткей-клавиша не шлёт
    /// своего события, пока её держат, поэтому на нажатии нашей клавиши узнать о ней можно
    /// только по флагам: удержанный правый ⌘ плюс тап правым ⌥ — это аккорд двух хоткеев,
    /// и запускать по нему диктовку нельзя.
    private let blockingFlags: UInt64
    /// Момент нажатия отслеживаемого модификатора; nil — тапа в ожидании нет.
    private var pressedAt: TimeInterval?

    public init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag,
        blockingFlags: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.deviceFlag = deviceFlag
        self.blockingFlags = blockingFlags
    }

    /// Событие смены модификаторов. `true` — это отпускание завершило тап.
    /// `flags` — сырые флаги события: device-бит отличает правый модификатор от левого,
    /// поэтому удержанный левый ⌘ не выдаёт себя за нажатый правый.
    public mutating func flagsChanged(keyCode: Int64, flags: UInt64, at time: TimeInterval) -> Bool {
        guard keyCode == self.keyCode else {
            pressedAt = nil  // любой другой модификатор — это аккорд, а не тап
            return false
        }
        guard flags & deviceFlag == 0 else {
            // Нажатие: ждать тапа начинаем, только если чужой хоткей-модификатор не удержан.
            // Иначе это аккорд двух хоткеев — ожидание не заводим вовсе (а заодно снимаем
            // старое, если оно почему-то осталось).
            pressedAt = flags & blockingFlags == 0 ? time : nil
            return false
        }
        let pressed = pressedAt
        pressedAt = nil
        guard let pressed else { return false }
        return time - pressed <= Self.holdLimit
    }

    /// Любой ввод во время удержания (клавиша, клик, скролл) отменяет тап.
    public mutating func cancel() {
        pressedAt = nil
    }

    /// Сброс после перерыва в потоке событий: пропущенные события делают ожидание недостоверным.
    public mutating func reset() {
        pressedAt = nil
    }
}


/// Событие, которое детектор удержания отдаёт оболочке CGEventTap.
public enum ModifierHoldAction: Equatable, Sendable {
    case none
    case arm
    case finish
    case cancel
}

/// Push-to-talk вариант того же правила, что у ModifierTapDetector.
///
/// Обычные сочетания macOS должны остаться обычными сочетаниями, поэтому запись не
/// начинается на самом flagsChanged. Сначала идёт короткое защитное окно: если за это
/// время появляется другая клавиша, модификатор, клик или скролл, ожидание снимается.
///
/// После реального старта любой такой ввод отменяет запись целиком. События при этом
/// слушаются .listenOnly в ModifierKeyTap, так что Cmd-C, Cmd-Tab, Option-Left и мышиные
/// аккорды продолжают доходить до macOS/приложения нетронутыми.
public struct ModifierHoldDetector {
    /// Компромисс между «не мигать на обычном Cmd-C» и отзывчивостью push-to-talk.
    /// Стартовый чайм сообщает, когда удержание принято и можно говорить.
    public static let activationDelay: TimeInterval = 0.20

    private enum State {
        case idle
        case pending(TimeInterval)
        case active
        /// Текущий физический hold уже испорчен аккордом; ждём отпускания своей клавиши.
        case suppressed
    }

    private let keyCode: Int64
    private let deviceFlag: UInt64
    private let blockingFlags: UInt64
    private var state: State = .idle

    public init(
        keyCode: Int64 = ModifierTapDetector.rightCommandKeyCode,
        deviceFlag: UInt64 = ModifierTapDetector.rightCommandFlag,
        blockingFlags: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.deviceFlag = deviceFlag
        self.blockingFlags = blockingFlags
    }

    /// .arm означает только «завести таймер» — микрофон ещё не включается.
    /// .finish бывает исключительно после подтверждённого удержания.
    public mutating func flagsChanged(
        keyCode: Int64,
        flags: UInt64,
        at time: TimeInterval
    ) -> ModifierHoldAction {
        guard keyCode == self.keyCode else {
            return suppressForChord()
        }

        if flags & deviceFlag != 0 {
            guard flags & blockingFlags == 0 else {
                state = .suppressed
                return .none
            }
            // Повторное flagsChanged своей клавиши не должно переармить уже живую запись.
            if case .active = state { return .none }
            state = .pending(time)
            return .arm
        }

        let previous = state
        state = .idle
        if case .active = previous { return .finish }
        return .none
    }

    /// Таймер защитного окна истёк. true — удержание всё ещё чистое и теперь активно.
    public mutating func activate(at time: TimeInterval) -> Bool {
        guard case .pending(let pressedAt) = state else { return false }
        guard time - pressedAt >= Self.activationDelay else { return false }
        state = .active
        return true
    }

    /// Клавиша/мышь во время удержания. Возвращает true, если запись уже успела
    /// стартовать и её нужно отменить; pending-состояние просто гасится без записи.
    @discardableResult
    public mutating func cancel() -> Bool {
        switch state {
        case .active:
            state = .suppressed
            return true
        case .pending:
            state = .suppressed
            return false
        case .idle, .suppressed:
            return false
        }
    }

    public mutating func reset() {
        state = .idle
    }

    private mutating func suppressForChord() -> ModifierHoldAction {
        switch state {
        case .active:
            state = .suppressed
            return .cancel
        case .pending:
            state = .suppressed
            return .none
        case .idle, .suppressed:
            return .none
        }
    }
}
