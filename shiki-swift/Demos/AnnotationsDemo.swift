import SwiftUI

/// Shiki transformer notation: comments in the source become line decorations.
struct AnnotationsDemo: View {
    @Environment(AppTheme.self) private var appTheme
    @State private var showSource = true

    var body: some View {
        let palette = appTheme.palette
        DemoPage(title: "Diffs & Focus",
                 subtitle: "Write Shiki's transformer notation in code comments — the comments are stripped before highlighting and turned into diff, highlight, focus, error, and warning decorations. Great for docs, blog posts, and code review UIs.") {
            Toggle("Show source next to the result", isOn: $showSource).toggleStyle(.switch)
            FlowLayout {
                ForEach(legend, id: \.0) { item in
                    Text(item.0)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(palette.panel, in: Capsule())
                        .overlay(Capsule().stroke(palette.border))
                        .help(item.1)
                }
            }

            ForEach(DemoSamples.annotated) { sample in
                VStack(alignment: .leading, spacing: 8) {
                    Text(sample.title).font(.headline)
                    let rendered = CodeBlock(code: sample.code, language: sample.language, title: "Rendered",
                                             parsesAnnotations: true)
                    let source = CodeBlock(code: sample.code, language: sample.language, title: "Source")
                    if showSource {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                source.frame(minWidth: 380)
                                rendered.frame(minWidth: 380)
                            }
                            VStack(spacing: 12) { source; rendered }
                        }
                    } else {
                        rendered
                    }
                }
            }
            Text("Tip: focused blocks un-blur when you hover them.")
                .font(.callout).foregroundStyle(palette.secondaryText)
        }
    }

    private let legend = [
        ("[!code ++]", "Added line"),
        ("[!code --]", "Removed line"),
        ("[!code highlight]", "Highlighted line"),
        ("[!code focus:N]", "Focus N lines, blur the rest"),
        ("[!code error]", "Error line"),
        ("[!code warning]", "Warning line"),
    ]
}
