import AppKit

let output = CommandLine.arguments[1]
let side = 1024.0
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()
let square = NSRect(x: 30, y: 30, width: 964, height: 964)
let backdrop = NSBezierPath(roundedRect: square, xRadius: 218, yRadius: 218)
NSColor(calibratedRed:0.055,green:0.065,blue:0.09,alpha:1).setFill(); backdrop.fill()
NSColor.white.withAlphaComponent(0.09).setStroke(); backdrop.lineWidth = 3; backdrop.stroke()
let colors: [NSColor] = [NSColor(calibratedRed:0.98,green:0.40,blue:0.43,alpha:1),NSColor(calibratedRed:0.99,green:0.65,blue:0.35,alpha:1),NSColor(calibratedRed:0.88,green:0.77,blue:0.38,alpha:1),NSColor(calibratedRed:0.38,green:0.76,blue:0.59,alpha:1),NSColor(calibratedRed:0.29,green:0.70,blue:0.80,alpha:1),NSColor(calibratedRed:0.56,green:0.51,blue:0.94,alpha:1)]
let spans: [Double] = [80,65,48,60,47,60]
for ring in 0..<4 {
    var start = 90.0
    for (index, span) in spans.enumerated() {
        let count = ring == 0 ? 1 : ring + (index % 2)
        for part in 0..<count {
            if ring == 3 && (index == 2 || (index == 4 && part > 1)) { continue }
            let a = start - Double(part) * span / Double(count) - 0.7
            let b = start - Double(part+1) * span / Double(count) + 0.7
            let inner = 150.0 + Double(ring) * 60
            let path = NSBezierPath()
            path.appendArc(withCenter:NSPoint(x:512,y:512),radius:inner+55,startAngle:a,endAngle:b,clockwise:true)
            path.appendArc(withCenter:NSPoint(x:512,y:512),radius:inner,startAngle:b,endAngle:a,clockwise:false)
            path.close()
            colors[index].withAlphaComponent(1 - Double(ring)*0.09).setFill(); path.fill()
        }
        start -= span
    }
}
let core = NSBezierPath(ovalIn:NSRect(x:473,y:473,width:78,height:78))
NSColor(calibratedRed:0.68,green:0.73,blue:1,alpha:1).setFill(); core.fill()
image.unlockFocus()
let data = NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
try data.write(to:URL(fileURLWithPath:output))
