import Foundation
import WhoRUCore

// Placeholder; the scanner command lands once the macOS checks exist.
let parser = PromptParser()
if let parsed = parser.parse(title: CommandLine.arguments.dropFirst().joined(separator: " ")) {
    print("\(parsed.requester) → \(parsed.service.shortName)")
} else {
    print("usage: whoru-cli '<dialog title>'")
}
