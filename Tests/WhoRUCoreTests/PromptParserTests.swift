import Foundation
import Testing
@testable import WhoRUCore

struct DialogFixture: Decodable {
    struct Expected: Decodable {
        var requester: String
        var service: String
        var target: String?
    }
    var title: String
    var body: String?
    var expected: Expected?
    var pending: Bool?
}

func loadFixtures(_ name: String) throws -> [DialogFixture] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([DialogFixture].self, from: Data(contentsOf: url))
}

@Suite struct PromptParserTests {
    let parser = PromptParser()

    @Test func englishFixtures() throws {
        let fixtures = try loadFixtures("dialogs.en")
        #expect(fixtures.count >= 20)
        for fixture in fixtures where fixture.pending != true {
            let parsed = parser.parse(title: fixture.title, body: fixture.body)
            if let expected = fixture.expected {
                let p = try #require(parsed, "expected a parse for \(fixture.title)")
                #expect(p.requester == expected.requester, "requester for \(fixture.title)")
                #expect(p.service.shortName == expected.service, "service for \(fixture.title)")
                if let target = expected.target { #expect(p.target == target) }
            } else {
                #expect(parsed == nil, "expected no parse for \(fixture.title)")
            }
        }
    }

    @Test func hebrewFixturesOnlyRunWhenNotPending() throws {
        let fixtures = try loadFixtures("dialogs.he")
        for fixture in fixtures {
            let parsed = parser.parse(title: fixture.title, body: fixture.body)
            if fixture.pending == true {
                // Generic quoted-name extraction still works; the service is unknown by design.
                #expect(parsed?.requester == fixture.expected?.requester)
                continue
            }
            let expected = try #require(fixture.expected)
            #expect(parsed?.requester == expected.requester)
            #expect(parsed?.service.shortName == expected.service)
        }
    }

    @Test func makePromptKeepsRawText() throws {
        let prompt = try #require(parser.makePrompt(title: "“Zoom” would like to access the camera.", body: "To join meetings."))
        #expect(prompt.requesterName == "Zoom")
        #expect(prompt.service == .camera)
        #expect(prompt.body == "To join meetings.")
        #expect(prompt.title.hasPrefix("“Zoom”"))
        #expect(prompt.locale == "en")
    }

    @Test func serviceKeywordsAreSpecificBeforeGeneric() {
        #expect(PromptParser.service(forPhrase: "access files in your Desktop folder") == .desktopFolder)
        #expect(PromptParser.service(forPhrase: "control this computer using accessibility features") == .accessibility)
        #expect(PromptParser.service(forPhrase: "access data from other apps") == .appleEvents)
        #expect(PromptParser.service(forPhrase: "do something we never saw") == .other)
    }

    @Test func serviceRoundTripsThroughShortName() {
        for service in PermissionService.allCases {
            #expect(PermissionService(shortName: service.shortName) == service)
        }
    }
}
