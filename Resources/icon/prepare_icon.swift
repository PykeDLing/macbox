// 把一张整图（圆角底板画在白底上、没有透明通道）整理成 macOS 图标母版：
// 自动找出底板边界 → 裁出底板 → 按 macOS 图标网格放进 1024 画布（底板 824×824，四周留 100）
// → 用 macOS 图标圆角裁掉白底 → 加上系统图标同样的投影。
// 用法：swiftc prepare_icon.swift -o prepare && ./prepare 原图.png AppIcon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("用法：prepare 原图.png 输出.png\n".utf8))
    exit(1)
}

// MARK: - 找底板边界

let w = image.width, h = image.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

/// 亮度（内存第 0 行是图片顶部）
func brightness(_ x: Int, _ y: Int) -> Int {
    let i = (y * w + x) * 4
    return (Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3
}

/// 从图片边缘沿一条线向内走：先经过越来越暗的投影，底板的亮边处亮度突然回升，那里就是底板边缘
func edge(along line: [(Int, Int)]) -> Int? {
    // 亮边过渡可能跨两三个像素，和 3 像素之前比较
    for index in 3..<line.count / 4 {
        let (x, y) = line[index], (px, py) = line[index - 3]
        if brightness(x, y) - brightness(px, py) > 20 { return index }
    }
    return nil
}

let left = edge(along: (0..<w).map { ($0, h / 2) }) ?? 0
let right = w - (edge(along: (0..<w).reversed().map { ($0, h / 2) }) ?? 0)
let top = edge(along: (0..<h).map { (w / 2, $0) }) ?? 0
let bottom = h - (edge(along: (0..<h).reversed().map { (w / 2, $0) }) ?? 0)
print("底板：x \(left)…\(right)，y \(top)…\(bottom)（原图 \(w)×\(h)）")

// 向内收 1% 再裁：去掉底板自带的亮边和外圈投影，边缘交给新的圆角蒙版
let inset = Double(right - left) * 0.01
let plate = image.cropping(to: CGRect(x: Double(left) + inset, y: Double(top) + inset,
                                      width: Double(right - left) - inset * 2,
                                      height: Double(bottom - top) - inset * 2))!

// MARK: - 按 macOS 图标网格绘制

let size = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

/// macOS 图标网格的底板形状：824 底板配 185 圆角（与原图底板约 22% 的圆角一致）
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
// 投影：与系统图标一致，向下偏移、柔和
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
              color: CGColor(colorSpace: space, components: [0, 0, 0, 0.30])!)
ctx.addPath(shape)
ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
ctx.fillPath()
ctx.restoreGState()
// 底板内容
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(plate, in: body)
ctx.restoreGState()

let output = URL(fileURLWithPath: args[2])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
print("✅ \(output.lastPathComponent)")
