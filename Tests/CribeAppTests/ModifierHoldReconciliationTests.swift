import XCTest
@testable import Cribe

final class ModifierHoldReconciliationTests: XCTestCase {
    func testCleanHoldKeepsRunningWhileKeyIsDown() {
        XCTAssertEqual(
            modifierHoldReconciliation(
                inputChanged: false,
                blockingModifierDown: false,
                mouseButtonDown: false,
                keyDown: true
            ),
            .keep
        )
    }

    func testCleanReleaseFinishesHold() {
        XCTAssertEqual(
            modifierHoldReconciliation(
                inputChanged: false,
                blockingModifierDown: false,
                mouseButtonDown: false,
                keyDown: false
            ),
            .release
        )
    }

    /// Именно этот порядок нужен для бага Option + модифицированное меню:
    /// после nested menu tracking Cribe может одновременно узнать и про click, и про
    /// уже отпущенный Option. Click означает системный аккорд, поэтому запись надо
    /// выбросить, а не завершить как нормальную диктовку.
    func testMenuClickWinsOverRelease() {
        XCTAssertEqual(
            modifierHoldReconciliation(
                inputChanged: true,
                blockingModifierDown: false,
                mouseButtonDown: false,
                keyDown: false
            ),
            .cancel
        )
    }

    func testBlockingModifierCancelsEvenWhileTrackedKeyIsDown() {
        XCTAssertEqual(
            modifierHoldReconciliation(
                inputChanged: false,
                blockingModifierDown: true,
                mouseButtonDown: false,
                keyDown: true
            ),
            .cancel
        )
    }

    func testHeldMouseButtonCancels() {
        XCTAssertEqual(
            modifierHoldReconciliation(
                inputChanged: false,
                blockingModifierDown: false,
                mouseButtonDown: true,
                keyDown: true
            ),
            .cancel
        )
    }
}
