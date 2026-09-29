#if os(macOS)
import AppKit

public struct EditorFileInfo: Equatable, Sendable {
    public var name: String
    public var lang: String?
    public init(name: String, lang: String? = nil) { self.name = name; self.lang = lang }
}

public enum EditorType: Sendable, Hashable { case file, fileDiff }
public enum EditStateError: Error { case keyAlreadyActive(String), invalidCapacity, incompatibleEditorType }

/// A value snapshot of the draft, including its piece-table undo/redo history.
public struct EditState: Sendable {
    public var type: EditorType
    public var document: TextDocument
    public var fileInfo: EditorFileInfo?
    public var selection: EditorSelection?
    public var scrollOrigin: CGPoint?
    public var annotations: [LineAnnotation]
    public var expandedHunks: [Int: HunkExpansionRegion]
    public var secondarySelections: [EditorSelection] = []
    public var selections: [EditorSelection] { secondarySelections + (selection.map { [$0] } ?? []) }
    public var diffSession: FileDiffMetadata?
    struct HistoryGroup: Sendable { var count: Int; var before: [EditorSelection]; var after: [EditorSelection]; var remapBefore = false; var remapAfter = false }
    var historyIdentity: TextDocument.HistoryIdentity?
    var undoGroups: [HistoryGroup]?
    var redoGroups: [HistoryGroup]?
    var annotationUndo: [DiffEditor.AnnotationHistory]?
    var annotationRedo: [DiffEditor.AnnotationHistory]?
    var maximumUndoGroups: Int?
    var canCoalesceUndo = false
    var initialDocument: HighlightedDiff?
    public init(type: EditorType, document: TextDocument, fileInfo: EditorFileInfo? = nil, selections: [EditorSelection] = [], scrollOrigin: CGPoint? = nil,
                annotations: [LineAnnotation] = [], expandedHunks: [Int: HunkExpansionRegion] = [:], diffSession: FileDiffMetadata? = nil) {
        self.type = type; self.document = document; self.fileInfo = fileInfo; selection = selections.last; secondarySelections = Array(selections.dropLast())
        self.scrollOrigin = scrollOrigin; self.annotations = annotations; self.expandedHunks = expandedHunks; self.diffSession = diffSession
    }

}

/// Optional fields are initialized from the attached component. Swift value
/// ownership keeps imported state independent of the original editor.
public struct EditorInitialState: Sendable {
    public var type: EditorType
    public var document: TextDocument?
    public var fileInfo: EditorFileInfo?
    public var editor: EditorViewState?
    public var annotations: [LineAnnotation]?
    public var diffSession: FileDiffMetadata?
    public var expandedHunks: [Int: HunkExpansionRegion]?
    var snapshot: EditState?
    public init(type: EditorType, document: TextDocument? = nil, fileInfo: EditorFileInfo? = nil, editor: EditorViewState? = nil,
                annotations: [LineAnnotation]? = nil, diffSession: FileDiffMetadata? = nil,
                expandedHunks: [Int: HunkExpansionRegion]? = nil) {
        self.type = type; self.document = document; self.fileInfo = fileInfo; self.editor = editor; self.annotations = annotations
        self.diffSession = diffSession; self.expandedHunks = expandedHunks
    }
    public init(_ state: EditState) {
        type = state.type; document = state.document; fileInfo = state.fileInfo; annotations = state.annotations; diffSession = state.diffSession
        expandedHunks = state.expandedHunks; snapshot = state
        editor = .init(selections: state.selections, view: state.scrollOrigin.map { .init(scrollLeft: $0.x, scrollTop: $0.y) })
    }
}

public struct ClearEditStateOptions: Sendable {
    public var document: Bool
    public var history: Bool
    public var editor: Bool
    public var selections: Bool
    public var view: Bool
    public init(document: Bool = false, history: Bool = false, editor: Bool = false,
                selections: Bool = false, view: Bool = false) {
        self.document = document; self.history = history; self.editor = editor
        self.selections = selections; self.view = view
    }
}

/// In-memory edit retention, with independent file/diff namespaces. Active keys
/// are exclusive; dormant sessions use the upstream default capacity of 100
/// per namespace. No viewport, callback, or active editor is retained here.
@MainActor public final class EditStateManager {
    public static let shared = EditStateManager()
    private struct Key: Hashable { var type: EditorType; var name: [UInt16] }
    private final class Owner {
        weak var editor: DiffEditor?
        init(_ editor: DiffEditor) { self.editor = editor }
    }
    private struct Entry { var state: DiffEditor.RetainedState; var sequence: UInt64 }
    private var active: [Key: Owner] = [:]
    private var dormant: [Key: Entry] = [:]
    private var sequence: UInt64 = 0
    public private(set) var capacity = 100
    public init() {}

    func activate(_ type: EditorType, key: String, editor: DiffEditor) throws -> DiffEditor.RetainedState? {
        let key = Key(type: type, name: Array(key.utf16))
        if let owner = active[key]?.editor, owner !== editor { throw EditStateError.keyAlreadyActive(String(decoding: key.name, as: UTF16.self)) }
        active[key] = Owner(editor)
        return dormant.removeValue(forKey: key)?.state
    }
    func release(_ type: EditorType, key: String, editor: DiffEditor, state: DiffEditor.RetainedState) {
        let key = Key(type: type, name: Array(key.utf16))
        guard active[key]?.editor === editor else { return }
        active.removeValue(forKey: key)
        sequence &+= 1
        dormant[key] = Entry(state: state, sequence: sequence)
        trim(type)
    }
    public func get(_ type: EditorType, editStateKey: String) -> EditState? {
        let key = Key(type: type, name: Array(editStateKey.utf16))
        return active[key]?.editor?.getEditState() ?? dormant[key]?.state.value
    }
    @discardableResult public func clear(_ type: EditorType, editStateKey: String, parts: ClearEditStateOptions? = nil) -> Bool {
        let key = Key(type: type, name: Array(editStateKey.utf16))
        guard active[key]?.editor == nil, var entry = dormant[key] else { return false }
        if let parts, !parts.document {
            entry.state.clear(parts); dormant[key] = entry
        } else { dormant.removeValue(forKey: key) }
        return true
    }
    public func clearAll() { dormant.removeAll() }
    public func setCapacity(_ capacity: Int) throws {
        guard capacity > 0 else { throw EditStateError.invalidCapacity }
        self.capacity = capacity; trim(.file); trim(.fileDiff)
    }
    private func trim(_ type: EditorType) {
        let entries = dormant.filter { $0.key.type == type }.sorted { $0.value.sequence < $1.value.sequence }
        for entry in entries.prefix(max(0, entries.count - capacity)) { dormant.removeValue(forKey: entry.key) }
    }
}

#endif
