// Gera o ícone do app como .icns, sem depender de assets ou do Xcode.
//
// Não podemos usar .xcassets: o `actool` que os compila é um shim que exige o Xcode.app
// completo, e só temos as Command Line Tools. O `iconutil`, ao contrário, é um binário
// real em /usr/bin e funciona — então desenhamos os PNGs aqui e deixamos ele montar.
//
// Uso: swift scripts/make-icon.swift <saída.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

/// Desenha a marca: uma forma de onda estilizada sobre fundo escuro arredondado, no
/// mesmo espírito minimalista da interface.
func drawIcon(size: Int) -> Data? {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return nil }

    // Fundo: "squircle" no raio que a Apple usa para ícones de app (~22.4% do lado).
    let inset = dimension * 0.06
    let rect = CGRect(x: inset, y: inset,
                      width: dimension - inset * 2, height: dimension - inset * 2)
    let radius = rect.width * 0.224
    let background = CGPath(roundedRect: rect,
                            cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(background)
    context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
    context.fillPath()

    // Onda: barras verticais de alturas variadas, centradas.
    let heights: [CGFloat] = [0.28, 0.52, 0.86, 0.62, 1.0, 0.44, 0.72, 0.34]
    let barWidth = rect.width * 0.055
    let gap = barWidth * 0.85
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - totalWidth / 2
    let maxBarHeight = rect.height * 0.46

    context.setFillColor(NSColor.white.cgColor)
    for factor in heights {
        let barHeight = maxBarHeight * factor
        let bar = CGRect(x: x, y: rect.midY - barHeight / 2,
                         width: barWidth, height: barHeight)
        context.addPath(CGPath(roundedRect: bar,
                               cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                               transform: nil))
        context.fillPath()
        x += barWidth + gap
    }

    guard let cgImage = context.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    bitmap.size = NSSize(width: dimension, height: dimension)
    return bitmap.representation(using: .png, properties: [:])
}

// O iconutil espera um .iconset com nomes exatos por tamanho e escala.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Capita-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = drawIcon(size: variant.size) else {
        FileHandle.standardError.write(Data("falha ao desenhar \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let output = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil falhou\n".utf8))
    exit(1)
}
print("ícone gerado: \(output.path)")
