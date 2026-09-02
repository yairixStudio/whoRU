import Testing
@testable import WhoRUMac

@Test func bundleIdentifierIsStable() {
    #expect(WhoRUMac.bundleIdentifier == "com.yairixstudio.whoru")
}
