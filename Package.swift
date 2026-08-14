// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ShikiSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ShikiCore", targets: ["ShikiCore"]),
        .library(name: "Shiki", targets: ["Shiki"]),
        .library(name: "ShikiUI", targets: ["ShikiUI"]),
    ],
    targets: [
        .target(
            name: "COniguruma",
            path: "Sources/COniguruma",
            exclude: [
                "LICENSE.txt",
                "unicode_egcb_data.c",
                "unicode_fold_data.c",
                "unicode_property_data.c",
                "unicode_property_data_posix.c",
                "unicode_wb_data.c",
            ],
            sources: [
                "ShikiOnig.c",
                "ascii.c",
                "big5.c",
                "cp1251.c",
                "euc_jp.c",
                "euc_jp_prop.c",
                "euc_kr.c",
                "euc_tw.c",
                "gb18030.c",
                "iso8859_1.c",
                "iso8859_2.c",
                "iso8859_3.c",
                "iso8859_4.c",
                "iso8859_5.c",
                "iso8859_6.c",
                "iso8859_7.c",
                "iso8859_8.c",
                "iso8859_9.c",
                "iso8859_10.c",
                "iso8859_11.c",
                "iso8859_13.c",
                "iso8859_14.c",
                "iso8859_15.c",
                "iso8859_16.c",
                "koi8_r.c",
                "onig_init.c",
                "regcomp.c",
                "regenc.c",
                "regerror.c",
                "regexec.c",
                "regext.c",
                "reggnu.c",
                "regparse.c",
                "regsyntax.c",
                "regtrav.c",
                "regversion.c",
                "sjis.c",
                "sjis_prop.c",
                "st.c",
                "unicode.c",
                "unicode_fold1_key.c",
                "unicode_fold2_key.c",
                "unicode_fold3_key.c",
                "unicode_unfold_key.c",
                "utf8.c",
                "utf16_be.c",
                "utf16_le.c",
                "utf32_be.c",
                "utf32_le.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
            ]
        ),
        .target(
            name: "ShikiCore",
            dependencies: ["COniguruma"]
        ),
        .target(
            name: "Shiki",
            dependencies: ["ShikiCore"],
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "ShikiUI",
            dependencies: ["ShikiCore"]
        ),
        .testTarget(
            name: "ShikiCoreTests",
            dependencies: ["ShikiCore"],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "ShikiTests",
            dependencies: ["Shiki"]
        ),
        .testTarget(
            name: "ShikiUITests",
            dependencies: ["ShikiUI", "ShikiCore"]
        ),
    ]
)
