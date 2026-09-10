import AppKit

/// Programmatic access to the general pasteboard. Cut, copy and paste inside
/// the page already work through the Edit menu; this is for the rest.
public struct Clipboard: SashExtension {
    public static let namespace = "clipboard"

    public init() {}

    struct Text: Codable, Sendable { var text: String }
    struct Image: Codable, Sendable { var png: String }

    public func register(in r: Registry) {
        r.call("readText") { () -> String? in
            NSPasteboard.general.string(forType: .string)
        }
        r.call("writeText") { (a: Text) in
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(a.text, forType: .string)
        }
        r.call("readImage") { () -> Image? in
            guard let image = NSImage(pasteboard: NSPasteboard.general),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            return Image(png: png.base64EncodedString())
        }
        r.call("writeImage") { (a: Image) in
            guard let data = Data(base64Encoded: a.png), let image = NSImage(data: data) else {
                throw CallError.invalidArgs("png is not base64 PNG data")
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
        }
        r.call("clear") { NSPasteboard.general.clearContents() }
    }
}
