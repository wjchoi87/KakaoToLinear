import KakaoLinearCore
import SwiftUI

struct ReviewView: View {
  @ObservedObject var state: AppState

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("AI 정리 결과").font(.title2.bold())
        Text("원문은 고정되어 있고, 아래 draft만 수정됩니다.")
          .foregroundStyle(.secondary)
        GroupBox("제목") {
          TextField("이슈 제목", text: binding(\.title)).textFieldStyle(.roundedBorder)
        }
        GroupBox("요약") {
          TextEditor(text: binding(\.summary)).frame(minHeight: 80)
        }
        GroupBox("요청사항") {
          TextEditor(text: listBinding(\.requirements)).frame(minHeight: 110)
        }
        GroupBox("완료 조건") {
          TextEditor(text: listBinding(\.acceptanceCriteria)).frame(minHeight: 110)
        }
        GroupBox("확인 필요") {
          TextEditor(text: listBinding(\.questions)).frame(minHeight: 70)
        }
        if let source = state.source {
          GroupBox("첨부") {
            VStack(alignment: .leading) {
              ForEach(source.resolvedAttachments, id: \.attachment.id) { item in
                Label(
                  item.attachment.originalName ?? item.fileURL.lastPathComponent,
                  systemImage: "paperclip")
              }
              ForEach(source.attachmentFailures, id: \.attachmentId) { failure in
                Label("\(failure.attachmentId) · 원본 확보 실패", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(.orange)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        if let evidence = state.evidence, !evidence.attachmentInsights.isEmpty {
          GroupBox("AI가 본 첨부 분석") {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(evidence.attachmentInsights, id: \.attachmentId) { insight in
                VStack(alignment: .leading, spacing: 4) {
                  Label(
                    "\(insight.attachmentId) (\(insight.type))",
                    systemImage: "vision.pro"
                  )
                  .font(.caption.bold())
                  ForEach(insight.observations, id: \.self) { observation in
                    Text("• \(observation)").font(.caption)
                  }
                  if !insight.ambiguities.isEmpty {
                    ForEach(insight.ambiguities, id: \.self) { ambiguity in
                      Label("\(ambiguity)", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                    }
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        GroupBox("추가/수정 지시") {
          VStack(alignment: .leading, spacing: 8) {
            TextField("예: PC 범위는 제외하고 태블릿 완료 조건을 추가해", text: $state.revisionInstruction)
              .textFieldStyle(.roundedBorder)
            HStack {
              Button("원문 보기") { state.showingSource = true }
              Spacer()
              Button("재정리") { Task { await state.revise() } }
                .disabled(
                  state.revisionInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Button("확정") { Task { await state.prepareLinear() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
          }
        }
      }
      .padding(20)
    }
  }

  private func binding(_ keyPath: WritableKeyPath<IssueDraft, String>) -> Binding<String> {
    Binding(
      get: { state.draft?[keyPath: keyPath] ?? "" },
      set: { state.draft?[keyPath: keyPath] = $0 }
    )
  }

  private func listBinding(_ keyPath: WritableKeyPath<IssueDraft, [String]>) -> Binding<String> {
    Binding(
      get: { state.draft?[keyPath: keyPath].joined(separator: "\n") ?? "" },
      set: { value in
        state.draft?[keyPath: keyPath] = value.split(separator: "\n").map(String.init)
      }
    )
  }
}
