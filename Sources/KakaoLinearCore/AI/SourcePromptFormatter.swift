import Foundation

struct SourcePromptFormatter: Sendable {
  func format(_ source: SourceBundle) -> String {
    var lines = [
      "SOURCE ROOM: \(source.room.title) [\(source.room.id)]",
      "SOURCE MESSAGES (chronological, immutable):",
    ]
    for message in source.messages.sorted(by: { $0.timestamp < $1.timestamp }) {
      lines.append("\n[\(message.id)] \(message.senderName) · \(iso8601(message.timestamp))")
      if let text = message.text { lines.append(text) }
      for attachment in message.attachments {
        let name = attachment.originalName ?? attachment.id
        lines.append(
          "[\(attachment.kind.rawValue.uppercased()) attachment://\(attachment.id) \(name)]")
      }
    }
    if !source.attachmentFailures.isEmpty {
      lines.append("\nUNAVAILABLE ATTACHMENTS:")
      lines.append(contentsOf: source.attachmentFailures.map { "- \($0.attachmentId)" })
    }
    return lines.joined(separator: "\n")
  }

  private func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}

struct TextAttachmentExtractor: Sendable {
  private let allowedExtensions = Set(["txt", "md", "csv", "json"])
  private let maxBytes = 1_000_000

  func context(from attachments: [ResolvedAttachment]) throws -> String {
    var sections: [String] = []
    for resolved in attachments {
      let ext = resolved.fileURL.pathExtension.lowercased()
      guard allowedExtensions.contains(ext) else { continue }
      let data = try Data(contentsOf: resolved.fileURL, options: [.mappedIfSafe])
      guard data.count <= maxBytes, let text = String(data: data, encoding: .utf8) else { continue }
      let name = resolved.attachment.originalName ?? resolved.fileURL.lastPathComponent
      sections.append("\nFILE CONTEXT [\(name)]:\n\(text)")
    }
    return sections.joined()
  }
}
