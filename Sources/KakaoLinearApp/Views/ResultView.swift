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
          Button("Linear 열기") { openLinear(url: result.url) }
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

  // Linear 데스크톱 앱이 설치되어 있으면 앱으로, 없으면 웹(기본 브라우저)으로 연다.
  private func openLinear(url: URL) {
    let workspace = NSWorkspace.shared
    // https://linear.app/... → linear://linear.app/... 딥링크로 바꿔 앱이 처리하는지 확인한다.
    if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      components.scheme = "linear"
      if let deepLink = components.url,
        workspace.urlForApplication(toOpen: deepLink) != nil,
        workspace.open(deepLink)
      {
        return
      }
    }
    // fallback: 웹
    workspace.open(url)
  }
}
