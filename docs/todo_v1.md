- [x] 카톡 대화 리스트는 쉬프트나 커맨드로 여러개 일괄 선택 가능하도록
- [x] 카톡 대화방 즐겨찾기 기능 추가
- [x] 즐겨찾기 된 대화방 리스트와 아닌 리스트 그룹 나눠서 접어둘수 있도록
- [x] 채팅방 선택 후 Message Picker header/footer 고정, body가 남은 영역 전체 차지

구현 계약:

- plain click: 단일 선택
- Command-click: 개별 추가/해제
- Shift-click: anchor 기준 연속 범위 선택
- Command-Shift-click: 기존 선택에 연속 범위 추가
- Command-A: 현재 표시된 message 전체 선택
- 즐겨찾기 상태: `room-favorites.json`, mode `0600`
- Room Picker: `즐겨찾기` / `다른 채팅방` DisclosureGroup, 각각 독립 접기
- CLI: `rooms favorites`, `rooms favorite --room`, `rooms unfavorite --room`
- Message Picker: header/footer는 intrinsic fixed height, list/empty body만 flexible height
