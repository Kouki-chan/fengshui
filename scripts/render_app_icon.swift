// Renders the HealthBot app icons from apple/Fengshui/UI/Design/HealthBotLogo.swift.
// Run: scripts/render_app_icon.sh  (compiles this file together with the logo view)
import AppKit
import SwiftUI

@main
struct RenderAppIcon {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
        let jobs: [(String, HealthBotIcon.Variant)] = [("AppIcon.png", .standard), ("AppIcon-dark.png", .dark),
                                                        ("AppIcon-tinted.png", .tinted), ("WatchIcon.png", .watch)]
        for (name, variant) in jobs {
            let r = ImageRenderer(content: HealthBotIcon(variant: variant).frame(width: 1024, height: 1024))
            r.scale = 1
            guard let cg = r.cgImage else { throw NSError(domain: "render", code: 1) }
            // App icons must be opaque: redraw into an RGB context without alpha.
            let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
            print("wrote \(name)")
        }
    }
}
