import Shiki
import ShikiDiffs
import SwiftUI

enum DemoScreen: String, CaseIterable, Identifiable, Hashable {
    case playground, languages, themes
    case lightDark, annotations, docs, terminal
    case streaming, inspector, largeFiles, largeDiff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playground: "Playground"
        case .languages: "Languages"
        case .themes: "Themes"
        case .lightDark: "Light & Dark"
        case .annotations: "Diffs & Focus"
        case .docs: "Docs & Markdown"
        case .terminal: "Terminal (ANSI)"
        case .streaming: "Streaming Chat"
        case .inspector: "Token Inspector"
        case .largeFiles: "Large Files"
        case .largeDiff: "Large File Diff"
        }
    }

    var symbol: String {
        switch self {
        case .playground: "pencil.and.scribble"
        case .languages: "square.grid.2x2"
        case .themes: "paintpalette"
        case .lightDark: "circle.lefthalf.filled"
        case .annotations: "plusminus"
        case .docs: "doc.richtext"
        case .terminal: "terminal"
        case .streaming: "bubble.left.and.text.bubble.right"
        case .inspector: "scope"
        case .largeFiles: "gauge.with.dots.needle.67percent"
        case .largeDiff: "arrow.left.arrow.right"
        }
    }

    static let sections: [(String, [DemoScreen])] = [
        ("Basics", [.playground, .languages, .themes]),
        ("Rendering", [.lightDark, .annotations, .docs, .terminal]),
        ("Advanced", [.streaming, .inspector, .largeFiles, .largeDiff]),
    ]
}

/// A sidebar entry: a Shiki demo screen or a ShikiDiffs example.
enum SidebarItem: Hashable, RawRepresentable {
    case screen(DemoScreen)
    case diff(DemoSample)

    // Stored in SceneStorage; plain screen names keep earlier saved values valid.
    init?(rawValue: String) {
        if rawValue.hasPrefix("diff:") {
            guard let sample = DemoSample(rawValue: String(rawValue.dropFirst(5))) else { return nil }
            self = .diff(sample)
        } else {
            guard let screen = DemoScreen(rawValue: rawValue) else { return nil }
            self = .screen(screen)
        }
    }

    var rawValue: String {
        switch self {
        case let .screen(screen): screen.rawValue
        case let .diff(sample): "diff:" + sample.rawValue
        }
    }

    var title: String {
        switch self {
        case let .screen(screen): screen.title
        case let .diff(sample): sample.title
        }
    }
}

struct ContentView: View {
    @Environment(AppTheme.self) private var appTheme
    @SceneStorage("screen") private var screen: SidebarItem = .screen(.playground)

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<SidebarItem?>(get: { screen }, set: { if let s = $0 { screen = s } })) {
                ForEach(DemoScreen.sections, id: \.0) { section in
                    Section(section.0) {
                        ForEach(section.1) { item in
                            Label(item.title, systemImage: item.symbol).tag(SidebarItem.screen(item))
                        }
                    }
                }
                Section("Diffs") {
                    ForEach(DemoSample.allCases) { sample in
                        Label(sample.title, systemImage: sample.icon).tag(SidebarItem.diff(sample))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            detail
                .id(screen)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) { ThemeSwitcher() }
                }
                .navigationTitle(screen.title)
        }
        .tint(appTheme.palette.accent)
        // Keep minimums small: on scaled displays the whole screen can be
        // ~650pt tall, and a larger minimum makes the content overflow the
        // window (clipping the top and bottom of every column).
        .frame(minWidth: 720, minHeight: 420)
    }

    @ViewBuilder
    private var detail: some View {
        switch screen {
        case let .diff(sample): DiffsWorkbench(sample: sample)
        case let .screen(screen): screenView(screen)
        }
    }

    @ViewBuilder
    private func screenView(_ screen: DemoScreen) -> some View {
        switch screen {
        case .playground: PlaygroundDemo()
        case .languages: LanguageGalleryDemo()
        case .themes: ThemeGalleryDemo()
        case .lightDark: LightDarkDemo()
        case .annotations: AnnotationsDemo()
        case .docs: DocsDemo()
        case .terminal: TerminalDemo()
        case .streaming: StreamingDemo()
        case .inspector: InspectorDemo()
        case .largeFiles: LargeFileDemo()
        case .largeDiff: LargeDiffDemo()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ThemeSwatch(themeID: appTheme.themeID, size: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(appTheme.info?.displayName ?? appTheme.themeID).font(.caption.weight(.medium))
                Text("\(DemoLanguages.all.count) languages · \(AppTheme.all.count) themes")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}

#Preview {
    ContentView().environment(AppTheme())
}
