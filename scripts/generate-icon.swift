import AppKit
let size=1024
let image=NSImage(size:NSSize(width:size,height:size))
image.lockFocus()
NSColor(calibratedRed:0.08,green:0.21,blue:0.17,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:32,y:32,width:960,height:960),xRadius:225,yRadius:225).fill()
let text="e" as NSString
let attrs:[NSAttributedString.Key:Any]=[.font:NSFont(name:"Georgia-BoldItalic",size:830) ?? NSFont.boldSystemFont(ofSize:830),.foregroundColor:NSColor(calibratedRed:0.83,green:0.90,blue:0.62,alpha:1)]
text.draw(at:NSPoint(x:265,y:34),withAttributes:attrs)
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"build/icon.png"))
