import Foundation

public enum TextContextMode: String, Codable, CaseIterable, Sendable {
    case automatic, small = "8k", medium = "16k", large = "32k"

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .small: "8K"
        case .medium: "16K"
        case .large: "32K"
        }
    }

    public var fixedTokens: Int? {
        switch self {
        case .automatic: nil
        case .small: 8192
        case .medium: 16384
        case .large: 32768
        }
    }
}

/// Runtime context and complete-output reserves, independent of the model's advertised maximum.
public enum TextContextPolicy {
    public static let safetyTokens = 512

    public static func automaticMaximum(physicalMemoryBytes: UInt64) -> Int {
        if physicalMemoryBytes <= 8 * 1_073_741_824 { return 8192 }
        return physicalMemoryBytes <= 16 * 1_073_741_824 ? 16384 : 32768
    }

    public static func context(mode: TextContextMode, inputTokens: Int, promptOverhead: Int,
                               action: TextAction, modelMaximum: Int, physicalMemoryBytes: UInt64) -> Int {
        if let fixed = mode.fixedTokens { return min(fixed, modelMaximum) }
        let maximum = min(modelMaximum, automaticMaximum(physicalMemoryBytes: physicalMemoryBytes))
        let needed = inputTokens + outputTokens(inputTokens: inputTokens, action: action) + promptOverhead + safetyTokens
        return [8192, 16384, 32768].first { $0 <= maximum && $0 >= needed } ?? maximum
    }

    public static func inputBudget(contextTokens: Int, promptOverhead: Int, action: TextAction) -> Int {
        let available = max(0, contextTokens - promptOverhead - safetyTokens)
        if action.isSummary { return max(0, available - 1200) }
        // Revisions can be longer than the source. Concise actions still reserve the whole source
        // because an already concise passage may be returned unchanged.
        let ratio = action.id == "concise" ? 2.0 : 2.5
        return max(0, Int(floor(Double(available - 256) / ratio)))
    }

    public static func outputTokens(inputTokens: Int, action: TextAction) -> Int {
        if action.isSummary { return 1200 }
        let ratio = action.id == "concise" ? 1.0 : 1.5
        return Int(ceil(Double(max(0, inputTokens)) * ratio)) + 256
    }
}
