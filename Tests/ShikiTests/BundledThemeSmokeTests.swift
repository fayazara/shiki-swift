import Shiki
import XCTest

final class BundledThemeSmokeTests: XCTestCase {
    func testEveryBundledNormalizedThemeCompilesWithUsableDefaults() throws {
        let assets = BundledShikiAssets.shared
        XCTAssertEqual(assets.themes.count, 65)
        XCTAssertEqual(Set(assets.themes.map(\.id)).count, 65)

        var failures: [String] = []
        for info in assets.themes {
            do {
                let theme = try assets.loadTheme(named: info.id)
                guard theme.name == info.id else {
                    failures.append(
                        "\(info.id): normalized name was \(String(reflecting: theme.name))"
                    )
                    continue
                }
                guard theme.type == info.type else {
                    failures.append(
                        "\(info.id): normalized type was \(theme.type), expected \(info.type)"
                    )
                    continue
                }
                guard !theme.foreground.isEmpty, !theme.background.isEmpty else {
                    failures.append(
                        "\(info.id): empty default fg/bg "
                            + "\(String(reflecting: theme.foreground))/"
                            + "\(String(reflecting: theme.background))"
                    )
                    continue
                }

                let compiled = try theme.compile()
                let defaults = compiled.getDefaults()
                let colorMap = compiled.getColorMap()
                guard defaults.foregroundID > 0,
                      colorMap.indices.contains(defaults.foregroundID),
                      let foreground = colorMap[defaults.foregroundID]
                else {
                    failures.append(
                        "\(info.id): unusable foreground ID \(defaults.foregroundID) "
                            + "for color map count \(colorMap.count)"
                    )
                    continue
                }
                guard defaults.backgroundID > 0,
                      colorMap.indices.contains(defaults.backgroundID),
                      let background = colorMap[defaults.backgroundID]
                else {
                    failures.append(
                        "\(info.id): unusable background ID \(defaults.backgroundID) "
                            + "for color map count \(colorMap.count)"
                    )
                    continue
                }
                guard !foreground.isEmpty, !background.isEmpty else {
                    failures.append(
                        "\(info.id): compiled defaults resolved to empty colors"
                    )
                    continue
                }
                guard !colorMap.isEmpty,
                      colorMap[0] == nil,
                      colorMap.dropFirst().contains(where: { $0 != nil })
                else {
                    failures.append("\(info.id): compiled color map was not usable")
                    continue
                }
            } catch {
                failures.append("\(info.id): threw \(String(describing: error))")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Bundled theme smoke failures:\n" + failures.joined(separator: "\n")
        )
    }
}
