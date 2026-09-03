import Foundation
import Testing
import WhoRUCore
@testable import WhoRUMac

@Suite struct SpotlightNameSafetyTests {
    @Test func ordinaryNamesAreSafe() {
        for name in ["Google Chrome", "Claude", "1Password 8", "Café Noir", "מסוף", "Foo-Bar_2.app", "iTerm2"] {
            #expect(MacApplicationFinder.isSafeSpotlightName(name), Comment(rawValue: name))
        }
    }

    @Test func wildcardsQuotesAndControlsAreRejected() {
        for name in ["*", "?", "Chrome*", "a?b", "It's", "Say \"hi\"", "back\\slash", "tab\there", "new\nline", "nul\u{0}", ""] {
            #expect(!MacApplicationFinder.isSafeSpotlightName(name), Comment(rawValue: name.debugDescription))
        }
    }

    @Test func spotlightFallbackDoesNotRunForUnsafeNames() async throws {
        // A wildcard name matches every application in Spotlight; the finder
        // must answer with nothing rather than with the whole Applications folder.
        let found = try await MacApplicationFinder().applications(named: "*")
        #expect(found.isEmpty)
    }
}
