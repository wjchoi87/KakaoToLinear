import Carbon
import Foundation

extension Notification.Name {
  static let showKakaoToLinearMaker = Notification.Name("showKakaoToLinearMaker")
  static let reloadKakaoLinearHotkey = Notification.Name("reloadKakaoLinearHotkey")
}

final class GlobalHotKey {
  private var hotKey: EventHotKeyRef?
  private var handler: EventHandlerRef?

  func register(
    keyCode: UInt32 = UInt32(kVK_ANSI_L), modifiers: UInt32 = UInt32(optionKey | cmdKey)
  ) {
    unregister()
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: OSType(kEventHotKeyPressed)
    )
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .showKakaoToLinearMaker, object: nil)
        }
        return noErr
      },
      1,
      &eventType,
      nil,
      &handler
    )
    let identifier = EventHotKeyID(signature: fourCharacterCode("KLIN"), id: 1)
    RegisterEventHotKey(
      keyCode,
      modifiers,
      identifier,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )
  }

  func unregister() {
    if let hotKey { UnregisterEventHotKey(hotKey) }
    if let handler { RemoveEventHandler(handler) }
    hotKey = nil
    handler = nil
  }

  deinit { unregister() }

  private func fourCharacterCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
  }
}
