import SwiftUI
import AppKit
import WidgetKit
// README용 위젯 그림: 위젯 보기 코드를 그대로 쓰고 데이터만 지어낸 샘플로 넣는다
let cal = Calendar.current
let now = cal.date(bySettingHour: 13, minute: 20, second: 0, of: Date())!
let ms = now.timeIntervalSince1970 * 1000, h = 3_600_000.0, m = 60_000.0
let day0 = cal.startOfDay(for: now).timeIntervalSince1970 * 1000
let sample = Feed(updatedAt: ms, error: nil, unread: 12, unreadExact: true, hideAds: true, todayMail: 3, driveWeek: 4,
    events: [.init(title: "캡스톤 팀 회의", start: ms - 20 * m, end: ms + 40 * m, allDay: false, url: nil),
             .init(title: "도서 반납", start: ms + 35 * m, end: ms + 65 * m, allDay: false, url: nil),
             .init(title: "알고리즘 스터디", start: day0 + 21 * h, end: day0 + 22.5 * h, allDay: false, url: nil)],
    mails: [.init(from: "학과사무실", subject: "캡스톤디자인 중간발표 순서 안내", t: ms - 36 * m, url: nil),
            .init(from: "GitHub", subject: "[team-project] PR #42 리뷰 요청이 도착했습니다", t: ms - 2 * h, url: nil),
            .init(from: "도서관", subject: "대출 도서 반납 예정 알림", t: ms - 5 * h, url: nil),
            .init(from: "팀 프로젝트", subject: "이번 주 회의 시간 투표", t: ms - 26 * h, url: nil)])
let entry = DeskEntry(date: now, feed: sample, preview: false)

@MainActor func render(_ fam: WidgetFamily, _ size: CGSize, _ scheme: ColorScheme, _ out: String) {
    let bg = scheme == .dark ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.97, green: 0.97, blue: 0.98)
    let v = DeskView(family: fam, entry: entry)
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, scheme)
        .padding(20)
    let r = ImageRenderer(content: v); r.scale = 2
    guard let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
          let png = rep.representation(using: .png, properties: [:]) else { print("실패", out); return }
    try! png.write(to: URL(fileURLWithPath: out)); print("저장", out, img.size)
}
let dir = CommandLine.arguments[1]
MainActor.assumeIsolated {
    render(.systemLarge, CGSize(width: 344, height: 344), .dark, dir + "/widget-large.png")
    render(.systemMedium, CGSize(width: 344, height: 160), .dark, dir + "/widget-medium.png")
    render(.systemSmall, CGSize(width: 160, height: 160), .dark, dir + "/widget-small.png")
}
// ImageRenderer는 Link를 그리지 못해(노란 금지 표시) 그림에서만 내용만 보여 준다
struct FakeLink<C: View>: View {
    let content: C
    init(destination: URL, @ViewBuilder label: () -> C) { content = label() }
    var body: some View { content }
}
