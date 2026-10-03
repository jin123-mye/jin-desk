#!/bin/zsh
# 빌드(앱 + WidgetKit 위젯 확장) → ~/Applications/진의 데스크.app 설치 → 페이지 복사 → LaunchAgent(로그인 시 자동 실행, 죽으면 재시작) 등록
set -e
cd "$(dirname "$0")"
# Xcode 라이선스 미동의 상태면 swiftc가 멈춘다 → CommandLineTools로 빌드
swiftc --version >/dev/null 2>&1 || export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SUPPORT="$HOME/Library/Application Support/JinDesk"
# 폴더 이름은 영문: 한글 경로면 위젯 확장 실행 때 Launch Services가 확장 기록을 못 찾는다(-10814). 보이는 이름은 CFBundleDisplayName
APP="$HOME/Applications/JinDesk.app"
OLD="$HOME/Applications/진의 데스크.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -d "$OLD" ]; then "$LSREG" -u "$OLD" 2>/dev/null || true; mv "$OLD" "$HOME/.Trash/진의 데스크 (예전 경로).app"; fi
BIN="$APP/Contents/MacOS/JinDesk"
LABEL=com.jin.desk
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# 서명: 키체인에 Apple Development 인증서가 있으면 그걸로(위젯 확장은 ad-hoc이면 macOS가 실행을 거부한다), 없으면 ad-hoc
SIGN=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
SIGN=${SIGN:--}
echo "서명: $SIGN"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ko.lproj"
printf '"CFBundleDisplayName" = "진의 데스크";\n"CFBundleName" = "진의 데스크";\n' > "$APP/Contents/Resources/ko.lproj/InfoPlist.strings"   # Finder에도 한글 이름
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # 아이콘 원본: icon.swift (다시 그리는 법은 CLAUDE.md 10.7)
swiftc -O main.swift Bridge.swift Google.swift Feed.swift MailCalendar.swift Daum.swift DaumParse.swift -o "$BIN" -framework Cocoa -framework WebKit -framework Carbon -framework WidgetKit

# WidgetKit 위젯 확장: 앱 안 PlugIns/JinDeskWidget.appex (샌드박스 + 요약 파일 폴더 읽기 전용 예외)
WX="$APP/Contents/PlugIns/JinDeskWidget.appex"
mkdir -p "$WX/Contents/MacOS"
swiftc -O -parse-as-library -application-extension -target arm64-apple-macos14.0 Widget/JinDeskWidget.swift \
  -o "$WX/Contents/MacOS/JinDeskWidget" -framework WidgetKit -framework SwiftUI \
  -Xlinker -e -Xlinker _NSExtensionMain   # Xcode 앱 확장과 같은 시작 함수 (없으면 확장이 시작하자마자 SIGTRAP)
VER=$(date +%Y%m%d%H%M)   # 빌드마다 올려야 위젯 호스트가 새 확장을 다시 읽는다
cat > "$WX/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL.widget</string>
  <key>CFBundleName</key><string>진의 데스크</string>
  <key>CFBundleDisplayName</key><string>진의 데스크</string>
  <key>CFBundleExecutable</key><string>JinDeskWidget</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleShortVersionString</key><string>3.4</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict></plist>
EOF
codesign --force -s "$SIGN" --entitlements Widget/widget.entitlements "$WX"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>진의 데스크</string>
  <key>CFBundleDisplayName</key><string>진의 데스크</string>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleExecutable</key><string>JinDesk</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.4</string>
  <key>CFBundleVersion</key><string>$VER</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>진의 데스크 페이지</string>
    <key>CFBundleURLSchemes</key><array><string>jindesk</string></array>
  </dict></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
EOF
codesign --force -s "$SIGN" "$APP"                # 확장을 먼저 서명한 뒤 앱을 서명해야 한다
"$LSREG" -f "$APP"   # jindesk:// 링크·위젯 확장 등록
pluginkit -a "$WX" 2>/dev/null || true
pkill -x JinDeskWidget 2>/dev/null || true   # 예전 버전 위젯 프로세스가 남아 있으면 "Bundle version did not match"로 다시 그리기가 실패한다

# 페이지 폴더: 대시보드 소스를 복사하고, 이 폴더에서 바로 열 수 있게 바로가기(pages)를 만든다
mkdir -p "$SUPPORT/pages" "$SUPPORT/data" "$SUPPORT/widget"
cp jin-desk.html "$SUPPORT/pages/jin-desk.html"
rm -f "$SUPPORT/pages/_widget.html" "$SUPPORT/data/widget-dim.log"   # 예전 창 위젯 흔적 (앱 3.5에서 없앰)
[ -e pages ] || ln -s "$SUPPORT/pages" pages

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
EOF

launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
for i in {1..20}; do launchctl print gui/$(id -u)/$LABEL >/dev/null 2>&1 || break; sleep 0.5; done   # 내려갈 때까지 대기
launchctl bootstrap gui/$(id -u) "$PLIST"
echo "설치 완료: $APP"
