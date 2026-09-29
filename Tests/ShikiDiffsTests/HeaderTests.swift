import AppKit
import Testing
@testable import ShikiDiffs

@Suite(.serialized) struct HeaderTests {
    @Test @MainActor func reviewHeaderFooterContributeToExtentAndPreserveAnchor() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 20))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 100))
        let header = NSView(frame: .init(x: 0, y: 0, width: 600, height: 120))
        let footer = NSView(frame: .init(x: 0, y: 0, width: 600, height: 60))
        view.reviewHeader = header; view.reviewFooter = footer
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(Array(repeating: document, count: 3), options: options)
        let host = try #require(view.scrollView.documentView)
        #expect(host.frame.height == 1412)
        #expect(header.frame.minY == 0 && footer.frame.maxY == host.frame.height)
        view.scrollToFile(at: 1)
        #expect(view.scrollView.contentView.bounds.minY == 536)
        header.setFrameSize(.init(width: 600, height: 200))
        view.invalidateReviewChromeLayout(); view.layoutSubtreeIfNeeded()
        #expect(view.scrollView.contentView.bounds.minY == 616)
        #expect(header.superview === host && footer.superview === host)
        view.reviewHeader = nil; view.reviewFooter = nil; view.layoutSubtreeIfNeeded()
        #expect(header.superview == nil && footer.superview == nil)
        #expect(host.frame.height == 1232)
        #expect(view.scrollView.contentView.bounds.minY == 416)
    }

    @Test @MainActor func customSlotsAndReplacementLifecycle() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new\n"))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        var pinnedOptions = DiffRenderOptions(); pinnedOptions.stickyHeader = true
        view.render(document, options: pinnedOptions)
        let header = try #require(view.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(header.filename.stringValue == "f.txt")
        #expect(header.counts.stringValue == "−1  +1")
        let prefix = NSTextField(labelWithString: "PREFIX"), suffix = NSTextField(labelWithString: "SUFFIX")
        let metadata = NSButton(title: "Review", target: nil, action: nil)
        var calls = 0
        view.headerRenderers = .init(renderHeaderPrefix: { diff in
            #expect(diff.name == "f.txt"); calls += 1; return prefix
        }, renderHeaderFilenameSuffix: { _ in suffix }, renderHeaderMetadata: { _ in metadata })
        view.layoutSubtreeIfNeeded()
        #expect(calls == 1)
        #expect(prefix.superview === header && metadata.superview === header)
        #expect(prefix.frame.maxX <= header.filename.frame.minX)
        #expect(header.filename.frame.maxX <= suffix.frame.minX)
        #expect(header.counts.frame.maxX <= metadata.frame.minX)
        let slotHeight = header.frame.height
        let custom = NSView(frame: .init(x: 0, y: 0, width: 400, height: 84))
        view.headerRenderers.renderCustomHeader = { _ in custom }
        view.layoutSubtreeIfNeeded()
        #expect(calls == 1)
        #expect(prefix.superview == nil && suffix.superview == nil && metadata.superview == nil)
        #expect(header.filename.isHidden)
        #expect(header.frame.height == 84 && view.scrollView.frame.height == 416)
        #expect(custom.frame == header.bounds)
        view.headerRenderers.renderCustomHeader = { _ in nil }
        view.layoutSubtreeIfNeeded()
        #expect(custom.superview == nil && header.frame.height == 0)
        #expect(view.scrollView.frame.height == 500)
        view.headerRenderers.renderCustomHeader = nil
        view.layoutSubtreeIfNeeded()
        #expect(calls == 2 && !header.filename.isHidden)
        #expect(header.frame.height == slotHeight)
        var options = DiffRenderOptions(); options.disableFileHeader = true
        view.render(document, options: options); view.layoutSubtreeIfNeeded()
        #expect(header.isHidden && view.scrollView.frame.height == 500)
    }
    @Test @MainActor func retainedHeaderResizeAndObserverTeardown() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new\n"))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        let custom = NSView(frame: .init(x: 0, y: 0, width: 800, height: 60))
        var calls = 0, invalidations = 0
        view.headerRenderers = .init(renderCustomHeader: { _ in calls += 1; return custom })
        var pinnedOptions = DiffRenderOptions(); pinnedOptions.stickyHeader = true
        view.render(document, options: pinnedOptions)
        view.onLayoutChange = { invalidations += 1 }
        custom.setFrameSize(.init(width: 800, height: 120))
        view.layoutSubtreeIfNeeded()
        #expect(calls == 1 && invalidations == 1)
        #expect(view.preferredHeaderHeight == 120 && view.scrollView.frame.height == 380)
        let prefix = NSView(frame: .init(x: 0, y: 0, width: 30, height: 50))
        view.headerRenderers = .init(renderHeaderPrefix: { _ in prefix })
        view.layoutSubtreeIfNeeded()
        invalidations = 0
        custom.setFrameSize(.init(width: 800, height: 200))
        #expect(invalidations == 0)
        prefix.setFrameSize(.init(width: 30, height: 90))
        view.layoutSubtreeIfNeeded()
        #expect(invalidations == 1 && view.preferredHeaderHeight == 90)
        let intrinsic = MutableHeader(frame: .zero)
        view.headerRenderers = .init(renderCustomHeader: { _ in intrinsic })
        view.layoutSubtreeIfNeeded()
        intrinsic.height = 100; intrinsic.invalidateIntrinsicContentSize()
        view.invalidateHeaderLayout(); view.layoutSubtreeIfNeeded()
        #expect(view.preferredHeaderHeight == 100 && view.scrollView.frame.height == 400)
    }

    @Test @MainActor func retainedReviewHeaderResizePreservesVisibleCode() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let review = NativeCodeView(frame: .init(x: 0, y: 0, width: 800, height: 200))
        var headers: [NSView] = []
        review.headerRenderers = .init(renderCustomHeader: { _ in
            let header = NSView(frame: .init(x: 0, y: 0, width: 800, height: 60))
            headers.append(header); return header
        })
        review.render(Array(repeating: document, count: 100))
        let host = try #require(review.scrollView.documentView)
        review.scrollView.contentView.scroll(to: .init(x: 0, y: 300))
        review.scrollView.reflectScrolledClipView(review.scrollView.contentView)
        review.layoutSubtreeIfNeeded()
        let extent = host.frame.height, top = review.scrollTop, calls = headers.count
        let header = try #require(headers.first)
        header.setFrameSize(.init(width: 800, height: 140))
        review.layoutSubtreeIfNeeded()
        #expect(review.scrollTop == top + 80)
        #expect(host.frame.height == extent + 80)
        #expect(headers.count == calls && review.mountedFileCount < 10)
    }

    @Test @MainActor func typographyUpdatesHeaderAndOffscreenReviewEstimates() async throws {
        let highlighter = DiffHighlighter()
        let changed = try await highlighter.prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new\n"))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500)); window.contentView = view
        var options = DiffRenderOptions(); options.fontSize = 19; options.lineHeight = 30; options.fontName = "Menlo-Regular"
        view.render(changed, options: options)
        let header = try #require(view.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(header.frame.height == 54)
        #expect(header.filename.font?.pointSize == 19)
        let countFont = try #require(header.counts.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(countFont.fontName == "Menlo-Regular" && countFont.pointSize == 19)
        #expect(header.counts.frame.width >= header.counts.attributedStringValue.size().width)
        let prefix = NSView(frame: .init(x: 0, y: 0, width: 24, height: 80))
        view.headerRenderers = .init(renderHeaderPrefix: { _ in prefix }); view.layoutSubtreeIfNeeded()
        #expect(header.frame.height == 80)
        view.headerRenderers = .init(); view.layoutSubtreeIfNeeded()
        options.lineHeight = 24; options.fontSize = 16
        view.render(changed, options: options)
        #expect(header.frame.height == 48 && header.filename.font?.pointSize == 16)

        let review = NativeCodeView(frame: view.frame); window.contentView = review
        review.render(Array(repeating: changed, count: 100), options: options)
        let host = try #require(review.scrollView.documentView)
        let extent = host.frame.height
        review.scrollToFile(at: 90)
        #expect(abs(review.scrollTop - (8 + 90 * (24 + 48 + 8))) < 0.01)
        #expect(host.frame.height == extent)
        #expect(review.mountedFileCount < 10)
        options.lineHeight = 30
        review.render(Array(repeating: changed, count: 100), options: options)
        let updatedExtent = host.frame.height
        review.scrollToFile(at: 50)
        #expect(abs(review.scrollTop - (8 + 50 * (30 + 54 + 8))) < 0.01)
        #expect(host.frame.height == updatedExtent)
    }

    @Test @MainActor func themeAndEditorUpdatesKeepHeaderHooks() async throws {
        let highlighter = DiffHighlighter()
        let document = try await highlighter.prepareThemes(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new\n"))
        let view = NativeThemedDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        var received: [FileDiffMetadata] = []
        view.headerRenderers = .init(renderHeaderMetadata: { diff in
            received.append(diff)
            return NSTextField(labelWithString: "Review \(diff.additions)")
        })
        view.themeAppearance = .dark
        view.render(document)
        let header = try #require(view.diffView.subviews.compactMap { $0 as? DiffHeaderView }.first)
        let first = try #require(header.metadata)
        view.themeAppearance = .light
        #expect(received.count == 2)
        #expect(first.superview == nil && header.metadata != nil)
        #expect(view.diffView.displayedDocument?.id == document.light.id)
        let editor = try view.diffView.beginEditing(highlighter: highlighter)
        await editor.waitForRendering()
        editor.insertText("extra\n", replacementRange: NSRange(location: 0, length: 0))
        await editor.waitForRendering()
        #expect(received.last?.additions == 2)
        #expect((header.metadata as? NSTextField)?.stringValue == "Review 2")
        editor.onEditComplete = { _ in true }
        _ = try await editor.complete(.install)
        #expect(received.last?.additions == view.diffView.displayedDocument?.diff.additions)
        #expect(header.metadata != nil)
    }

    @Test @MainActor func singleFileHeadersPreserveMetadataAndStreamingRevision() async throws {
        let highlighter = DiffHighlighter()
        let source = FileContents(name: "stream.txt", contents: "first\n", lang: "text", header: "File header", cacheKey: "original")
        let first = try await highlighter.prepare(oldFile: source, newFile: source)
        let view = NativeFileView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        var seen: FileContents?
        var snapshots: [String] = []
        view.headerRenderers = .init(renderHeaderMetadata: { file in
            seen = file
            snapshots.append(file.contents)
            return NSTextField(labelWithString: file.header ?? "Streaming")
        })
        view.render(first, file: source)
        let header = try #require(view.diffView.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(seen == source)
        #expect(header.filename.stringValue == source.name && header.counts.stringValue.isEmpty)
        #expect((header.metadata as? NSTextField)?.stringValue == "File header")
        let updated = FileContents(name: "stream.txt", contents: "first\nsecond\n", lang: "text", cacheKey: "next")
        let next = try await highlighter.prepare(oldFile: updated, newFile: updated).identifyingSource(as: first.sourceID)
        view.render(next)
        #expect(seen?.contents == updated.contents && seen?.name == updated.name)
        #expect(seen?.header == nil)
        #expect(snapshots == [source.contents, updated.contents])
        view.stageHeaderRenderers(.init(renderHeaderMetadata: { file in
            snapshots.append(file.contents)
            return NSTextField(labelWithString: "Changed hook")
        }))
        #expect(snapshots.count == 2)
        view.render(next)
        #expect(snapshots == [source.contents, updated.contents, updated.contents])
        #expect((header.metadata as? NSTextField)?.stringValue == "Changed hook")
        #expect(view.diffView.rowCount == 2)
        view.headerRenderers.renderCustomHeader = { _ in nil }
        view.layoutSubtreeIfNeeded()
        #expect(header.customMode && header.frame.height == 0)
    }

    @Test @MainActor func multiFileHeadersMountLazilyAndMeasureHeights() async throws {
        let highlighter = DiffHighlighter()
        var documents: [HighlightedDiff] = []
        for index in 0..<100 {
            documents.append(try await highlighter.prepare(oldFile: .init(name: "f\(index).txt", contents: "old\n"), newFile: .init(name: "f\(index).txt", contents: "new\n")))
        }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        var rendered: [String] = []
        view.headerRenderers = .init(renderCustomHeader: { diff in
            rendered.append(diff.name)
            return NSView(frame: .init(x: 0, y: 0, width: 800, height: 120))
        })
        view.render(documents)
        #expect(rendered.count < 10)
        #expect(view.mountedFileCount <= 4)
        let host = try #require(view.scrollView.documentView)
        let frames = host.subviews.filter { !$0.isHidden }.map(\.frame).sorted { $0.minY < $1.minY }
        #expect(frames.count > 1)
        #expect(frames[0].height == 140)
        #expect(frames[1].minY == 156)
        view.scrollToFile(at: 80)
        #expect(rendered.contains("f80.txt"))
        #expect(!rendered.contains("f40.txt"))
        #expect(view.mountedFileCount <= 4)
        for child in host.subviews.compactMap({ $0 as? NativeDiffView }) {
            #expect(child.preferredHeaderHeight == 120)
        }
        var refreshed: [String] = []
        view.headerRenderers = .init(renderHeaderPrefix: { diff in
            refreshed.append(diff.name)
            return NSTextField(labelWithString: "Review")
        })
        #expect(refreshed.contains("f80.txt"))
        #expect(!refreshed.contains("f99.txt"))
    }

    @Test @MainActor func customHeaderHeightTracksAvailableWidth() async throws {
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: .init(name: "f.txt", contents: "new\n"))
        let view = NativeDiffView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        let content = WidthAwareHeader(frame: .zero)
        view.headerRenderers = .init(renderCustomHeader: { _ in content })
        view.render(document)
        #expect(view.preferredHeaderHeight == 40)
        #expect(content.frame.width == 800)
        view.setFrameSize(.init(width: 300, height: 500)); view.needsLayout = true; view.layoutSubtreeIfNeeded()
        #expect(view.preferredHeaderHeight == 100)
        #expect(view.scrollView.frame.height == 500 && view.scrollView.contentInsets.top == 100)
        view.setFrameSize(.init(width: 800, height: 500)); view.needsLayout = true; view.layoutSubtreeIfNeeded()
        #expect(view.preferredHeaderHeight == 40)
        #expect(view.scrollView.frame.height == 500 && view.scrollView.contentInsets.top == 40)
        let review = NativeCodeView(frame: .init(x: 0, y: 0, width: 800, height: 500))
        review.headerRenderers = .init(renderCustomHeader: { _ in WidthAwareHeader(frame: .zero) })
        review.render(Array(repeating: document, count: 30))
        let host = try #require(review.scrollView.documentView)
        #expect(host.subviews.compactMap { $0 as? NativeDiffView }.allSatisfy { $0.preferredHeaderHeight == 40 })
        review.setFrameSize(.init(width: 300, height: 500)); review.needsLayout = true; review.layoutSubtreeIfNeeded()
        #expect(host.subviews.compactMap { $0 as? NativeDiffView }.allSatisfy { $0.preferredHeaderHeight == 100 })
        review.setFrameSize(.init(width: 800, height: 500)); review.needsLayout = true; review.layoutSubtreeIfNeeded()
        #expect(host.subviews.compactMap { $0 as? NativeDiffView }.allSatisfy { $0.preferredHeaderHeight == 40 })
    }

}

@MainActor private final class WidthAwareHeader: NSView {
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: bounds.width < 400 ? 100 : 40) }
}

@MainActor private final class MutableHeader: NSView {
    var height: CGFloat = 60
    override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: height) }
}
