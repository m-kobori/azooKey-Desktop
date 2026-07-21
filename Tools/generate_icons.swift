// Kiwi のアイコン生成スクリプト。
// 使い方: swift Tools/generate_icons.swift
// メニューバー用テンプレート（main/en .tiff）と AppIcon の PNG 一式を再生成する。
import AppKit
import Foundation

let repo = "/Users/kobosta/projects/kiwi/azooKey-Desktop/azooKeyMac"

func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
}

func draw(into rep: NSBitmapImageRep, _ body: (CGFloat, CGFloat) -> Void) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body(CGFloat(rep.pixelsWide), CGFloat(rep.pixelsHigh))
    NSGraphicsContext.restoreGraphicsState()
}

func drawCenteredText(_ text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor, center: CGPoint) {
    let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let str = NSAttributedString(string: text, attributes: attrs)
    let size = str.size()
    // 光学的な中央合わせ（フォントメトリクスの余白を補正）
    let rect = NSRect(
        x: center.x - size.width / 2,
        y: center.y - size.height / 2 - fontSize * 0.02,
        width: size.width, height: size.height
    )
    str.draw(in: rect)
}

// MARK: - メニューバー テンプレートアイコン（黒＋アルファ。円=キウイ輪切り + 文字）
func drawMenuIcon(letter: String, width: Int, height: Int, scale: CGFloat) -> NSBitmapImageRep {
    let rep = makeBitmap(width: width, height: height)
    draw(into: rep) { w, h in
        let black = NSColor.black
        let cx = w / 2
        let cy = h / 2
        let r = (h / 2 - 1 * scale)
        // 円（輪切りの外形）
        let stroke = 1.3 * scale
        let circle = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        circle.lineWidth = stroke
        black.setStroke()
        circle.stroke()
        // 文字
        drawCenteredText(letter, fontSize: 8.6 * scale, weight: .bold, color: black, center: CGPoint(x: cx, y: cy))
    }
    return rep
}

// MARK: - アプリアイコン（キウイの輪切り + あ）
func drawAppIcon(size: Int) -> NSBitmapImageRep {
    let rep = makeBitmap(width: size, height: size)
    draw(into: rep) { s, _ in
        let inset = s * 0.08
        let squircle = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.185, yRadius: s * 0.185)
        // 背景（クリーム）
        NSColor(calibratedRed: 0.97, green: 0.95, blue: 0.90, alpha: 1).setFill()
        squircle.fill()

        let cx = s / 2, cy = s / 2
        let r = s * 0.335
        // 皮（茶）
        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
        // 果肉（緑のグラデーション: 外側濃→中心淡）
        let flesh = r * 0.93
        let gradient = NSGradient(
            starting: NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.62, alpha: 1),
            ending: NSColor(calibratedRed: 0.44, green: 0.72, blue: 0.20, alpha: 1)
        )!
        let fleshPath = NSBezierPath(ovalIn: NSRect(x: cx - flesh, y: cy - flesh, width: flesh * 2, height: flesh * 2))
        gradient.draw(in: fleshPath, relativeCenterPosition: .zero)
        // 種（黒の小さな滴を放射状に）
        NSColor(calibratedRed: 0.12, green: 0.10, blue: 0.05, alpha: 1).setFill()
        let seedCount = 16
        let seedR = r * 0.60
        for i in 0 ..< seedCount {
            let angle = CGFloat(i) / CGFloat(seedCount) * 2 * .pi + .pi / 7
            let sx = cx + cos(angle) * seedR
            let sy = cy + sin(angle) * seedR
            let seedW = r * 0.055, seedH = r * 0.10
            let path = NSBezierPath(ovalIn: NSRect(x: -seedW / 2, y: -seedH / 2, width: seedW, height: seedH))
            // 自身の中心回りに回転してから配置（translate → rotate の順で適用）
            var t = AffineTransform.identity
            t.translate(x: sx, y: sy)
            t.rotate(byRadians: angle - .pi / 2)
            path.transform(using: t)
            path.fill()
        }
        // 芯（淡い中心）
        let core = r * 0.34
        NSColor(calibratedRed: 0.95, green: 0.97, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: cx - core, y: cy - core * 1.05, width: core * 2, height: core * 2.1)).fill()
        // 「あ」（芯の上に濃緑で）
        drawCenteredText("あ", fontSize: s * 0.30, weight: .heavy,
                         color: NSColor(calibratedRed: 0.16, green: 0.35, blue: 0.10, alpha: 1),
                         center: CGPoint(x: cx, y: cy))
    }
    return rep
}

func writeTIFF(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.tiffRepresentation!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}
func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// メニューアイコン（22x16 / 44x32）
writeTIFF(drawMenuIcon(letter: "あ", width: 22, height: 16, scale: 1), to: "\(repo)/main.tiff")
writeTIFF(drawMenuIcon(letter: "あ", width: 44, height: 32, scale: 2), to: "\(repo)/main@2x.tiff")
writeTIFF(drawMenuIcon(letter: "A", width: 22, height: 16, scale: 1), to: "\(repo)/en.tiff")
writeTIFF(drawMenuIcon(letter: "A", width: 44, height: 32, scale: 2), to: "\(repo)/en@2x.tiff")

// アプリアイコン
for size in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(drawAppIcon(size: size), to: "\(repo)/Assets.xcassets/AppIcon.appiconset/\(size).png")
}
print("done")
