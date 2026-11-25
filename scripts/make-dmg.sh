#!/bin/zsh
# 공증·staple된 dist/KakaoToLinear.app으로 배포용 DMG를 만들고 Developer ID 서명 → 공증 → staple까지 한다.
#
# 사용법:
#   APP_DEVELOPER_ID="Developer ID Application: 이름 (TEAMID)" NOTARY_PROFILE=<keychain profile> \
#     ./scripts/make-dmg.sh <버전>
#
# 공증 인증은 release.sh와 같다: NOTARY_PROFILE 우선, 없으면 APPLE_ID/APPLE_TEAM_ID/APPLE_PASSWORD.
# 결과: dist/KakaoToLinear-<버전>.dmg (Applications 바로가기 포함)

set -euo pipefail

VERSION="${1:?사용법: ./scripts/make-dmg.sh <버전> (예: 0.5.0)}"
project_dir="${0:A:h:h}"
cd "$project_dir"

APP="dist/KakaoToLinear.app"
DMG="dist/KakaoToLinear-$VERSION.dmg"
: "${APP_DEVELOPER_ID:?APP_DEVELOPER_ID가 필요합니다 (Developer ID Application identity)}"

NOTARY_ARGS=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_PASSWORD")
else
  echo "공증 인증 정보가 없습니다: NOTARY_PROFILE 또는 APPLE_ID/APPLE_TEAM_ID/APPLE_PASSWORD" >&2
  exit 1
fi

# DMG 안의 앱은 이미 공증·staple된 같은 버전이어야 한다.
app_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [[ "$app_version" != "$VERSION" ]]; then
  echo "$APP 버전($app_version)이 요청 버전($VERSION)과 다릅니다." >&2
  exit 1
fi
xcrun stapler validate "$APP" >/dev/null || { echo "$APP 이 공증·staple되지 않았습니다." >&2; exit 1; }

stage=$(mktemp -d "${TMPDIR:-/tmp}/kakaotolinear-dmg.XXXXXX")
cleanup_stage() {
  find "$stage" -depth -type f -delete
  find "$stage" -depth -type l -delete
  find "$stage" -depth -type d -empty -delete
}
trap cleanup_stage EXIT

ditto "$APP" "$stage/KakaoToLinear.app"
ln -s /Applications "$stage/Applications"

echo ">>> DMG 생성: $DMG"
hdiutil create -volname "KakaoToLinear $VERSION" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG"

echo ">>> DMG 서명: $APP_DEVELOPER_ID"
codesign --force --timestamp --sign "$APP_DEVELOPER_ID" "$DMG"
codesign --verify --strict "$DMG"

echo ">>> DMG notarize + staple"
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "$DMG"
