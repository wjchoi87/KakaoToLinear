import AppKit
import ApplicationServices
import Foundation

struct KakaoAXAdapter: Sendable {
  func focusedRoomTitle() throws -> String? {
    guard AXIsProcessTrusted() else {
      throw KakaoLinearError.permission("Accessibility 권한이 필요합니다.")
    }
    guard
      let application = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.kakao.KakaoTalkMac"
      ).first
    else {
      throw KakaoLinearError.kakaoNotRunning
    }
    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    var windowValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement,
        kAXFocusedWindowAttribute as CFString,
        &windowValue
      ) == .success,
      let windowValue
    else { return nil }
    let window = unsafeDowncast(windowValue, to: AXUIElement.self)
    var titleValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
      let title = titleValue as? String
    else { return nil }
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned != "카카오톡", cleaned != "KakaoTalk" else { return nil }
    return cleaned
  }
}
