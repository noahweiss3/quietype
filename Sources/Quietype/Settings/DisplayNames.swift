import QuietypeCore

extension CleanupMode {
    var displayName: String {
        switch self {
        case .rulesOnly: return "Rules only (no LLM)"
        case .smart: return "Smart: LLM only when needed"
        case .always: return "Always use the LLM"
        }
    }
}

extension ProcessedDictation.Path {
    var displayName: String {
        switch self {
        case .rules: return "rules"
        case .llm: return "LLM"
        case .llmRejected: return "LLM rejected"
        }
    }
}
