import Foundation

/// List prices per million tokens, used to show cost in history. The live
/// figure of record is the provider's bill; this is an estimate.
public enum Pricing {
    public struct Rate: Sendable { public var inputPerMillion: Double; public var outputPerMillion: Double }

    public static let rates: [String: Rate] = [
        "claude-fable-5-1": Rate(inputPerMillion: 10, outputPerMillion: 50),
        "claude-fable-5": Rate(inputPerMillion: 10, outputPerMillion: 50),
        "claude-opus-5": Rate(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-8": Rate(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-7": Rate(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-6": Rate(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-5": Rate(inputPerMillion: 2, outputPerMillion: 10),
        "claude-sonnet-4-6": Rate(inputPerMillion: 3, outputPerMillion: 15),
        "claude-haiku-4-5": Rate(inputPerMillion: 1, outputPerMillion: 5),
    ]

    public static func cost(model: String, inputTokens: Int, outputTokens: Int) -> Double {
        guard let rate = rates[model] ?? rates.first(where: { model.hasPrefix($0.key) })?.value else { return 0 }
        return Double(inputTokens) / 1_000_000 * rate.inputPerMillion + Double(outputTokens) / 1_000_000 * rate.outputPerMillion
    }
}
