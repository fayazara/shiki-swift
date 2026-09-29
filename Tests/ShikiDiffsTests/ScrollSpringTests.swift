import Testing
import AppKit
import QuartzCore
@testable import ShikiDiffs

struct ScrollSpringTests {
    @Test @MainActor func smoothAutoUsesTenViewportsAndHonorsReducedMotion() async throws {
        #expect(prefersReducedMotion() == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 1_000))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.reducedMotionPreference = { false }
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems([.init(id: "file", document: document)], options: options)
        let threshold = view.scrollView.contentSize.height * 10
        view.scrollTo(top: threshold, behavior: .smoothAuto)
        #expect(view.isAnimatingScroll && view.scrollTop == 0)
        view.scrollTo(top: 0)
        view.scrollTo(top: threshold + 1, behavior: .smoothAuto)
        #expect(!view.isAnimatingScroll && view.scrollTop == threshold + 1)
        #expect(view.scrollToLine(900, inFileAt: 0, behavior: .smoothAuto))
        #expect(!view.isAnimatingScroll)
        #expect(view.scrollToLine(899, inFileAt: 0, behavior: .smoothAuto))
        #expect(view.isAnimatingScroll)
        view.reducedMotionPreference = { true }
        view.scrollTo(top: 500, behavior: .smooth)
        #expect(!view.isAnimatingScroll && view.scrollTop == 500)
        #expect(view.scrollToItem("file", behavior: .smoothAuto))
        #expect(!view.isAnimatingScroll && view.scrollTop == view.getTopForItem("file"))
        #expect(view.scrollToLine(10, inFileAt: 0, behavior: .smooth))
        #expect(!view.isAnimatingScroll)
    }
    @Test(arguments: [false, true]) @MainActor
    func activeWrappedTargetSurvivesReflowUnlessUserScrolls(_ interrupt: Bool) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.overflow = .wrap; options.expandUnchanged = true
        try view.setItems((0..<20).map { .init(id: "file\($0)", document: document) }, options: options)
        func waitForLayout() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(!view.isPreparingWrappedLayout)
        }
        try await waitForLayout()
        let range = LineSelection(side: .deletions, startLine: 52, endLine: 50, endSide: .additions)
        #expect(view.scrollToRange(range, inFileAt: 18, align: .end, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 10)
        window.setContentSize(.init(width: 850, height: 400)); view.layoutSubtreeIfNeeded()
        window.setContentSize(.init(width: 1000, height: 450)); view.layoutSubtreeIfNeeded()
        #expect(view.isPreparingWrappedLayout && view.isAnimatingScroll)
        let pendingTop = view.scrollTop
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 1_000)
        #expect(view.scrollTop == pendingTop)
        if interrupt { view.scrollView.contentView.scroll(to: .init(x: 0, y: 100)) }
        try await waitForLayout()
        if interrupt {
            #expect(!view.isAnimatingScroll)
            let stationary = view.scrollTop
            view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
            #expect(view.scrollTop == stationary)
        } else {
            #expect(view.isAnimatingScroll)
            view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
            let animated = view.scrollTop
            #expect(!view.isAnimatingScroll)
            #expect(view.scrollToRange(range, inFileAt: 18, align: .end))
            #expect(abs(view.scrollTop - animated) < 0.01)
        }
        #expect(view.mountedFileCount <= 2)
    }
    @Test @MainActor func unwrappedAnimationSurvivesViewportResizeAndReviewHeaderGrowth() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 500))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        #expect(view.scrollToLine(300, inFileAt: 8, align: .center, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 20)
        #expect(view.isAnimatingScroll)
        let beforeResize = view.scrollTop
        window.setContentSize(.init(width: 800, height: 500)); view.layoutSubtreeIfNeeded()
        #expect(view.isAnimatingScroll)
        #expect(abs(view.scrollTop - beforeResize) < 0.01)
        view.reviewHeader = NSView(frame: .init(x: 0, y: 0, width: 800, height: 100))
        view.layoutSubtreeIfNeeded()
        #expect(view.isAnimatingScroll)
        #expect(abs(view.scrollTop - beforeResize - 100) < 0.01)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        let animated = view.scrollTop
        #expect(!view.isAnimatingScroll)
        #expect(view.scrollToLine(300, inFileAt: 8, align: .center))
        #expect(abs(view.scrollTop - animated) < 0.01)
        #expect(view.scrollToLine(1, inFileAt: 1, behavior: .smooth))
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 100))
        #expect(!view.isAnimatingScroll)
    }
    @Test @MainActor func customReviewHeadersClipAtBothFileBoundaries() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        view.headerRenderers = .init(renderCustomHeader: { _ in NSView(frame: .init(x: 0, y: 0, width: 600, height: 120)) })
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        view.scrollToFile(at: 5)
        let itemTop = try #require(view.getTopForItem("file5"))
        view.scrollTo(top: itemTop + 50)
        let mounted = try #require(view.getRenderedItems().first { $0.id == "file5" }?.instance)
        let header = try #require(mounted.subviews.compactMap { $0 as? DiffHeaderView }.first)
        #expect(header.frame.height == 120)
        #expect(abs(header.frame.intersection(mounted.bounds).height - 70) < 0.01)
        #expect(abs(mounted.scrollView.frame.height - (mounted.bounds.height - 70)) < 0.01)
        #expect(mounted.scrollView.contentView.bounds.minY == 0)
        view.stickyHeaders = true
        #expect(abs(header.frame.intersection(mounted.bounds).height - 120) < 0.01)
        #expect(view.scrollToLine(40, inFileAt: 5))
        #expect(abs(view.scrollTop - (itemTop + 39 * options.lineHeight)) < 0.01)
        // Use the native clip directly so the positioning check does not apply
        // the public absolute-target sticky offset a second time.
        let fileEnd = try #require(view.getTopForItem("file6")) - CodeViewLayout().gap
        view.scrollView.contentView.scroll(to: .init(x: 0, y: fileEnd - 30))
        view.scrollView.reflectScrolledClipView(view.scrollView.contentView)
        #expect(abs(mounted.bounds.height - 30) < 0.01)
        #expect(abs(header.frame.intersection(mounted.bounds).height - 30) < 0.01)
        #expect(header.frame.maxY == mounted.bounds.maxY)
        #expect(mounted.scrollView.frame.height == 0)
        let next = try #require(view.getRenderedItems().first { $0.id == "file6" }?.instance)
        #expect(abs(next.frame.minY - fileEnd - CodeViewLayout().gap) < 0.01)
        #expect(mounted.clipsToBounds)
    }
    @Test @MainActor func absoluteStickyTargetsClampBeforeApplyingHeaderOffset() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        view.stickyHeaders = true
        let header = try #require(view.getRenderedItems().first?.instance.headerHeight(for: 600))
        view.scrollTo(top: 500)
        #expect(abs(view.scrollTop - (500 - header)) < 0.01)
        view.scrollTo(top: 800, behavior: .smooth)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(abs(view.scrollTop - (800 - header)) < 0.01)
        let maximum = view.scrollView.documentView!.bounds.height - view.scrollView.contentSize.height
        view.scrollTo(top: maximum)
        #expect(abs(view.scrollTop - (maximum - header)) < 0.01)
        view.scrollTo(top: maximum + 1)
        #expect(view.scrollTop == maximum)
        view.scrollTo(top: -1)
        #expect(view.scrollTop == 0)
        #expect(view.scrollToItem("file5", behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(view.scrollTop == view.getTopForItem("file5"))
        view.stickyHeaders = false
        view.scrollTo(top: 500)
        #expect(view.scrollTop == 500)
        options.disableFileHeader = true
        try view.setItems([.init(id: "file", document: document)], options: options)
        view.stickyHeaders = true
        view.scrollTo(top: 500)
        #expect(view.scrollTop == 500)
    }
    @Test @MainActor func reviewHeadersScrollAwayOrPinAndCompensateNavigation() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        #expect(!view.stickyHeaders)
        #expect(view.scrollToLine(40, inFileAt: 5))
        let normalTop = view.scrollTop
        let mounted = try #require(view.getRenderedItems().first { $0.id == "file5" }?.instance)
        #expect(abs(mounted.scrollView.frame.height - mounted.bounds.height) < 0.01)
        #expect(abs(mounted.scrollView.contentView.bounds.minY - 39 * options.lineHeight) < 0.01)
        let header = mounted.headerHeight(for: 600)
        view.stickyHeaders = true
        #expect(abs(mounted.bounds.height - mounted.scrollView.frame.height - header) < 0.01)
        #expect(view.scrollToLine(40, inFileAt: 5, align: .nearest))
        #expect(abs(view.scrollTop - (normalTop - header)) < 0.01)
        #expect(abs(mounted.scrollView.contentView.bounds.minY - 39 * options.lineHeight) < 0.01)
        view.scrollTo(top: 0)
        #expect(view.scrollToLine(40, inFileAt: 5, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(abs(view.scrollTop - (normalTop - header)) < 0.01)
        view.stickyHeaders = false
        #expect(view.scrollToLine(40, inFileAt: 5))
        #expect(abs(view.scrollTop - normalTop) < 0.01)
        options.disableFileHeader = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        #expect(view.scrollToLine(40, inFileAt: 5))
        let withoutHeader = view.scrollTop
        view.stickyHeaders = true
        #expect(view.scrollToLine(40, inFileAt: 5))
        #expect(view.scrollTop == withoutHeader)
    }
    @Test(arguments: [DiffStyle.split, .unified]) @MainActor
    func partialPatchHiddenTargetsUseSourceCoordinates(_ style: DiffStyle) async throws {
        let patch = "--- a/f.txt\n+++ b/f.txt\n@@ -10 +10,2 @@\n-old\n+new\n+inserted\n@@ -90 +91 @@\n-last old\n+last new\n"
        let diff = try #require(try parsePatchFiles(patch, throwOnError: true).first?.files.first)
        #expect(diff.isPartial && diff.deletionLines.count == 2 && diff.additionLines.count == 3)
        var options = DiffRenderOptions(); options.diffStyle = style
        let plan = DiffRenderPlan(diff: diff, options: options)
        let gaps = plan.rows.filter { $0.hiddenOldLines != nil }
        #expect(gaps.map(\.hiddenOldLines) == [1...9, 11...89])
        #expect(gaps.map(\.hiddenNewLines) == [1...9, 12...90])
        let document = try await DiffHighlighter().prepare(diff)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 120)); window.contentView = view
        try view.setItems((0..<20).map { .init(id: "file\($0)", document: document) }, options: options)
        view.layoutSubtreeIfNeeded()
        let extent = view.scrollView.documentView!.frame.height
        #expect(view.scrollToLine(1, inFileAt: 10))
        let leading = view.scrollTop
        #expect(view.scrollToLine(9, side: .deletions, inFileAt: 10))
        #expect(view.scrollTop == leading)
        #expect(view.scrollToLine(11, side: .deletions, inFileAt: 10))
        let middle = view.scrollTop
        #expect(middle > leading)
        #expect(view.scrollToRange(.init(side: .additions, startLine: 90, endLine: 89, endSide: .deletions), inFileAt: 10, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(abs(view.scrollTop - middle) < 0.01)
        #expect(!view.scrollToLine(92, inFileAt: 10))
        #expect(!view.scrollToLine(91, side: .deletions, inFileAt: 10))
        #expect(view.scrollView.documentView!.frame.height == extent)
    }
    @Test(arguments: [false, true]) @MainActor
    func singleFileTargetsClampPastEOFAndResolveEmptyFiles(_ wraps: Bool) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 99) + String(repeating: "last ", count: 100))
        let highlighter = DiffHighlighter()
        let document = try await highlighter.prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 200)); window.contentView = view
        var options = DiffRenderOptions(); options.overflow = wraps ? .wrap : .scroll
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document, file: file) }, options: options)
        #expect(view.scrollToLine(Int.max, side: .deletions, inFileAt: 5, align: .end, behavior: .smooth))
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        let clampedPosition = view.scrollTop
        #expect(clampedPosition > 0)
        #expect(view.scrollToLine(100, inFileAt: 5, align: .end))
        #expect(abs(view.scrollTop - clampedPosition) < 0.01)
        #expect(view.scrollToRange(.init(side: .deletions, startLine: Int.max, endLine: 100), inFileAt: 5, align: .end))
        #expect(abs(view.scrollTop - clampedPosition) < 0.01)
        #expect(!view.scrollToLine(0, inFileAt: 5))
        let empty = FileContents(name: "empty.txt", contents: "")
        let emptyDocument = try await highlighter.prepare(oldFile: empty, newFile: empty)
        try view.setItems((0..<30).map { .init(id: "empty\($0)", document: emptyDocument, file: empty) }, options: .init())
        #expect(view.scrollToLine(Int.max, inFileAt: 15))
        let boundary = try #require(view.getTopForItem("empty16")) - CodeViewLayout().gap
        #expect(abs(view.scrollTop - boundary) < 0.01)
    }
    @Test(arguments: CodeViewScrollAlignment.allCases) @MainActor
    func collapsedFilesNavigateToZeroHeightHeaderBoundary(_ alignment: CodeViewScrollAlignment) async throws {
        let file = FileContents(name: "f.txt", contents: "new\n")
        let document = try await DiffHighlighter().prepare(oldFile: .init(name: "f.txt", contents: "old\n"), newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 120)); window.contentView = view
        var options = DiffRenderOptions(); options.collapsed = true
        try view.setItems((0..<30).map { .init(id: "file\($0)", document: document) }, options: options)
        view.layoutSubtreeIfNeeded()
        let extent = view.scrollView.documentView!.frame.height
        #expect(view.scrollToLine(1, inFileAt: 15, align: alignment, offset: 8))
        let expected = view.scrollTop
        #expect(expected > 0)
        let boundary = try #require(view.getTopForItem("file16")) - CodeViewLayout().gap
        let viewportHeight = view.scrollView.contentSize.height
        let alignedBoundary: CGFloat
        switch alignment {
        case .start: alignedBoundary = boundary - 8
        case .center: alignedBoundary = boundary - viewportHeight / 2 + 8
        case .end, .nearest: alignedBoundary = boundary - viewportHeight + 8
        }
        #expect(abs(expected - alignedBoundary) < 0.01)
        view.scrollTo(top: 0)
        #expect(view.scrollToRange(.init(side: .deletions, startLine: 10_000, endLine: 1, endSide: .additions), inFileAt: 15, align: alignment, offset: 8, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(abs(view.scrollTop - expected) < 0.01)
        #expect(!view.scrollToLine(0, inFileAt: 15))
        #expect(view.scrollView.documentView!.frame.height == extent)
        let unchanged = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        try view.setItems([.init(id: "diff", document: unchanged), .init(id: "file", document: unchanged, file: file)], options: options)
        #expect(!view.scrollToLine(1, inFileAt: 0))
        #expect(view.scrollToLine(10_000, inFileAt: 1))
    }
    @Test @MainActor func hiddenContextNavigationTargetsSeparatorWithoutExpanding() async throws {
        let oldLines = (1...1_000).map { "line \($0)\n" }
        var newLines = oldLines; newLines[499] = "changed\n"
        let document = try await DiffHighlighter().prepare(
            oldFile: .init(name: "f.txt", contents: oldLines.joined()),
            newFile: .init(name: "f.txt", contents: newLines.joined()))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 120)); window.contentView = view
        let options = DiffRenderOptions()
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        view.layoutSubtreeIfNeeded()
        let extent = view.scrollView.documentView!.frame.height
        #expect(view.scrollToLine(10, inFileAt: 5))
        let leading = view.scrollTop
        #expect(view.scrollToLine(400, side: .deletions, inFileAt: 5))
        #expect(view.scrollTop == leading)
        #expect(view.scrollToLine(900, inFileAt: 5))
        let trailing = view.scrollTop
        #expect(trailing > leading)
        #expect(view.scrollToLine(999, side: .deletions, inFileAt: 5, behavior: .smooth))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(abs(view.scrollTop - trailing) < 0.01)
        #expect(view.scrollToRange(.init(side: .additions, startLine: 900, endLine: 10), inFileAt: 5))
        #expect(abs(view.scrollTop - leading) < 0.01)
        #expect(!view.scrollToLine(1_001, inFileAt: 5))
        #expect(view.scrollView.documentView!.frame.height == extent)
        let plan = DiffRenderPlan(diff: document.diff, options: options, expandedRegions: [0: .init(fromStart: 20, fromEnd: 20)])
        let separator = try #require(plan.rows.first { $0.hiddenNewLines != nil })
        #expect(separator.hiddenNewLines?.contains(10) == false)
        #expect(separator.hiddenNewLines?.contains(400) == true)
    }
    @Test @MainActor func deferredWrappedRangeKeepsSmoothBehaviorAndLatestTarget() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: String(repeating: "word ", count: 30) + "\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.overflow = .wrap; options.expandUnchanged = true
        try view.setItems((0..<20).map { .init(id: "file\($0)", document: document) }, options: options)
        #expect(view.isPreparingWrappedLayout)
        #expect(view.scrollToLine(10, inFileAt: 5, behavior: .smooth))
        let range = LineSelection(side: .deletions, startLine: 52, endLine: 50, endSide: .additions)
        #expect(view.scrollToRange(range, inItem: "file18", align: .end, behavior: .smooth))
        #expect(!view.isAnimatingScroll)
        window.setContentSize(.init(width: 900, height: 300)); view.layoutSubtreeIfNeeded()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.isPreparingWrappedLayout && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!view.isPreparingWrappedLayout && view.isAnimatingScroll)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(!view.isAnimatingScroll)
        let animatedPosition = view.scrollTop
        #expect(view.scrollToRange(range, inItem: "file18", align: .end))
        #expect(abs(view.scrollTop - animatedPosition) < 0.01)
        #expect(view.mountedFileCount <= 2)
    }
    @Test(arguments: CodeViewScrollAlignment.allCases) @MainActor
    func animatedRangeMatchesInstantAlignment(_ alignment: CodeViewScrollAlignment) async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 1_000))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems([.init(id: "file", document: document)], options: options)
        view.layoutSubtreeIfNeeded()
        let range = LineSelection(side: .additions, startLine: 510, endLine: 500)
        #expect(view.scrollToRange(range, inItem: "file", align: alignment, offset: 12))
        let expected = view.scrollTop
        view.scrollTo(top: 0)
        #expect(view.scrollToRange(range, inItem: "file", align: alignment, offset: 12, behavior: .smooth))
        #expect(view.isAnimatingScroll && view.scrollTop == 0)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(!view.isAnimatingScroll && abs(view.scrollTop - expected) < 0.01)
    }
    @Test @MainActor func animatedItemTargetSurvivesRenameAndCancelsRemoval() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 100))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        try view.setItems((0..<10).map { .init(id: "file\($0)", document: document) }, options: options)
        view.layoutSubtreeIfNeeded()
        #expect(view.scrollToItem("file8", behavior: .smooth))
        #expect(view.isAnimatingScroll)
        #expect(view.updateItemID("file8", to: "renamed"))
        let target = try #require(view.getTopForItem("renamed"))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(!view.isAnimatingScroll && abs(view.scrollTop - target) < 0.01)
        #expect(view.scrollToItem("file2", behavior: .smooth))
        #expect(try view.removeItem("file2"))
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 10_000)
        #expect(!view.isAnimatingScroll)
        #expect(!view.scrollToItem("missing", behavior: .smooth))
    }
    @Test @MainActor func nativeDriverSettlesAndCancelsExternalScrolling() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 1_000))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300))
        window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        view.render([document], options: options); view.layoutSubtreeIfNeeded()
        view.scrollTo(top: 5_000, behavior: .smooth)
        #expect(view.isAnimatingScroll)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(!view.isAnimatingScroll && abs(view.scrollTop - 5_000) < 0.01)
        view.scrollTo(top: 10_000, behavior: .smooth)
        view.scrollView.contentView.scroll(to: .init(x: 0, y: 100))
        #expect(!view.isAnimatingScroll)
        view.scrollTo(top: 2_000, behavior: .smooth)
        let accepted = view.scrollToLine(5, inFileAt: 0, align: .nearest)
        #expect(accepted && !view.isAnimatingScroll)
        let stationary = view.scrollTop
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 10_000)
        #expect(view.scrollTop == stationary)
        view.scrollTo(top: 2_000, behavior: .smooth)
        let invalid = view.scrollToLine(5, inFileAt: 99)
        #expect(!invalid && view.isAnimatingScroll)
        view.scrollToFile(at: 0)
        #expect(!view.isAnimatingScroll)
        for invalidSettings in [SmoothScrollSettings(omega: 0), .init(omega: -1), .init(omega: .nan), .init(positionEpsilon: -1), .init(velocityEpsilon: .infinity)] {
            view.smoothScrollSettings = .init()
            view.scrollTo(top: 2_000, behavior: .smooth)
            #expect(view.isAnimatingScroll)
            let beforeInvalidation = view.scrollTop
            view.smoothScrollSettings = invalidSettings
            #expect(!view.isAnimatingScroll && view.scrollTop == beforeInvalidation)
            view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 20_000)
            #expect(view.scrollTop.isFinite && view.scrollTop == beforeInvalidation)
        }
        view.smoothScrollSettings = .init()
        view.scrollTo(top: 2_000, behavior: .smooth)
        view.reset()
        #expect(!view.isAnimatingScroll && view.scrollTop == 0)
    }
    @Test @MainActor func frameCompletionDoesNotCancelReentrantRetarget() async throws {
        let file = FileContents(name: "f.txt", contents: String(repeating: "line\n", count: 1_000))
        let document = try await DiffHighlighter().prepare(oldFile: file, newFile: file)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let view = NativeCodeView(frame: .init(x: 0, y: 0, width: 600, height: 300)); window.contentView = view
        var options = DiffRenderOptions(); options.expandUnchanged = true
        view.render([document], options: options); view.layoutSubtreeIfNeeded()
        var retargeted = false
        let unsubscribe = view.subscribeToScroll { _, view in
            if !retargeted { retargeted = true; view.scrollTo(top: 8_000, behavior: .smooth) }
        }
        defer { unsubscribe() }
        view.scrollTo(top: 4_000, behavior: .smooth)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 5_000)
        #expect(retargeted && view.isAnimatingScroll)
        view.advanceSmoothScroll(timestamp: CACurrentMediaTime() * 1000 + 10_000)
        #expect(!view.isAnimatingScroll && abs(view.scrollTop - 8_000) < 0.01)
    }
    @Test func irregularFramesAgreeWithSingleAnalyticStep() {
        let settings = SmoothScrollSettings(positionEpsilon: 0, velocityEpsilon: 0)
        var one = ScrollSpring(position: 20, velocity: 0.2, lastTimestamp: 0)
        var many = one
        _ = one.advance(to: 4_000, timestamp: 400, settings: settings)
        for timestamp: Double in [1, 8, 16, 120, 121, 380, 400] {
            _ = many.advance(to: 4_000, timestamp: timestamp, settings: settings)
        }
        #expect(abs(one.position - many.position) < 0.000001)
        #expect(abs(one.velocity - many.velocity) < 0.000001)
    }
    @Test func longFrameGapSettlesAndRetargetingPreservesMotion() {
        var spring = ScrollSpring(position: 0, lastTimestamp: 0)
        let firstSettled = spring.advance(to: 10_000, timestamp: 16)
        #expect(!firstSettled)
        let before = spring.position
        let retargetSettled = spring.advance(to: 20_000, timestamp: 32)
        #expect(!retargetSettled)
        #expect(spring.position > before && spring.position < 20_000)
        let finalSettled = spring.advance(to: 20_000, timestamp: 60_000)
        #expect(finalSettled)
        #expect(spring.position == 20_000 && spring.velocity == 0)
    }
    @Test func anchorCorrectionAndEarlierTimestampDoNotIntegrateNegativeTime() {
        var spring = ScrollSpring(position: 100, velocity: 1, lastTimestamp: 50)
        let settled = spring.advance(to: 1_000, timestamp: 40, anchorDelta: 25)
        #expect(!settled)
        #expect(spring.position == 125 && spring.velocity == 1)
    }
}
