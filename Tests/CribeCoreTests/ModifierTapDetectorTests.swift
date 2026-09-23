import XCTest
@testable import CribeCore

/// Тап по правому ⌘ должен срабатывать только вхолостую: ⌘-аккорды пользователя
/// живут своей жизнью и диктовку не запускают.
final class ModifierTapDetectorTests: XCTestCase {

    private let rcmd = ModifierTapDetector.rightCommandKeyCode
    private let rcmdDown = ModifierTapDetector.rightCommandFlag
    private let released: UInt64 = 0

    func testPressAndReleaseFires() {
        var detector = ModifierTapDetector()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0))
        XCTAssertTrue(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    /// ⌘C правым ⌘ (и так же ⌘-клик, ⌘-скролл): между нажатием и отпусканием был ввод — это аккорд.
    func testInputBetweenCancels() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        detector.cancel()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    /// ⇧⌘ и подобное: смена другого модификатора во время удержания отменяет тап.
    func testOtherModifierCancels() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        _ = detector.flagsChanged(keyCode: 56, flags: rcmdDown | 0x2, at: 0.05)
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }

    func testLongHoldDoesNotFire() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        XCTAssertFalse(
            detector.flagsChanged(keyCode: rcmd, flags: released, at: ModifierTapDetector.holdLimit + 0.01)
        )
    }

    /// Левый ⌘ шлёт свой keyCode: удержание левого не должно выглядеть тапом правого.
    func testLeftCommandIgnored() {
        var detector = ModifierTapDetector()
        XCTAssertFalse(detector.flagsChanged(keyCode: 55, flags: 0x8, at: 0))
        XCTAssertFalse(detector.flagsChanged(keyCode: 55, flags: released, at: 0.1))
    }

    /// Отпускание правого ⌘ при всё ещё зажатом левом: device-бит правого погас — это отпускание.
    func testReleaseWhileLeftCommandHeld() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown | 0x8, at: 0)
        XCTAssertTrue(detector.flagsChanged(keyCode: rcmd, flags: 0x8, at: 0.1))
    }

    /// Детектор правого ⌥ (диктовка с переводом) ловит свою клавишу и не путает её с ⌘:
    /// у них разные и keyCode, и device-бит, а тапы работают одновременно.
    func testRightOptionDetectorIsIndependentFromCommand() {
        var detector = ModifierTapDetector(
            keyCode: ModifierTapDetector.rightOptionKeyCode,
            deviceFlag: ModifierTapDetector.rightOptionFlag
        )
        let ralt = ModifierTapDetector.rightOptionKeyCode
        let raltDown = ModifierTapDetector.rightOptionFlag

        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0))
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))

        XCTAssertFalse(detector.flagsChanged(keyCode: ralt, flags: raltDown, at: 0.2))
        XCTAssertTrue(detector.flagsChanged(keyCode: ralt, flags: released, at: 0.3))
    }

    /// Аккорд двух хоткей-модификаторов: ⌘ удержан, поверх него тапнули ⌥. Удержанный ⌘
    /// своего события не шлёт, поэтому узнать о нём можно только по флагам нажатия ⌥ —
    /// иначе отпускание ⌥ запустило бы диктовку с переводом прямо посреди чужого аккорда.
    func testHeldCommandBlocksOptionTap() {
        var detector = ModifierTapDetector(
            keyCode: ModifierTapDetector.rightOptionKeyCode,
            deviceFlag: ModifierTapDetector.rightOptionFlag,
            blockingFlags: ModifierTapDetector.rightCommandFlag
        )
        let ralt = ModifierTapDetector.rightOptionKeyCode
        let raltDown = ModifierTapDetector.rightOptionFlag

        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0))
        // Нажатие ⌥ несёт оба device-бита: ⌘ всё ещё зажат.
        XCTAssertFalse(detector.flagsChanged(keyCode: ralt, flags: rcmdDown | raltDown, at: 0.1))
        XCTAssertFalse(detector.flagsChanged(keyCode: ralt, flags: rcmdDown, at: 0.2))

        // Аккорд кончился — чистый тап ⌥ снова работает (детектор не «залипает»).
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.3))
        XCTAssertFalse(detector.flagsChanged(keyCode: ralt, flags: raltDown, at: 0.4))
        XCTAssertTrue(detector.flagsChanged(keyCode: ralt, flags: released, at: 0.5))
    }

    /// То же в обратную сторону: ⌥ удержан, тапнули ⌘ — обычная диктовка не стартует.
    func testHeldOptionBlocksCommandTap() {
        var detector = ModifierTapDetector(blockingFlags: ModifierTapDetector.rightOptionFlag)
        let ralt = ModifierTapDetector.rightOptionKeyCode
        let raltDown = ModifierTapDetector.rightOptionFlag

        XCTAssertFalse(detector.flagsChanged(keyCode: ralt, flags: raltDown, at: 0))
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: raltDown | rcmdDown, at: 0.1))
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: raltDown, at: 0.2))
    }

    /// После сброса (тап отключали и включали) ожидание не воскресает.
    func testResetDropsPendingTap() {
        var detector = ModifierTapDetector()
        _ = detector.flagsChanged(keyCode: rcmd, flags: rcmdDown, at: 0)
        detector.reset()
        XCTAssertFalse(detector.flagsChanged(keyCode: rcmd, flags: released, at: 0.1))
    }
    /// Левая пара должна вести себя идентично правой: чистый тап ⌘ срабатывает.
    func testLeftCommandPressAndReleaseFires() {
        var detector = ModifierTapDetector(
            keyCode: ModifierTapDetector.leftCommandKeyCode,
            deviceFlag: ModifierTapDetector.leftCommandFlag,
            blockingFlags: ModifierTapDetector.leftOptionFlag
        )
        let lcmd = ModifierTapDetector.leftCommandKeyCode
        let lcmdDown = ModifierTapDetector.leftCommandFlag

        XCTAssertFalse(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0))
        XCTAssertTrue(detector.flagsChanged(keyCode: lcmd, flags: released, at: 0.1))
    }

    /// Обычное сочетание вроде левого ⌘C не должно запускать диктовку после отпускания ⌘.
    func testLeftCommandInputBetweenCancels() {
        var detector = ModifierTapDetector(
            keyCode: ModifierTapDetector.leftCommandKeyCode,
            deviceFlag: ModifierTapDetector.leftCommandFlag
        )
        let lcmd = ModifierTapDetector.leftCommandKeyCode
        let lcmdDown = ModifierTapDetector.leftCommandFlag

        _ = detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0)
        detector.cancel()
        XCTAssertFalse(detector.flagsChanged(keyCode: lcmd, flags: released, at: 0.1))
    }

    /// Левая ⌥ запускает перевод только чистым тапом и блокируется удержанным левым ⌘.
    func testLeftOptionIsIndependentAndBlockedByLeftCommand() {
        var detector = ModifierTapDetector(
            keyCode: ModifierTapDetector.leftOptionKeyCode,
            deviceFlag: ModifierTapDetector.leftOptionFlag,
            blockingFlags: ModifierTapDetector.leftCommandFlag
        )
        let lcmd = ModifierTapDetector.leftCommandKeyCode
        let lcmdDown = ModifierTapDetector.leftCommandFlag
        let lalt = ModifierTapDetector.leftOptionKeyCode
        let laltDown = ModifierTapDetector.leftOptionFlag

        XCTAssertFalse(detector.flagsChanged(keyCode: lalt, flags: laltDown, at: 0))
        XCTAssertTrue(detector.flagsChanged(keyCode: lalt, flags: released, at: 0.1))

        XCTAssertFalse(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0.2))
        XCTAssertFalse(detector.flagsChanged(keyCode: lalt, flags: lcmdDown | laltDown, at: 0.3))
        XCTAssertFalse(detector.flagsChanged(keyCode: lalt, flags: lcmdDown, at: 0.4))
    }

}


final class ModifierHoldDetectorTests: XCTestCase {
    private let lcmd = ModifierTapDetector.leftCommandKeyCode
    private let lcmdDown = ModifierTapDetector.leftCommandFlag
    private let released: UInt64 = 0

    func testCleanHoldArmsThenFinishesAfterActivationDelay() {
        var detector = ModifierHoldDetector(
            keyCode: lcmd,
            deviceFlag: lcmdDown,
            blockingFlags: ModifierTapDetector.leftOptionFlag
        )

        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 1), .arm)
        XCTAssertFalse(detector.activate(at: 1 + ModifierHoldDetector.activationDelay - 0.01))
        XCTAssertTrue(detector.activate(at: 1 + ModifierHoldDetector.activationDelay + 0.001))
        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: released, at: 2), .finish)
    }

    /// Быстрый tap в режиме удержания — не альтернативный toggle: записи быть не должно.
    func testQuickPressReleaseNeverActivates() {
        var detector = ModifierHoldDetector(keyCode: lcmd, deviceFlag: lcmdDown)

        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0), .arm)
        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: released, at: 0.05), .none)
        XCTAssertFalse(detector.activate(at: 1))
    }

    /// Cmd-C/клик/скролл до защитного порога гасят pending жест без старта записи.
    func testInputBeforeActivationCancelsPendingHoldSilently() {
        var detector = ModifierHoldDetector(keyCode: lcmd, deviceFlag: lcmdDown)

        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0), .arm)
        XCTAssertFalse(detector.cancel())
        XCTAssertFalse(detector.activate(at: 1))
        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: released, at: 1.1), .none)
    }

    /// Если аккорд начался уже после стартового чайма, живую запись выбрасываем,
    /// а отпускание модификатора потом ничего не запускает и не обрабатывает.
    func testInputAfterActivationCancelsActiveHoldAndReleaseIsNoOp() {
        var detector = ModifierHoldDetector(keyCode: lcmd, deviceFlag: lcmdDown)

        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0), .arm)
        XCTAssertTrue(detector.activate(at: ModifierHoldDetector.activationDelay + 0.001))
        XCTAssertTrue(detector.cancel())
        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: released, at: 1), .none)
    }

    func testOtherModifierAfterActivationReturnsCancel() {
        var detector = ModifierHoldDetector(keyCode: lcmd, deviceFlag: lcmdDown)

        _ = detector.flagsChanged(keyCode: lcmd, flags: lcmdDown, at: 0)
        XCTAssertTrue(detector.activate(at: ModifierHoldDetector.activationDelay + 0.001))
        XCTAssertEqual(
            detector.flagsChanged(keyCode: 56, flags: lcmdDown | 0x2, at: 0.7),
            .cancel
        )
        XCTAssertEqual(detector.flagsChanged(keyCode: lcmd, flags: released, at: 0.4), .none)
    }

    /// Уже зажатый внешний модификатор (например Shift перед Option) обязан блокировать
    /// hold прямо на первом событии нашей клавиши: второго flagsChanged может уже не быть.
    func testAlreadyHeldBlockingFlagPreventsArming() {
        let simulatedShiftFlag: UInt64 = 1 << 17
        var detector = ModifierHoldDetector(
            keyCode: lcmd,
            deviceFlag: lcmdDown,
            blockingFlags: simulatedShiftFlag
        )

        XCTAssertEqual(
            detector.flagsChanged(
                keyCode: lcmd,
                flags: lcmdDown | simulatedShiftFlag,
                at: 0
            ),
            .none
        )
        XCTAssertFalse(detector.activate(at: 2))
    }

    func testHeldNeighborBlocksHoldFromArming() {
        var detector = ModifierHoldDetector(
            keyCode: ModifierTapDetector.leftOptionKeyCode,
            deviceFlag: ModifierTapDetector.leftOptionFlag,
            blockingFlags: ModifierTapDetector.leftCommandFlag
        )

        XCTAssertEqual(
            detector.flagsChanged(
                keyCode: ModifierTapDetector.leftOptionKeyCode,
                flags: ModifierTapDetector.leftCommandFlag | ModifierTapDetector.leftOptionFlag,
                at: 0
            ),
            .none
        )
        XCTAssertFalse(detector.activate(at: 1))
    }
}
