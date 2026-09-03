import Foundation
import Testing
import WhoRUCore
@testable import WhoRUMac

private let known: Set<String> = ["com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent"]

@Test func onlyAnApplePlatformProcessWithAKnownIdentifierIsASystemDialog() {
    #expect(AXDialogWatcher.isSystemDialogProcess(isPlatform: true, bundleID: "com.apple.UserNotificationCenter", known: known))
    // A copied bundle identifier without Apple's signature is an impostor.
    #expect(!AXDialogWatcher.isSystemDialogProcess(isPlatform: false, bundleID: "com.apple.UserNotificationCenter", known: known))
    // Apple-signed but not a dialog process: osascript, Script Editor, Finder.
    #expect(!AXDialogWatcher.isSystemDialogProcess(isPlatform: true, bundleID: "com.apple.finder", known: known))
    #expect(!AXDialogWatcher.isSystemDialogProcess(isPlatform: true, bundleID: nil, known: known))
    #expect(!AXDialogWatcher.isSystemDialogProcess(isPlatform: false, bundleID: nil, known: known))
}

@Test func originCarriesTheOwnersDetailsWhenUnverified() {
    let system = AXDialogWatcher.origin(isSystem: true, bundleID: "com.apple.CoreServicesUIAgent", owner: "CoreServicesUIAgent", path: "/x", signer: "Apple")
    #expect(system == .system(bundleID: "com.apple.CoreServicesUIAgent"))
    let fake = AXDialogWatcher.origin(isSystem: false, bundleID: nil, owner: "osascript", path: "/usr/bin/osascript", signer: "Apple")
    #expect(fake == .unverified(owner: "osascript", path: "/usr/bin/osascript", signer: "Apple"))
    let impostor = AXDialogWatcher.origin(isSystem: false, bundleID: "com.apple.UserNotificationCenter", owner: "UserNotificationCenter", path: "/tmp/fake", signer: nil)
    #expect(impostor == .unverified(owner: "UserNotificationCenter", path: "/tmp/fake", signer: nil))
    // A system flag without an identifier cannot be a system origin.
    #expect(AXDialogWatcher.origin(isSystem: true, bundleID: nil, owner: "x", path: nil, signer: nil) == .unverified(owner: "x", path: nil, signer: nil))
}

@Test func signerSummaryNamesThePublisherOrTheLackOfOne() {
    func info(_ kind: SignerKind, leaf: String? = nil) -> SignatureInfo {
        SignatureInfo(kind: kind, valid: true, leafSummary: leaf, chain: [], isPlatformBinary: false, hardenedRuntime: false, entitlements: [:])
    }
    #expect(AXDialogWatcher.signerSummary(info(.apple)) == "Apple")
    #expect(AXDialogWatcher.signerSummary(info(.unsigned)) == "unsigned")
    #expect(AXDialogWatcher.signerSummary(info(.adhoc)).contains("ad-hoc"))
    #expect(AXDialogWatcher.signerSummary(info(.developerID, leaf: "Developer ID Application: Vendor (TEAM)")) == "Developer ID Application: Vendor (TEAM)")
}

@Test func theRunningProcessIsItsOwnFileOnDisk() {
    // This test process: Apple-signed only when run from Xcode's tools, but
    // always intact and identical to its executable.
    let pid = ProcessInfo.processInfo.processIdentifier
    let path = ProcessTrust.executablePath(pid: pid)
    #expect(path != nil)
    if let path {
        let info = RunningCode.validate(pid: pid, diskPath: path)
        if info.error != "unsigned" {
            #expect(info.valid, "\(info.error ?? "")")
            #expect(info.matchesDisk == true)
            #expect(info.cdhash != nil && info.cdhash == info.diskCdhash)
        } else {
            #expect(info.matchesDisk == nil)
        }
    }
    #expect(ProcessTrust.isApplePlatformProcess(pid: 1))
    #expect(RunningCode.validate(pid: 1, diskPath: "/sbin/launchd").matchesDisk == true)
}

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
