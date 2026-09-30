#!/usr/bin/env swift
// Run from the repository root: swift scripts/generate-brand-assets.swift
// Shared daylight. Native renderer; SVG wordmarks retain vector font outlines.
import AppKit
import CoreText

let fm = FileManager.default
let branding = "docs/assets/branding", catalog = "AmbientSync/Assets.xcassets"
let paper = "#F7F8FA", ink = "#20242C", cobalt = "#1769E8"
let warm = "#FFD166", ochre = "#9A5700", muted = "#BAC2CF"
func write(_ text: String, _ path: String) throws {
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}
func color(_ hex: String) -> CGColor {
    let n = UInt32(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255, blue: CGFloat(n & 255)/255, alpha: 1)
}
func number(_ v: CGFloat) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), Double(v)) }
func pathData(_ path: CGPath) -> String {
    var result = ""
    path.applyWithBlock { e in
        let p = e.pointee.points
        func xy(_ i: Int) -> String { "\(number(p[i].x)) \(number(p[i].y))" }
        switch e.pointee.type {
        case .moveToPoint: result += "M\(xy(0)) "
        case .addLineToPoint: result += "L\(xy(0)) "
        case .addQuadCurveToPoint: result += "Q\(xy(0)) \(xy(1)) "
        case .addCurveToPoint: result += "C\(xy(0)) \(xy(1)) \(xy(2)) "
        case .closeSubpath: result += "Z "
        @unknown default: fatalError("Unsupported path element")
        }
    }
    return result
}
final class Canvas {
    let context: CGContext
    let width: Int, height: Int
    var svg = ""
    init(_ width: Int, _ height: Int) {
        self.width = width; self.height = height
        context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    }
    func path(_ p: CGPath, fill: String? = nil, stroke: String? = nil, width: CGFloat = 0, data: String? = nil) {
        svg += "<path d=\"\(data ?? pathData(p))\" fill=\"\(fill ?? "none")\""
        if let stroke { svg += " stroke=\"\(stroke)\" stroke-width=\"\(number(width))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"" }
        svg += "/>\n"
        context.addPath(p)
        if let fill { context.setFillColor(color(fill)) }
        if let stroke { context.setStrokeColor(color(stroke)); context.setLineWidth(width); context.setLineCap(.round); context.setLineJoin(.round) }
        context.drawPath(using: fill == nil ? .stroke : (stroke == nil ? .fill : .fillStroke))
    }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat = 0, fill: String) {
        path(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil), fill: fill)
    }
    func group(_ x: CGFloat, _ y: CGFloat, _ scale: CGFloat, _ draw: () -> Void) {
        svg += "<g transform=\"translate(\(number(x)) \(number(y))) scale(\(number(scale)))\">\n"
        context.saveGState(); context.translateBy(x: x, y: y); context.scaleBy(x: scale, y: scale)
        draw()
        context.restoreGState(); svg += "</g>\n"
    }
    func text(_ value: String, x: CGFloat, baseline: CGFloat, size: CGFloat, medium: Bool, tracking: CGFloat, fill: String) {
        let name = medium ? "HelveticaNeue-Medium" : "HelveticaNeue"
        let font = CTFontCreateWithName(name as CFString, size, nil)
        precondition(CTFontCopyPostScriptName(font) as String == name, "Required Helvetica Neue font unavailable")
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                  NSAttributedString.Key(kCTKernAttributeName as String): tracking]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs))
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs); CTRunGetPositions(run, CFRange(), &positions)
            for i in 0..<count {
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + positions[i].x, ty: baseline - positions[i].y)
                if let outline = CTFontCreatePathForGlyph(font, glyphs[i], &transform) { path(outline, fill: fill) }
            }
        }
    }
    func saveSVG(_ path: String) throws {
        try write("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\">\n\(svg)</svg>\n", path)
    }
    func savePNG(_ path: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}
func lines(_ segments: [[CGPoint]]) -> CGPath {
    let p = CGMutablePath()
    for points in segments { p.move(to: points[0]); for point in points.dropFirst() { p.addLine(to: point) } }
    return p
}
func points(_ values: [CGFloat]) -> [CGPoint] { stride(from: 0, to: values.count, by: 2).map { CGPoint(x: values[$0], y: values[$0+1]) } }
func sun(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    let p = CGMutablePath(); p.move(to: CGPoint(x: x-r, y: y))
    p.addArc(center: CGPoint(x: x, y: y), radius: r, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
    p.closeSubpath(); return p
}
func mark(_ c: Canvas, frame: String, sunColor: String, diagonals: Bool = true) {
    c.path(sun(50, 60, 16), fill: sunColor, data: "M34 60 A16 16 0 0 1 66 60 Z")
    c.path(CGPath(roundedRect: CGRect(x: 12, y: 20, width: 76, height: 56), cornerWidth: 10, cornerHeight: 10, transform: nil), stroke: frame, width: 6)
    c.path(lines([points([25,60,75,60]), points([50,76,50,84]), points([35,84,65,84])]), stroke: frame, width: 6)
    var rays = [points([50,31,50,35])]
    if diagonals { rays += [points([31,37,34,40]), points([69,37,66,40])] }
    c.path(lines(rays), stroke: frame, width: 6)
}
func appIcon(_ c: Canvas, diagonals: Bool = true) {
    c.rect(64,64,896,896,radius:200,fill:cobalt)
    c.group(192,176,6.4) { mark(c, frame:paper, sunColor:warm, diagonals:diagonals) }
}
func json(_ value: Any, _ path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try write(String(decoding:data,as:UTF8.self)+"\n",path)
}
let info: [String: Any] = ["author":"xcode", "version":1]
try json(["info":info], "\(catalog)/Contents.json")
var images = [[String: String]]()
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale, name = "app-icon-\(size)@\(scale)x.png"
        let c = Canvas(pixels,pixels)
        c.group(0,0,CGFloat(pixels)/1024) { appIcon(c, diagonals:pixels > 32) }
        try c.savePNG("\(catalog)/AppIcon.appiconset/\(name)")
        images.append(["idiom":"mac", "size":"\(size)x\(size)", "scale":"\(scale)x", "filename":name])
    }
}
try json(["images":images,"info":info],"\(catalog)/AppIcon.appiconset/Contents.json")
let master = Canvas(1024,1024); appIcon(master)
try master.saveSVG("\(branding)/app-icon.svg"); try master.savePNG("\(branding)/app-icon.png")
let canonical = Canvas(100,100); mark(canonical,frame:ink,sunColor:ochre)
try canonical.saveSVG("\(branding)/mark.svg")
for dark in [false,true] {
    let c = Canvas(800,160)
    c.group(8,8,1.44) { mark(c, frame:dark ? paper:ink, sunColor:dark ? warm:ochre) }
    c.text("AmbientSync",x:164,baseline:105,size:84,medium:true,tracking:-2,fill:dark ? paper:ink)
    try c.saveSVG("\(branding)/logo-\(dark ? "dark":"light").svg")
}
for scale in [1,2] {
    let c = Canvas(18*scale,18*scale)
    c.group(0,0,CGFloat(scale)) {
        c.path(sun(9,11.5,3),fill:"#000000",data:"M6 11.5 A3 3 0 0 1 12 11.5 Z")
        c.path(CGPath(roundedRect:CGRect(x:1.5,y:3.5,width:15,height:10),cornerWidth:2,cornerHeight:2,transform:nil),stroke:"#000000",width:1.5)
        c.path(lines([points([4,11.5,14,11.5]),points([9,13.5,9,16]),points([6,16,12,16])]),stroke:"#000000",width:1.5)
    }
    try c.savePNG("\(catalog)/MenuBarIcon.imageset/menu-bar@\(scale)x.png")
    try c.savePNG("\(branding)/menu-bar@\(scale)x.png")
    if scale == 1 { try c.saveSVG("\(branding)/menu-bar.svg") }
}
try json(["info":info,"properties":["template-rendering-intent":"template"],"images":[
    ["idiom":"mac","scale":"1x","filename":"menu-bar@1x.png"],
    ["idiom":"mac","scale":"2x","filename":"menu-bar@2x.png"]]],"\(catalog)/MenuBarIcon.imageset/Contents.json")
for github in [false,true] {
    let c = Canvas(github ? 1280:1200,github ? 640:630)
    c.rect(0,0,CGFloat(c.width),CGFloat(c.height),fill:ink)
    c.group(github ? 40:0,github ? 5:0,1) {
        c.group(64,115,400/1024) { appIcon(c) }
        c.text("AmbientSync",x:504,baseline:294,size:64,medium:true,tracking:-1.5,fill:paper)
        c.text("Brightness in sync.",x:507,baseline:352,size:28,medium:false,tracking:0,fill:muted)
    }
    let name = github ? "github-social-preview":"social-card"
    try c.saveSVG("\(branding)/\(name).svg"); try c.savePNG("\(branding)/\(name).png")
}
let profile = Canvas(1024,1024); profile.rect(0,0,1024,1024,fill:cobalt)
profile.group(192,176,6.4) { mark(profile,frame:paper,sunColor:warm) }
try profile.saveSVG("\(branding)/profile.svg"); try profile.savePNG("\(branding)/profile.png")
print("Generated Shared daylight assets in \(branding) and \(catalog)")
