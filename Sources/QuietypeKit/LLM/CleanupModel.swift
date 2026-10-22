import Foundation

/// A downloadable GGUF model for the cleanup step.
public struct CleanupModel: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var detail: String
    /// The Hugging Face repository, and the commit the file is pinned to so the download can't
    /// change under the size and hash below.
    public var repository: String
    public var revision: String
    public var fileName: String
    /// Exact size and SHA-256 of the file, checked after every download.
    public var bytes: Int64
    public var sha256: String
    /// Appended after the assistant header, e.g. an empty think block to turn off reasoning.
    public var assistantPrefill: String

    public var url: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)")!
    }

    public static let qwen3_4B = CleanupModel(
        id: "qwen3-4b-instruct-2507",
        name: "Qwen3 4B Instruct (recommended)",
        detail: "Best cleanup quality. 2.5 GB download, about 3 GB of memory.",
        repository: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        revision: "a06e946bb6b655725eafa393f4a9745d460374c9",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        bytes: 2_497_281_120,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        assistantPrefill: ""
    )

    public static let qwen3_1_7B = CleanupModel(
        id: "qwen3-1.7b",
        name: "Qwen3 1.7B (faster)",
        detail: "About twice as fast, weaker at subtle corrections. 1.1 GB download.",
        repository: "unsloth/Qwen3-1.7B-GGUF",
        revision: "d7f544eead698dbd1f15126ef60b45a1e1933222",
        fileName: "Qwen3-1.7B-Q4_K_M.gguf",
        bytes: 1_107_409_472,
        sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
        assistantPrefill: "<think>\n\n</think>\n\n"
    )

    public static let all: [CleanupModel] = [qwen3_4B, qwen3_1_7B]

    public static func with(id: String) -> CleanupModel? { all.first { $0.id == id } }
}
