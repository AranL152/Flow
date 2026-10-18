// Isolated native source probe. Never changes the general clipboard, reads
// the real Downloads directory, attaches a file, or sends a message.
import AppKit
import Foundation

var checks: [String: Bool] = [:]
let board = NSPasteboard(name: NSPasteboard.Name("com.flow.attachment-probe.\(UUID().uuidString)"))
defer { board.releaseGlobally() }
let image = NSImage(size: NSSize(width: 8, height: 8))
image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill(); image.unlockFocus()
board.clearContents(); board.writeObjects([image])
let capturedCount = board.changeCount
let snapshot = board.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
let retainedImage = snapshot?.tiffRepresentation
checks["clipboard_image_readable"] = retainedImage != nil
// A text insertion uses the same pasteboard in the buffered fallback. Keeping
// the image bytes first is necessary; the current clipboard no longer has them.
board.clearContents(); board.setString("generated text", forType: .string)
checks["clipboard_change_detected"] = board.changeCount != capturedCount
checks["captured_image_survives_text_paste"] = retainedImage != nil && board.readObjects(forClasses: [NSImage.self], options: nil)?.isEmpty != false

let files = FileManager.default
let folder = files.temporaryDirectory.appendingPathComponent("flow-attachment-source-\(UUID())")
try files.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? files.removeItem(at: folder) }
let old = folder.appendingPathComponent("older-deck.pdf")
let recent = folder.appendingPathComponent("recent-deck.pdf")
let partial = folder.appendingPathComponent("newest.pdf.crdownload")
let unrelated = folder.appendingPathComponent("newer-archive.zip")
for file in [old, recent, partial, unrelated] { try Data("synthetic fixture".utf8).write(to: file) }
// Imported documents can carry an old modification date. Recency should come
// from download/directory-observation evidence, not that embedded timestamp.
try files.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: recent.path)
let observedArrival = [old.lastPathComponent: 10, recent.lastPathComponent: 20, partial.lastPathComponent: 40, unrelated.lastPathComponent: 30]
let candidates = try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.addedToDirectoryDateKey])
let pdfs = try candidates.filter { url in
    let values = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
    return values.isRegularFile == true && values.isSymbolicLink != true && url.pathExtension.lowercased() == "pdf"
}.sorted { observedArrival[$0.lastPathComponent,default:0] > observedArrival[$1.lastPathComponent,default:0] }
checks["latest_matching_pdf_selected"] = pdfs.first?.standardizedFileURL.path == recent.standardizedFileURL.path
checks["partial_download_and_wrong_type_excluded"] = !pdfs.contains(partial) && !pdfs.contains(unrelated)
checks["modification_time_is_not_download_recency"] = try recent.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate == Date(timeIntervalSince1970:1)
board.clearContents(); board.writeObjects([recent as NSURL])
let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly:true]) as? [URL]
checks["clipboard_file_url_readable"] = urls?.first == recent
let added = try recent.resourceValues(forKeys:[.addedToDirectoryDateKey]).addedToDirectoryDate
let result: [String:Any] = ["kind":"native private-pasteboard and temporary-file fixtures", "checks":checks,
    "passed":checks.values.allSatisfy{$0}, "added_to_directory_date_available_on_fixture_volume":added != nil,
    "limitations":["Download ordering uses a synthetic observation log; no browser download history or actual Downloads access was tested", "No general clipboard changes or real message attachment insertion"], "file_candidates":candidates.count, "selected_pdf":pdfs.first?.lastPathComponent ?? "none"]
let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
if CommandLine.arguments.count > 1 { try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
print(String(decoding:data,as:UTF8.self))
if !checks.values.allSatisfy({$0}) { exit(1) }
