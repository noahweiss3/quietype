import Foundation

/// A downloadable GGUF model for the cleanup step.
public struct CleanupModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    public var url: URL
    public var approximateBytes: Int64
    /// Appended after the assistant header, e.g. an empty think block to turn off reasoning.
    public var assistantPrefill: String

    public var fileName: String { url.lastPathComponent }

    public static let qwen3_4B = CleanupModel(
        id: "qwen3-4b-instruct-2507",
        name: "Qwen3 4B Instruct (recommended)",
        detail: "Best cleanup quality. 2.5 GB download, about 3 GB of memory.",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        approximateBytes: 2_497_281_120,
        assistantPrefill: ""
    )

    public static let qwen3_1_7B = CleanupModel(
        id: "qwen3-1.7b",
        name: "Qwen3 1.7B (faster)",
        detail: "About twice as fast, weaker at subtle corrections. 1.1 GB download.",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf")!,
        approximateBytes: 1_107_409_472,
        assistantPrefill: "<think>\n\n</think>\n\n"
    )

    public static let all: [CleanupModel] = [qwen3_4B, qwen3_1_7B]

    public static func with(id: String) -> CleanupModel? { all.first { $0.id == id } }
}
