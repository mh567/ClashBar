import XCTest
@testable import ClashBar

/// The core-settings action row is a filled card. It must only exist when it has
/// something in it, otherwise it renders as an empty strip under the section tabs.
final class CoreSettingsActionsVisibilityTests: XCTestCase {
    func testRowIsHiddenWhenTheOnlyStateIsASingleOverride() {
        // One hot-applied override, nothing pending, nothing to restore-all: the field's
        // own status chip already covers it, so the card would be empty.
        XCTAssertFalse(
            CoreSettingsActionsVisibility.shouldShow(
                isApplying: false,
                isCommitting: false,
                pendingCount: 0,
                overrideCount: 1,
                hasError: false,
                isRestoring: false))
    }

    func testRowShowsForEachReasonItCanContainSomething() {
        let reasons: [(String, Bool, Bool, Int, Int, Bool, Bool)] = [
            ("applying", true, false, 0, 0, false, false),
            ("committing", false, true, 0, 0, false, false),
            ("pending drafts", false, false, 1, 0, false, false),
            ("an error", false, false, 0, 0, true, false),
            ("a staged restore", false, false, 0, 0, false, true),
            ("two overrides, so Restore All applies", false, false, 0, 2, false, false),
        ]
        for (name, applying, committing, pending, overrides, error, restoring) in reasons {
            XCTAssertTrue(
                CoreSettingsActionsVisibility.shouldShow(
                    isApplying: applying,
                    isCommitting: committing,
                    pendingCount: pending,
                    overrideCount: overrides,
                    hasError: error,
                    isRestoring: restoring),
                "the row must show for \(name)")
        }
    }
}
