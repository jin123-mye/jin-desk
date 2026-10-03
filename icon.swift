// 앱 아이콘 그리기: swift icon.swift <출력.png>  → 1024×1024 PNG
// 어두운 바탕 위에 대시보드의 세 패널(일정 보라·메일 파랑·드라이브 초록) 카드를 쌓은 모양. 색은 jin-desk.html 다크 토큰과 같다.
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
func hex(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}
func rr(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad) }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS 아이콘 격자: 1024 캔버스 안 824 본체(여백 100), 모서리 약 185
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = rr(body, 185)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.35); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set(); hex(0x10141B).setFill(); squircle.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(starting: hex(0x222A38), ending: hex(0x0E1218))!.draw(in: body, angle: -90)
// 위쪽 은은한 빛
NSGradient(colors: [hex(0xFFFFFF, 0.10), hex(0xFFFFFF, 0)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)

// 세 패널 카드
let cards: [(accent: UInt32, soft: UInt32, lines: [CGFloat], live: Bool)] = [
    (0xB9A6F7, 0x2A2344, [0.62, 0.40], true),    // 일정 (진행 중 강조)
    (0x8DA8F5, 0x1F2A47, [0.70, 0.48], false),   // 메일
    (0x5FCB9F, 0x16302A, [0.54, 0.36], false),   // 드라이브
]
let cw: CGFloat = 612, ch: CGFloat = 158, gap: CGFloat = 40
let cx = (S - cw) / 2
var y = S / 2 + (3 * ch + 2 * gap) / 2 - ch - 6
for c in cards {
    let r = NSRect(x: cx, y: y, width: cw, height: ch)
    NSGraphicsContext.saveGraphicsState()
    let s2 = NSShadow(); s2.shadowColor = .black.withAlphaComponent(0.45); s2.shadowBlurRadius = 18; s2.shadowOffset = NSSize(width: 0, height: -6); s2.set()
    hex(c.live ? 0x2B3242 : 0x222936).setFill(); rr(r, 38).fill()
    NSGraphicsContext.restoreGraphicsState()
    hex(0xFFFFFF, c.live ? 0.10 : 0.05).setStroke(); let b = rr(r.insetBy(dx: 1.5, dy: 1.5), 37); b.lineWidth = 3; b.stroke()
    // 왼쪽 색 막대 + 동그란 표식
    NSGraphicsContext.saveGraphicsState(); rr(r, 38).addClip()
    hex(c.accent).setFill(); NSRect(x: r.minX, y: r.minY, width: 30, height: ch).fill()
    NSGraphicsContext.restoreGraphicsState()
    let dot = NSRect(x: r.minX + 52, y: r.midY - 36, width: 72, height: 72)
    hex(c.soft).setFill(); rr(dot, 22).fill()
    hex(c.accent).setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: 17, dy: 17)).fill()
    // 글줄 두 개
    let tx = dot.maxX + 36, tw = r.maxX - 44 - tx
    hex(0xE7EAF0, c.live ? 0.92 : 0.78).setFill(); rr(NSRect(x: tx, y: r.midY + 8, width: tw * c.lines[0] / 0.7, height: 26), 13).fill()
    hex(0xA1A9B8, 0.55).setFill(); rr(NSRect(x: tx, y: r.midY - 38, width: tw * c.lines[1] / 0.7, height: 20), 10).fill()
    y -= ch + gap
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("저장:", out)
