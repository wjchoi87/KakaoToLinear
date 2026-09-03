import Foundation

struct LinearDescriptionBuilder: Sendable {
  func build(
    draft: IssueDraft,
    source: SourceBundle,
    assets: [UploadedLinearAsset] = []
  ) -> String {
    var sections: [String] = []
    sections.append(section("요청사항", items: draft.requirements))
    sections.append(section("완료 조건", items: draft.acceptanceCriteria))
    sections.append(section("참고사항", items: draft.notes, fallback: "없음"))
    sections.append(section("확인 필요", items: draft.questions, fallback: "없음"))
    if !assets.isEmpty {
      let lines = assets.map { asset in
        if asset.mimeType.hasPrefix("image/") {
          return "![\(escape(asset.name))](\(asset.assetURL.absoluteString))"
        }
        return "[📎 \(escape(asset.name))](\(asset.assetURL.absoluteString))"
      }
      sections.append("## 첨부\n\n\(lines.joined(separator: "\n\n"))")
    }
    let messages = source.messages.sorted { $0.timestamp < $1.timestamp }.map { message in
      let date = ISO8601DateFormatter().string(from: message.timestamp)
      let body = (message.text ?? "[\(message.type.rawValue)]")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "> \($0)" }
        .joined(separator: "\n")
      return "**\(escape(message.senderName)) · \(date) · `\(message.id)`**\n\(body)"
    }
    sections.append("---\n\n## 원본 요청\n\n\(messages.joined(separator: "\n\n"))")
    return sections.joined(separator: "\n\n")
  }

  private func section(_ title: String, items: [String], fallback: String? = nil) -> String {
    let body =
      items.isEmpty
      ? (fallback.map { "- \($0)" } ?? "") : items.map { "- \($0)" }.joined(separator: "\n")
    return "## \(title)\n\n\(body)"
  }

  private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
  }
}
