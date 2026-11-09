import Foundation
import HeardCore

func runTextInjectorTests() {
    print("\n⌨️ TextInjector Accessibility Tests")

    test("Dictation accepts a confirmed process trust grant") {
        try expect(TextInjector.canAttemptInjection(isTrusted: true, targetReadSucceeded: false))
    }

    test("Dictation accepts a successful cross-app read with a stale trust bit") {
        try expect(TextInjector.canAttemptInjection(isTrusted: false, targetReadSucceeded: true))
    }

    test("Dictation does not paste when access is unverified") {
        try expect(!TextInjector.canAttemptInjection(isTrusted: false, targetReadSucceeded: false))
    }
}
