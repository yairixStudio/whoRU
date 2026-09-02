import Testing
@testable import WhoRUMac

@Test func bundleIdentifierIsStable() {
    #expect(WhoRUMac.bundleIdentifier == "com.yairixstudio.whoru")
}

@Test func keychainAndPasswordDialogsAreNotPermissionPrompts() {
    #expect(AXDialogWatcher.looksLikeAuthentication(texts: ["codesign wants to access key “whoRU-application” in your keychain.", "To allow this, enter the “login” keychain password.", "Password:"]))
    #expect(AXDialogWatcher.looksLikeAuthentication(texts: ["Terminal wants to make changes.", "Enter your password to allow this."]))
    #expect(AXDialogWatcher.looksLikeAuthentication(texts: ["הזן את הסיסמה שלך"]))
    #expect(!AXDialogWatcher.looksLikeAuthentication(texts: ["“Terminal” would like to access files in your Downloads folder."]))
    #expect(!AXDialogWatcher.looksLikeAuthentication(texts: []))
}
