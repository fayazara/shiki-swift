#if os(macOS)
import AppKit

/// Owns one native find/replace session. Match computation runs on a snapshot.
@MainActor public final class DiffEditorSearch {
    public var params: EditorSearchParams { didSet { if params != oldValue { replacementRequest += 1; replacementTask?.cancel(); isReplacing = false; refresh() } } }
    public var replacing: Bool { didSet { changed() } }
    public private(set) var matches: [NSRange] = []
    public private(set) var current: NSRange?
    public private(set) var isSearching = false
    public private(set) var isReplacing = false
    public private(set) var error: String?
    public var onUpdate: (() -> Void)?
    var onPresentationUpdate: (() -> Void)?
    var lineMatches: [Int: [NSRange]] = [:]
    private weak var editor: DiffEditor?
    private var task: Task<Void, Never>?
    private var replacementTask: Task<Void, Never>?
    private var request = 0
    private var replacementRequest = 0
    private var active = true
    private var version = -1
    init(editor: DiffEditor, query: String, replacing: Bool) {
        self.editor = editor; params = .init(text: query); self.replacing = replacing
    }
    public var resultLabel: String {
        if let error { return error }
        if isSearching { return "Searching…" }
        guard !matches.isEmpty else { return "No results" }
        if let current, let index = matches.firstIndex(of: current) { return "\(index + 1) of \(matches.count)" }
        return "\(matches.count) results"
    }
    private func changed() { guard active else { return }; onUpdate?(); onPresentationUpdate?(); editor?.searchPresentationChanged() }
    public func refresh(syncSelection: Bool = true) {
        guard active, let editor, editor.isActive else { return }
        request += 1; task?.cancel()
        let request = request, snapshot = editor.document, params = params
        version = snapshot.version; matches = []; lineMatches = [:]; current = nil; error = nil
        isSearching = !params.text.isEmpty; changed()
        guard isSearching else { return }
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
                let worker = Task.detached(priority: .userInitiated) { () throws -> ([NSRange], [Int: [NSRange]]) in
                    let matches = try snapshot.search(params)
                    var lines: [Int: [NSRange]] = [:]
                    for (index, match) in matches.enumerated() {
                        if index % 128 == 0 { try Task.checkCancellation() }
                        let position = snapshot.positionAt(match.location)
                        lines[position.line, default: []].append(.init(location: position.character, length: match.length))
                    }
                    return (matches, lines)
                }
                let (matches, lines) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard let self, self.active, self.request == request, editor.isActive, editor.document.version == snapshot.version else { return }
                self.matches = matches; self.lineMatches = lines; self.isSearching = false
                let selected = editor.selectedRange()
                if syncSelection {
                    self.current = matches.first { $0.location >= (selected.location == NSNotFound ? 0 : selected.location) }
                    if let current = self.current { editor.revealSearchMatch(current) }
                } else { self.current = matches.first { $0 == selected } }
                self.changed()
            } catch is CancellationError { }
            catch {
                guard let self, self.active, self.request == request else { return }
                self.isSearching = false; self.error = "Search could not finish"; self.changed()
            }
        }
    }
    func documentChanged() {
        if let editor, editor.document.version != version { refresh(syncSelection: false) }
    }
    public func next(previous: Bool = false) {
        guard active, let editor, editor.document.version == version, !matches.isEmpty else { return }
        let match: NSRange
        if previous {
            let offset = current?.location ?? 0
            match = matches.last { NSMaxRange($0) <= offset } ?? matches.last!
        } else {
            let offset = current.map(NSMaxRange) ?? 0
            match = matches.first { $0.location >= offset } ?? matches[0]
        }
        current = match; editor.revealSearchMatch(match); changed()
    }
    public func replace(all: Bool = false) {
        guard active, let editor, !isSearching, !isReplacing, !matches.isEmpty else { return }
        if !all && current == nil { next() }
        let selected = current, params = params, version = version
        replacementRequest += 1
        let replacementRequest = replacementRequest
        isReplacing = true; changed()
        replacementTask = Task { [weak self] in
            do {
                if all { _ = try await editor.replaceAll(params) }
                else if let selected { try await editor.replaceSearchMatch(selected, params: params, expectedVersion: version) }
                guard let self, self.active, self.replacementRequest == replacementRequest else { return }
                self.isReplacing = false; self.refresh()
            } catch {
                guard let self, self.active, self.replacementRequest == replacementRequest else { return }
                self.isReplacing = false
                if !(error is CancellationError) { self.error = "Replacement could not finish" }
                self.changed()
            }
        }
    }
    public func close() { guard active else { return }; editor?.closeSearch() }
    func stop() { active = false; request += 1; task?.cancel(); replacementTask?.cancel(); matches = []; lineMatches = [:]; current = nil; isSearching = false; isReplacing = false; onUpdate = nil; onPresentationUpdate = nil }
    public func waitForResults() async { await task?.value }
    public func waitForReplacement() async { await replacementTask?.value }
}

@MainActor final class DiffSearchBar: NSView, NSSearchFieldDelegate {
    let session: DiffEditorSearch
    let query = NSSearchField()
    private let replacement = NSTextField()
    private let status = NSTextField(labelWithString: "No results")
    private let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let modeButton = NSButton(checkboxWithTitle: "Replace", target: nil, action: nil)
    private let previousButton = NSButton(title: "↑", target: nil, action: nil)
    private let nextButton = NSButton(title: "↓", target: nil, action: nil)
    private let closeButton = NSButton(title: "Done", target: nil, action: nil)
    private let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    private let allButton = NSButton(title: "Replace All", target: nil, action: nil)
    private var rows: [NSStackView] = []
    override var isFlipped: Bool { true }
    var preferredHeight: CGFloat { session.replacing ? 116 : 80 }
    init(session: DiffEditorSearch) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        query.placeholderString = "Find"; query.delegate = self; query.setAccessibilityLabel("Find text")
        replacement.placeholderString = "Replace with"; replacement.delegate = self; replacement.setAccessibilityLabel("Replacement text")
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        query.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replacement.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [caseButton, wordButton, regexButton, modeButton] { button.target = self; button.action = #selector(optionsChanged); button.controlSize = .small }
        for (button, action) in [(previousButton, #selector(previous)), (nextButton, #selector(next)), (closeButton, #selector(close)), (replaceButton, #selector(replaceOne)), (allButton, #selector(replaceAll))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded; button.controlSize = .small
        }
        previousButton.setAccessibilityLabel("Previous match"); nextButton.setAccessibilityLabel("Next match")
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rows = [NSStackView(views: [query, status, previousButton, nextButton, closeButton]),
                NSStackView(views: [caseButton, wordButton, regexButton, modeButton, spacer]),
                NSStackView(views: [replacement, replaceButton, allButton])]
        for (index, row) in rows.enumerated() {
            row.orientation = .horizontal; row.distribution = .fill; row.spacing = 8; row.alignment = .centerY
            row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                row.topAnchor.constraint(equalTo: topAnchor, constant: 8 + CGFloat(index) * 36),
                row.heightAnchor.constraint(equalToConstant: 28)
            ])
        }
        status.alignment = .right
        let statusWidth = status.widthAnchor.constraint(equalToConstant: 100); statusWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([statusWidth, query.widthAnchor.constraint(greaterThanOrEqualToConstant: 80), replacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)])
        session.onPresentationUpdate = { [weak self] in self?.update() }
        update()
    }
    required init?(coder: NSCoder) { fatalError("Use init(session:)") }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "g": session.next(previous: event.modifierFlags.contains(.shift)); return true
            case "f": session.replacing = event.modifierFlags.contains(.option); focusQuery(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    func focusQuery() { window?.makeFirstResponder(query); query.selectText(nil) }
    private func update() {
        if query.stringValue != session.params.text { query.stringValue = session.params.text }
        if replacement.stringValue != session.params.replaceText { replacement.stringValue = session.params.replaceText }
        caseButton.state = session.params.caseSensitive ? .on : .off; wordButton.state = session.params.wholeWord ? .on : .off
        regexButton.state = session.params.regex ? .on : .off; modeButton.state = session.replacing ? .on : .off
        rows.last?.isHidden = !session.replacing; status.stringValue = session.resultLabel
        let enabled = !session.matches.isEmpty && !session.isSearching && !session.isReplacing
        for button in [previousButton, nextButton, replaceButton, allButton] { button.isEnabled = enabled }
        needsLayout = true; superview?.needsLayout = true
    }
    func controlTextDidChange(_ notification: Notification) {
        var params = session.params; params.text = query.stringValue; params.replaceText = replacement.stringValue; session.params = params
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch NSStringFromSelector(commandSelector) {
        case "cancelOperation:": close(); return true
        case "insertNewline:":
            if control === replacement { session.replace() }
            else { session.next(previous: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        default: return false
        }
    }
    @objc private func optionsChanged() {
        session.replacing = modeButton.state == .on
        var params = session.params; params.caseSensitive = caseButton.state == .on; params.wholeWord = wordButton.state == .on; params.regex = regexButton.state == .on; session.params = params
    }
    @objc private func previous() { session.next(previous: true) }
    @objc private func next() { session.next() }
    @objc private func close() { session.close() }
    @objc private func replaceOne() { session.replace() }
    @objc private func replaceAll() { session.replace(all: true) }
}

#endif
