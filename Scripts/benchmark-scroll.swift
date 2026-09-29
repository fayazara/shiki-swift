import AppKit
import SwiftUI
import Shiki
@main struct ScrollBench {
 @MainActor static func main() throws {
  _ = NSApplication.shared
  let arguments = CommandLine.arguments
  let code = arguments.count > 1
   ? try String(contentsOfFile: arguments[1], encoding: .utf8)
   : Array(repeating: "let greeting = \"Hello, Swift 🙂\" // highlighted code", count: 10_000).joined(separator: "\n")
  let language = arguments.count > 2 ? arguments[2] : "swift"
  let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
  let result = try highlighter.codeToTokens(code, language: language)
  let view = ShikiTextViewport(result: result, renderID: 1, font: .monospacedSystemFont(ofSize: 15, weight: .regular), padding: 16)
  let coordinator = view.makeCoordinator()
  let scroll = view.makeScrollView(coordinator: coordinator)
  let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = scroll
  scroll.layoutSubtreeIfNeeded()
  let text = scroll.documentView as! ShikiCodeDocumentView
  let layout = text.textView.textLayoutManager!
  layout.textViewportLayoutController.layoutViewport()
  let doc = coordinator.document!
  func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
  func ms(_ start: UInt64) -> Double { Double(now()-start)/1e6 }
  print("Release scroll + layout timings; excludes painting and display FPS")
  print("initial paragraphs=\(doc.renderedParagraphCount)")
  for requestedRow in [20,40,60,80,100,200,400,800,1600,3000,5000,0,3000,0] {
   let row = min(requestedRow, max(0, doc.visualLineOffsets.count - 1))
   let count=doc.renderedParagraphCount
   let start=now()
   scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(row)*doc.lineHeight))
   scroll.reflectScrolledClipView(scroll.contentView)
   let scrollMS=ms(start)
   let layoutStart=now()
   scroll.layoutSubtreeIfNeeded()
   layout.textViewportLayoutController.layoutViewport()
   let layoutMS=ms(layoutStart)
   print(String(format:"row=%d scroll_ms=%.2f layout_ms=%.2f new_paragraphs=%d cache=%d",row,scrollMS,layoutMS,doc.renderedParagraphCount-count,doc.cachedParagraphCount))
  }
  // Horizontal jumps matter for long (e.g. minified) lines.
  print(String(format:"document width=%.0f", text.frame.width))
  for fraction in [0.25, 0.5, 0.99, 0.0] {
   let x = max(0, (text.frame.width - scroll.contentSize.width) * fraction)
   let start=now()
   scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
   scroll.reflectScrolledClipView(scroll.contentView)
   scroll.layoutSubtreeIfNeeded()
   layout.textViewportLayoutController.layoutViewport()
   var visible = 0
   layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
    visible += fragment.textLineFragments.count; return true
   }
   print(String(format:"x=%.0f total_ms=%.2f line_fragments=%d", x, ms(start), visible))
  }
 }
}
