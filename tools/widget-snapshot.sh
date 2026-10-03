#!/bin/zsh
# README용 위젯 그림 만들기: 위젯 보기 코드(Widget/JinDeskWidget.swift)를 그대로 쓰고 지어낸 샘플 데이터로 그린다
# 실제 위젯·메일은 건드리지 않는다. 결과: docs/widget-{large,medium,small}.png
set -e
cd "$(dirname "$0")/.."
swiftc --version >/dev/null 2>&1 || export DEVELOPER_DIR=/Library/Developer/CommandLineTools
T=$(mktemp -d)
# @main 빼기, 크기(family)를 인자로 받게, Link는 그림에서 못 그리므로 내용만 보이는 FakeLink로
sed -e 's/^@main$//' -e 's/@Environment(\\.widgetFamily) var family/var family: WidgetFamily = .systemLarge/' \
    -e 's/Link(destination:/FakeLink(destination:/g' Widget/JinDeskWidget.swift > "$T/Widget.swift"
cp tools/widget-snapshot.swift "$T/main.swift"
swiftc -target arm64-apple-macos14.0 "$T/Widget.swift" "$T/main.swift" -o "$T/render" -framework WidgetKit -framework SwiftUI
"$T/render" docs
rm -rf "$T"
