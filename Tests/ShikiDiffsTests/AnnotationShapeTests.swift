import AppKit
import Testing
@testable import ShikiDiffs

struct AnnotationShapeTests {
    @Test @MainActor func annotationAppearanceFollowsCodeThemeAndRespectsExplicitOverride() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let highlighter = DiffHighlighter()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        defer { window.close() }
        let view = NativeFileView(frame: .init(x: 0, y: 0, width: 600, height: 400)); window.contentView = view
        let comments = [FileLineAnnotation(id: "inherited", lineNumber: 0, text: "Inherited"),
                        FileLineAnnotation(id: "explicit", lineNumber: 1, text: "Explicit")]
        var cards: [String: NSView] = [:]
        view.diffView.renderAnnotation = { annotation in
            let card = NSTextField(labelWithString: annotation.text)
            if annotation.id == "explicit" { card.appearance = NSAppearance(named: .aqua) }
            cards[annotation.id] = card
            return card
        }
        for theme in ["pierre-dark", "pierre-light", "pierre-dark"] {
            var options = DiffRenderOptions(); options.theme = theme
            let document = try await highlighter.prepare(oldFile: file, newFile: file, options: options)
            view.render(document, file: file, options: options, fileAnnotations: comments)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let inherited = try #require(cards["inherited"])
            let explicit = try #require(cards["explicit"])
            let expected: NSAppearance.Name = theme == "pierre-light" ? .aqua : .darkAqua
            #expect(inherited.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(explicit.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        }
    }

    @Test func fileEqualityUsesLineAndStrictMetadata() {
        let metadata = LineAnnotationMetadata(["author": "Ada"])
        let a = FileLineAnnotation(id: "a", lineNumber: 1, text: "First", metadata: metadata)
        var b = FileLineAnnotation(id: "b", lineNumber: 1, text: "Other", metadata: metadata)
        #expect(areLineAnnotationsEqual(a, b))
        b.metadata = LineAnnotationMetadata(["author": "Ada"])
        #expect(!areLineAnnotationsEqual(a, b))
        b.metadata = metadata; b.lineNumber = 2
        #expect(!areLineAnnotationsEqual(a, b))
        let nan = FileLineAnnotation(lineNumber: 1, text: "", metadata: .init(primitive: .number(.nan)))
        #expect(!areLineAnnotationsEqual(nan, nan))
    }

    @Test @MainActor func fileHostsAcceptSideLessComments() async throws {
        let file = FileContents(name: "f.txt", contents: "first\nsecond\n")
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let metadata = LineAnnotationMetadata(primitive: .string("review"))
        let comments = [FileLineAnnotation(id: "above", lineNumber: 0, text: "Header", metadata: metadata),
                        FileLineAnnotation(id: "line", lineNumber: 2, text: "Comment", metadata: metadata)]
        let host = FileView(document: document, file: file, fileAnnotations: comments)
        #expect(host.annotations.map(\.id) == ["above", "line"])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeFileView(frame: .init(x: 0, y: 0, width: 600, height: 400)); window.contentView = view
        var rendered: [String: LineAnnotation] = [:]
        view.diffView.renderAnnotation = { annotation in
            rendered[annotation.id] = annotation
            return NSTextField(labelWithString: annotation.text)
        }
        view.render(document, file: file, fileAnnotations: comments)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(Set(rendered.keys) == ["above", "line"])
        #expect(rendered["above"]?.lineNumber == 0)
        #expect(rendered["line"]?.side == .additions)
        #expect(rendered["line"]?.metadata === metadata)
    }

    @Test func shapeIsIndependentOfRenderedSideAndEmptyCollectionsMatchBoth() {
        let file = EditorAnnotation.file(.init(id: "file", lineNumber: 0, text: "Above file"))
        let diff = EditorAnnotation.diff(.init(id: "diff", side: .additions, lineNumber: 1, text: "Addition"))
        #expect(isFileAnnotation(file) && !isDiffAnnotation(file))
        #expect(isDiffAnnotation(diff) && !isFileAnnotation(diff))
        #expect(isDiffAnnotationCollection([]) && isFileAnnotationCollection([]))
        #expect(isFileAnnotationCollection([file, diff]))
        #expect(!isDiffAnnotationCollection([file, diff]))
        #expect(isDiffAnnotationCollection([diff, file]))
        #expect(!isFileAnnotationCollection([diff, file]))
    }
    @Test func fileAdapterPreservesIdentityMetadataAndAboveFilePosition() {
        let metadata = LineAnnotationMetadata(primitive: .string("comment"))
        let file = FileLineAnnotation(id: "stable", lineNumber: 0, text: "Review", metadata: metadata)
        let rendered = EditorAnnotation.file(file).renderedAnnotation
        #expect(rendered.id == "stable" && rendered.lineNumber == 0)
        #expect(rendered.side == .additions && rendered.text == "Review")
        #expect(rendered.metadata === metadata)
    }
}
