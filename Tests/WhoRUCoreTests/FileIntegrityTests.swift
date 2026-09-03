import Foundation
import Testing
@testable import WhoRUCore

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoru-integrity-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let testKey = Data((0..<32).map { UInt8($0) })

@Suite struct FileIntegrityTests {
    @Test func roundTripVerifies() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        let integrity = FileIntegrity(key: testKey)
        try integrity.write(Data("{\"a\":1}".utf8), to: url)
        let (data, state) = try integrity.read(url)
        #expect(state == .verified)
        #expect(String(decoding: data, as: UTF8.self) == "{\"a\":1}")
        let sidecar = try String(contentsOf: FileIntegrity.sidecarURL(for: url), encoding: .utf8)
        #expect(sidecar.count == 64)
        #expect(sidecar.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func modifiedFileIsTampered() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        let integrity = FileIntegrity(key: testKey)
        try integrity.write(Data("{\"a\":1}".utf8), to: url)
        try Data("{\"a\":2}".utf8).write(to: url)
        #expect(try integrity.read(url).state == .tampered)
    }

    @Test func modifiedSidecarIsTampered() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        let integrity = FileIntegrity(key: testKey)
        try integrity.write(Data("{\"a\":1}".utf8), to: url)
        try Data("not hex".utf8).write(to: FileIntegrity.sidecarURL(for: url))
        #expect(try integrity.read(url).state == .tampered)
        try Data(String(repeating: "0", count: 64).utf8).write(to: FileIntegrity.sidecarURL(for: url))
        #expect(try integrity.read(url).state == .tampered)
    }

    @Test func differentKeyIsTampered() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        try FileIntegrity(key: testKey).write(Data("{}".utf8), to: url)
        #expect(try FileIntegrity(key: Data(repeating: 9, count: 32)).read(url).state == .tampered)
    }

    @Test func missingSidecarIsMissingSignature() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        let integrity = FileIntegrity(key: testKey)
        try integrity.write(Data("{}".utf8), to: url)
        try FileManager.default.removeItem(at: FileIntegrity.sidecarURL(for: url))
        let (data, state) = try integrity.read(url)
        #expect(state == .missingSignature)
        #expect(data == Data("{}".utf8))
    }

    @Test func nilKeyIsUnverifiableAndWritesNoSidecar() throws {
        let url = temporaryDirectory().appendingPathComponent("a.json")
        let integrity = FileIntegrity(key: nil)
        try integrity.write(Data("{}".utf8), to: url)
        #expect(!FileManager.default.fileExists(atPath: FileIntegrity.sidecarURL(for: url).path))
        #expect(try integrity.read(url).state == .unverifiable)
        #expect(!integrity.canVerify)
        // A keyed file rewritten without a key loses its (now stale) sidecar.
        try FileIntegrity(key: testKey).write(Data("{}".utf8), to: url)
        try integrity.write(Data("{\"b\":1}".utf8), to: url)
        #expect(try FileIntegrity(key: testKey).read(url).state == .missingSignature)
    }
}

@Suite struct SignedSettingsStoreTests {
    private func paths() -> DefaultPaths {
        DefaultPaths(applicationSupport: temporaryDirectory(), homeDirectory: "/tmp")
    }

    @Test func savedSettingsVerifyAndLoad() throws {
        let store = JSONFileSettingsStore(paths: paths(), integrity: FileIntegrity(key: testKey))
        var settings = Settings()
        settings.strictness = .strict
        try store.save(settings)
        let loaded = try store.loadChecked()
        #expect(loaded.state == .verified)
        #expect(loaded.settings.strictness == .strict)
    }

    @Test func tamperedFileYieldsDefaults() throws {
        let store = JSONFileSettingsStore(paths: paths(), integrity: FileIntegrity(key: testKey))
        var settings = Settings()
        settings.strictness = .strict
        try store.save(settings)
        try Data(#"{"strictness":"standard","claudeCodePath":"/tmp/evil"}"#.utf8).write(to: store.url)
        let loaded = try store.loadChecked()
        #expect(loaded.state == .tampered)
        #expect(loaded.settings == Settings())
        #expect(try store.load() == Settings())
    }

    @Test func unsignedFileIsUsedOnce() throws {
        let p = paths()
        // Written by a version without signing.
        try JSONFileSettingsStore(paths: p).save({ var s = Settings(); s.historyRetentionDays = 7; return s }())
        let store = JSONFileSettingsStore(paths: p, integrity: FileIntegrity(key: testKey))
        let loaded = try store.loadChecked()
        #expect(loaded.state == .missingSignature)
        #expect(loaded.settings.historyRetentionDays == 7)
        try store.save(loaded.settings)
        #expect(try store.loadChecked().state == .verified)
    }

    @Test func absentFileIsDefaults() throws {
        #expect(try JSONFileSettingsStore(paths: paths(), integrity: FileIntegrity(key: testKey)).loadChecked().state == .verified)
        #expect(try JSONFileSettingsStore(paths: paths()).loadChecked().state == .unverifiable)
    }
}

@Suite struct PublisherOverridesStoreTests {
    private func paths() -> DefaultPaths {
        DefaultPaths(applicationSupport: temporaryDirectory(), homeDirectory: "/tmp")
    }

    @Test func roundTrip() throws {
        let store = PublisherOverridesStore(paths: paths(), integrity: FileIntegrity(key: testKey))
        let trusted = Publisher(teamID: "ABC123", name: "Someone", source: .user, trust: .trusted)
        try store.save([trusted])
        let loaded = try store.load()
        #expect(loaded.state == .verified)
        #expect(loaded.publishers == [trusted])
    }

    @Test func tamperedFileHonoursNoTrust() throws {
        let store = PublisherOverridesStore(paths: paths(), integrity: FileIntegrity(key: testKey))
        try store.save([])
        let injected = [Publisher(teamID: "EVIL01", name: "Evil", source: .user, trust: .trusted)]
        try JSONEncoder().encode(injected).write(to: store.url)
        let loaded = try store.load()
        #expect(loaded.state == .tampered)
        #expect(loaded.publishers.isEmpty)
    }

    @Test func absentAndUnsignedFiles() throws {
        let p = paths()
        let store = PublisherOverridesStore(paths: p, integrity: FileIntegrity(key: testKey))
        #expect(try store.load().publishers.isEmpty)
        let old = [Publisher(teamID: "OLD", name: "Old", source: .user, trust: .blocked)]
        try PublisherOverridesStore(paths: p).save(old)
        let loaded = try store.load()
        #expect(loaded.state == .missingSignature)
        #expect(loaded.publishers == old)
    }
}

@Suite struct IntegrityKeyTests {
    @Test func createsOnceAndReturnsTheSameKey() {
        let secrets = InMemorySecretStore()
        #expect(IntegrityKey.load(from: secrets, createIfMissing: false) == nil)
        let first = IntegrityKey.load(from: secrets, createIfMissing: true)
        #expect(first?.count == IntegrityKey.length)
        let second = IntegrityKey.load(from: secrets, createIfMissing: true)
        #expect(first == second)
        #expect(IntegrityKey.load(from: secrets, createIfMissing: false) == first)
        #expect(secrets.secret(.storeIntegrityKey).flatMap { Data(base64Encoded: $0) } == first)
    }

    @Test func readOnlyStoreYieldsNoKey() {
        #expect(IntegrityKey.load(from: EnvironmentSecretStore(), createIfMissing: true) == nil)
    }

    @Test func unreadableKeyIsNotReplaced() {
        let secrets = InMemorySecretStore([.storeIntegrityKey: "not base64!"])
        #expect(IntegrityKey.load(from: secrets, createIfMissing: true) == nil)
        #expect(secrets.secret(.storeIntegrityKey) == "not base64!")
    }
}
