# KakaoToLinear UI Contract

## UX 목표

사용자는 `⌥⌘L` 이후 source 선택, draft 확인, Linear 생성만 수행한다. 화면당 primary CTA는 하나다.

```text
Room 선택 → Message 정리 → Draft 확정 → Linear 생성 → 결과
```

## Visual system

- macOS native SwiftUI control과 semantic system color 사용
- window minimum `680 × 600`, default `760 × 720`
- surface마다 16~20pt padding
- warning/error는 icon + text를 함께 사용하고 색상만으로 상태를 표현하지 않음
- body는 system font, title은 `.title2.bold`, metadata는 `.caption/.secondary`
- decorative animation 없음; loading은 blocking progress overlay 한 종류

## Screens

### Room Picker

- primary CTA: room row 선택
- current room과 search는 secondary action
- favorite와 other room을 독립 DisclosureGroup으로 나누고 star action은 row navigation과 분리
- empty: Kakao 실행/FDA 확인 문구
- permission: 상단 banner에서 Settings sheet 진입

### Message Picker

- primary CTA: 정리
- plain click single, Command-click additive toggle, Shift range, Command-Shift additive range, ⌘A
- 선택 수를 footer 왼쪽에 고정
- 선택한 source만 AI로 전달된다는 privacy copy 표시

### Review

- title/summary/requirements/acceptance/questions 직접 수정
- manual edit는 다음 단계 전에 새 draft revision으로 저장
- 재정리는 Source + CurrentDraft + Instruction만 전달
- attachment resolve failure는 전체 flow를 막지 않음

### Linear Create

- API metadata만 Picker에 사용
- room defaults prefill
- Team 변경 시 dependent metadata와 선택값 reset
- duplicate prevention 설명을 생성 버튼 옆에 표시

### Result

- identifier가 가장 높은 hierarchy
- primary CTA: Linear 열기
- secondary: 번호 복사, 새 이슈

## States

- loading: app 전체 interaction 차단, 중복 submit 금지
- error: action 가능한 human-readable banner, source/draft 유지
- permission: 권한 종류와 다음 행동 표시
- empty: icon, 원인, 해결 기준 표시
- attachment unavailable: warning으로 표시하고 issue creation 허용
- already created: CLI exit 60, 기존 identifier/url 안내
- AI settings: provider → model 순서로 선택하고 Codex는 CLI owner, 나머지는 provider별 Keychain 입력을 표시

## Accessibility

- native Button/Picker/Toggle/TextField semantic 사용
- icon-only close button에 accessibility label 제공
- keyboard default/cancel shortcuts 제공
- 모든 text field에 visible label 또는 prompt 제공
- 긴 한글은 multiline wrapping, message body 최대 5 lines preview
- checkbox state는 icon/AX state로 제공

## Visual QA checklist

- [x] Permission/empty state actual app capture
- [x] Settings form actual app capture
- [x] Favorite/other room disclosure group, star 이동, 독립 collapse fixture capture
- [x] Empty Message Picker의 top header / flexible body / bottom footer fixture capture
- [x] Korean text wrapping and AX labels
- [x] Loading state clears after denied permission
- [ ] Live room/message screenshots — private content 노출 방지를 위해 미수집
- [ ] AI/Linear result screens with production credentials
