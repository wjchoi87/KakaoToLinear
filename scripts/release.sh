#!/bin/zsh
# KakaoToLinear 릴리즈 자동화
#
# 사용법:
#   ./scripts/release.sh 0.3.0                     # 0.3.0 릴리즈 (현재 버전 +1 권장)
#   APPLE_ID=x SPARKLE_BIN=/path/to/bin ./scripts/release.sh 0.3.0
#
# 환경변수 (모두 선택):
#   APPLE_ID       Apple Developer 계정 (notarize용, set하면 정식 서명/notarize 수행)
#   APPLE_TEAM_ID  Apple Developer Team ID
#   APPLE_PASSWORD App-specific password (Keychain에 저장 권장)
#   APP_DEVELOPER_ID  Developer ID identity ("Developer ID Application: 이름 (ABCDE12345)")
#   SPARKLE_BIN     Sparkle bin 디렉토리 (generate_keys/sign_update 포함, 기본 자동 탐색)
#   DRY_RUN=1       로컬(빌드/zip/서명/appcast 생성)까지만 수행, push/release 생략
#
# Developer ID/애플 계정이 없으면 ad-hoc으로 빌드/서명한 뒤 경고하고
# GitHub release까지만 진행한다 (자동 업데이트는 서명 후에만 동작).

set -euo pipefail

VERSION="${1:?사용법: ./scripts/release.sh <버전> (예: 0.3.0)}"
project_dir="${0:A:h:h}"
cd "$project_dir"

# --------------------------------------------------------------------------
# 0. 도구/환경 준비
# --------------------------------------------------------------------------
# Sparkle bin 탐색: SPARKLE_BIN > /tmp/bin > 홈brew sparkle > 실패
if [[ -z "${SPARKLE_BIN:-}" ]]; then
  if [[ -x /tmp/bin/sign_update ]]; then
    SPARKLE_BIN=/tmp/bin
  elif [[ -x "$(command -v sparkle-generate-keys 2>/dev/null)" ]]; then
    SPARKLE_BIN="$(dirname "$(command -v sparkle-generate-keys)")"
  else
    echo "경고: Sparkle bin(sign_update)을 찾지 못했습니다. SPARKLE_BIN=/path/to/bin 지정 필요." >&2
    echo "  https://github.com/sparkle-project/Sparkle/releases 에서 받아 /tmp/bin 에 넣으세요." >&2
    exit 1
  fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령이 없습니다: $1" >&2; exit 1; }
}
require_cmd swift
require_cmd gh
require_cmd ditto
require_cmd stat

# gh 로그인 확인
gh auth status >/dev/null 2>&1 || { echo "gh 로그인이 필요합니다: gh auth login" >&2; exit 1; }
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo wjchoi87/KakaoToLinear)}"

# --------------------------------------------------------------------------
# 1. 버전 + 빌드 번호 준비, Info.plist 갱신
# --------------------------------------------------------------------------
PLIST="Resources/KakaoLinearApp-Info.plist"
CURRENT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "0.0.0")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "0")
NEW_BUILD=$((CURRENT_BUILD + 1))

echo ">>> 버전: $VERSION (빌드 #$NEW_BUILD, 이전: $CURRENT_SHORT ($CURRENT_BUILD))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

ZIP="KakaoToLinear-$VERSION.zip"
TAG="v$VERSION"

echo ">>> 빌드 (release)"
swift build -c release --product KakaoLinearApp
./scripts/build-app.sh >/dev/null

# --------------------------------------------------------------------------
# 2. 서명 (Developer ID 있으면 notarize까지, 없으면 ad-hoc + 경고)
# --------------------------------------------------------------------------
APP="dist/KakaoToLinear.app"
SIGNED=false
if [[ -n "${APP_DEVELOPER_ID:-}" ]]; then
  echo ">>> Developer ID 서명: $APP_DEVELOPER_ID"
  codesign --force --deep --options runtime --sign "$APP_DEVELOPER_ID" "$APP"
  codesign --verify --deep --strict "$APP"
  SIGNED=true
else
  echo "!!! 경고: APP_DEVELOPER_ID 미지정 → ad-hoc 서명. Gatekeeper 경고가 뜹니다." >&2
  echo "!!! 자동 업데이트(Sparkle)는 Developer ID 서명 후에만 동작합니다." >&2
  # build-app.sh가 이미 ad-hoc 서명을 함
  SIGNED=false
fi

if [[ "$SIGNED" == true && -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
  echo ">>> notarize + staple"
  ditto -c -k --keepParent "$APP" "/tmp/$ZIP"
  xcrun notarytool submit "/tmp/$ZIP" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD" --wait
  xcrun staple "$APP"
  spctl -a -vv "$APP" || echo "!!! spctl 검증 실패 (알 수 없는 개발자 경고가 남음)" >&2
else
  if [[ "$SIGNED" == true ]]; then
    echo "!!! 경고: APPLE_ID/TEAM/PASSWORD 미설정 → notarize 생략. Gatekeeper 경고가 뜹니다." >&2
  fi
fi

# --------------------------------------------------------------------------
# 3. zip 생성 + Sparkle 서명
# --------------------------------------------------------------------------
echo ">>> zip 생성"
rm -f "dist/$ZIP"
ditto -c -k --keepParent "$APP" "dist/$ZIP"
LENGTH=$(stat -f%z "dist/$ZIP")

echo ">>> Sparkle 서명 (sign_update)"
SPARKLE_SIGN="$( "$SPARKLE_BIN/sign_update" "dist/$ZIP" )"
# 출력 예: sparkle:edSignature="..." length="..."
ED_SIG="$(echo "$SPARKLE_SIGN" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIG" ]]; then
  echo "sign_update 출력 파싱 실패: $SPARKLE_SIGN" >&2
  exit 1
fi
echo "    edSignature=$ED_SIG  length=$LENGTH"

# --------------------------------------------------------------------------
# 4. appcast.xml 갱신
# --------------------------------------------------------------------------
echo ">>> appcast.xml 갱신"
cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>KakaoToLinear Updates</title>
    <item>
      <title>KakaoToLinear $VERSION</title>
      <sparkle:version>$NEW_BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ZIP"
                 sparkle:edSignature="$ED_SIG"
                 length="$LENGTH"
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML

# --------------------------------------------------------------------------
# 5. 커밋/push + GitHub Release
# --------------------------------------------------------------------------
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">>> DRY_RUN: git push / GitHub Release 생략"
else
  echo ">>> git commit/push"
  git add appcast.xml "Resources/KakaoLinearApp-Info.plist"
  git commit -m "Release $VERSION (build $NEW_BUILD): bump version & update appcast" >/dev/null
  git push origin main

  echo ">>> GitHub Release 생성/업데이트"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "dist/$ZIP" --repo "$REPO" --clobber
  else
    gh release create "$TAG" "dist/$ZIP" --repo "$REPO" \
      --title "KakaoToLinear $VERSION" --notes "KakaoToLinear $VERSION 릴리즈"
  fi
fi

echo ""
echo "완료: $REPO $TAG"
echo "  zip      : dist/$ZIP ($LENGTH bytes)"
echo "  appcast  : https://raw.githubusercontent.com/$REPO/main/appcast.xml"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo "  (DRY_RUN: 실제 push/release는 실행되지 않았습니다.)"
fi
if [[ "$SIGNED" != true ]]; then
  echo "!!! 주의: ad-hoc 서명 배포입니다. 자동 업데이트는 Developer ID 서명 후 동작합니다."
fi