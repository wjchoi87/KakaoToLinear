import AppKit
import SwiftUI

struct ResultView: View {
  @ObservedObject var state: AppState

  var body: some View {
    VStack(spacing: 22) {
      Spacer()
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 64)).foregroundStyle(.green)
      Text("Linear 이슈를 만들었습니다").font(.title.bold())
      if let result = state.result {
        VStack(spacing: 6) {
          Text(result.identifier).font(.title2.monospaced().bold())
          Text(result.title).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        HStack {
          Button("Linear 열기") { NSWorkspace.shared.open(result.url) }
            .buttonStyle(.borderedProminent)
          Button("번호 복사") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.identifier, forType: .string)
          }
          .buttonStyle(.bordered)
        }
      }
      Button("새 이슈 만들기") { Task { await state.reset() } }
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}