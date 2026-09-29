import Foundation

struct CodeSample: Identifiable, Hashable {
    let language: String
    let title: String
    let code: String
    var id: String { language + ":" + title }
}

enum DemoSamples {
    static let gallery: [CodeSample] = [
        CodeSample(language: "swift", title: "Greeting.swift", code: #"""
        import SwiftUI

        struct Greeting: View {
            @State private var count = 0
            let name: String

            var body: some View {
                Button("Hello, \(name)! (\(count))") { count += 1 }
                    .buttonStyle(.borderedProminent)
            }
        }
        """#),
        CodeSample(language: "typescript", title: "user.ts", code: #"""
        type User = { id: number; name: string; roles?: Role[] }
        enum Role { Admin = "admin", Viewer = "viewer" }

        export async function fetchUser(id: number): Promise<User> {
          const res = await fetch(`/api/users/${id}`)
          if (!res.ok) throw new Error(`HTTP ${res.status}`)
          return (await res.json()) as User
        }
        """#),
        CodeSample(language: "tsx", title: "Counter.tsx", code: #"""
        import { useState } from "react"

        export function Counter({ start = 0 }: { start?: number }) {
          const [count, setCount] = useState(start)
          return (
            <button className="btn" onClick={() => setCount(c => c + 1)}>
              Clicked {count} times
            </button>
          )
        }
        """#),
        CodeSample(language: "python", title: "stats.py", code: #"""
        from dataclasses import dataclass, field
        from statistics import mean

        @dataclass
        class Series:
            name: str
            values: list[float] = field(default_factory=list)

            def summary(self) -> str:
                return f"{self.name}: n={len(self.values)} mean={mean(self.values):.2f}"
        """#),
        CodeSample(language: "rust", title: "main.rs", code: #"""
        use std::collections::HashMap;

        #[derive(Debug, Clone)]
        struct Word<'a> { text: &'a str, count: usize }

        fn main() {
            let mut freq: HashMap<&str, usize> = HashMap::new();
            for w in "the quick brown the lazy the".split_whitespace() {
                *freq.entry(w).or_insert(0) += 1;
            }
            println!("{:?}", freq);
        }
        """#),
        CodeSample(language: "go", title: "server.go", code: #"""
        package main

        import (
            "fmt"
            "net/http"
        )

        func main() {
            http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
                fmt.Fprintf(w, "Hello, %s!\n", r.URL.Query().Get("name"))
            })
            http.ListenAndServe(":8080", nil)
        }
        """#),
        CodeSample(language: "kotlin", title: "Shapes.kt", code: #"""
        sealed interface Shape {
            data class Circle(val r: Double) : Shape
            data class Rect(val w: Double, val h: Double) : Shape
        }

        fun Shape.area(): Double = when (this) {
            is Shape.Circle -> Math.PI * r * r
            is Shape.Rect -> w * h
        }
        """#),
        CodeSample(language: "java", title: "Main.java", code: #"""
        import java.util.List;

        public final class Main {
            record Point(int x, int y) {}

            public static void main(String[] args) {
                var points = List.of(new Point(1, 2), new Point(3, 4));
                points.stream().map(Point::x).forEach(System.out::println);
            }
        }
        """#),
        CodeSample(language: "cpp", title: "vector.cpp", code: #"""
        #include <algorithm>
        #include <iostream>
        #include <vector>

        template <typename T>
        T sum(const std::vector<T>& v) { return std::accumulate(v.begin(), v.end(), T{}); }

        int main() {
            std::vector<int> v{5, 3, 8, 1};
            std::ranges::sort(v);
            std::cout << "sum = " << sum(v) << '\n';
        }
        """#),
        CodeSample(language: "csharp", title: "Program.cs", code: #"""
        using System.Linq;

        var orders = new[] { new Order("A", 12.5m), new Order("B", 7m) };
        var total = orders.Where(o => o.Amount > 5).Sum(o => o.Amount);
        Console.WriteLine($"Total: {total:C}");

        public record Order(string Id, decimal Amount);
        """#),
        CodeSample(language: "ruby", title: "greeter.rb", code: #"""
        class Greeter
          attr_reader :name

          def initialize(name) = @name = name

          def greet(times: 1)
            times.times.map { |i| "Hello #{name} ##{i + 1}" }.join("\n")
          end
        end

        puts Greeter.new("Shiki").greet(times: 2)
        """#),
        CodeSample(language: "php", title: "index.php", code: #"""
        <?php
        declare(strict_types=1);

        final class Cart {
            /** @var array<string, int> */
            private array $items = [];

            public function add(string $sku, int $qty = 1): static {
                $this->items[$sku] = ($this->items[$sku] ?? 0) + $qty;
                return $this;
            }
        }
        """#),
        CodeSample(language: "html", title: "index.html", code: #"""
        <!doctype html>
        <html lang="en">
          <head>
            <style> body { font: 16px/1.5 system-ui; } </style>
          </head>
          <body>
            <h1 class="title">Hello 👋</h1>
            <script type="module">document.title = "Shiki"</script>
          </body>
        </html>
        """#),
        CodeSample(language: "css", title: "card.css", code: #"""
        @layer components {
          .card {
            --radius: 12px;
            border-radius: var(--radius);
            background: color-mix(in oklab, canvas 90%, currentColor);
            transition: transform 150ms ease-out;
          }
          .card:hover { transform: translateY(-2px); }
        }
        """#),
        CodeSample(language: "scss", title: "_buttons.scss", code: #"""
        $brand: #6d28d9;

        @mixin button($bg: $brand) {
          background: $bg;
          &:hover { background: darken($bg, 8%); }
        }

        .btn { @include button; padding: .5rem 1rem; }
        """#),
        CodeSample(language: "json", title: "package.json", code: #"""
        {
          "name": "shiki-swift",
          "version": "1.0.0",
          "private": true,
          "scripts": { "build": "swift build -c release" },
          "keywords": ["syntax", "highlighting", null],
          "stars": 4200
        }
        """#),
        CodeSample(language: "yaml", title: "ci.yml", code: #"""
        name: CI
        on: [push, pull_request]
        jobs:
          test:
            runs-on: macos-15
            steps:
              - uses: actions/checkout@v4
              - run: swift test --parallel  # fast!
        """#),
        CodeSample(language: "toml", title: "Cargo.toml", code: #"""
        [package]
        name = "demo"
        version = "0.1.0"
        edition = "2021"

        [dependencies]
        serde = { version = "1", features = ["derive"] }
        """#),
        CodeSample(language: "sql", title: "report.sql", code: #"""
        WITH monthly AS (
          SELECT date_trunc('month', created_at) AS month, SUM(total) AS revenue
          FROM orders
          WHERE status = 'paid'
          GROUP BY 1
        )
        SELECT month, revenue, revenue - LAG(revenue) OVER (ORDER BY month) AS delta
        FROM monthly ORDER BY month DESC LIMIT 12;
        """#),
        CodeSample(language: "shellscript", title: "deploy.sh", code: #"""
        #!/usr/bin/env bash
        set -euo pipefail

        VERSION="${1:-$(git describe --tags)}"
        for host in web{1..3}.example.com; do
          echo "Deploying $VERSION to $host"
          ssh "$host" "sudo systemctl restart app@${VERSION}" || exit 1
        done
        """#),
        CodeSample(language: "docker", title: "Dockerfile", code: #"""
        FROM swift:6.1 AS build
        WORKDIR /src
        COPY . .
        RUN swift build -c release --static-swift-stdlib

        FROM ubuntu:24.04
        COPY --from=build /src/.build/release/app /usr/bin/app
        ENTRYPOINT ["app", "serve"]
        """#),
        CodeSample(language: "graphql", title: "query.graphql", code: #"""
        query Repo($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            stargazerCount
            issues(first: 5, states: OPEN) {
              nodes { number title author { login } }
            }
          }
        }
        """#),
        CodeSample(language: "vue", title: "Hello.vue", code: #"""
        <script setup lang="ts">
        import { ref } from "vue"
        const count = ref(0)
        </script>

        <template>
          <button @click="count++">Count is {{ count }}</button>
        </template>

        <style scoped> button { font-weight: bold; } </style>
        """#),
        CodeSample(language: "elixir", title: "math.ex", code: #"""
        defmodule Math do
          @doc "Sums a list recursively"
          def sum([]), do: 0
          def sum([head | tail]), do: head + sum(tail)
        end

        [1, 2, 3] |> Math.sum() |> IO.inspect(label: "sum")
        """#),
        CodeSample(language: "haskell", title: "Main.hs", code: #"""
        module Main where

        data Tree a = Leaf | Node (Tree a) a (Tree a)

        insert :: Ord a => a -> Tree a -> Tree a
        insert x Leaf = Node Leaf x Leaf
        insert x t@(Node l v r)
          | x < v = Node (insert x l) v r
          | x > v = Node l v (insert x r)
          | otherwise = t
        """#),
        CodeSample(language: "zig", title: "main.zig", code: #"""
        const std = @import("std");

        pub fn main() !void {
            const stdout = std.io.getStdOut().writer();
            var i: u8 = 0;
            while (i < 3) : (i += 1) {
                try stdout.print("Hello {d}\n", .{i});
            }
        }
        """#),
        CodeSample(language: "lua", title: "init.lua", code: #"""
        local M = {}

        function M.setup(opts)
          opts = vim.tbl_extend("force", { theme = "nord" }, opts or {})
          vim.cmd.colorscheme(opts.theme)
        end

        return M
        """#),
        CodeSample(language: "diff", title: "fix.patch", code: #"""
        --- a/Sources/App/Cache.swift
        +++ b/Sources/App/Cache.swift
        @@ -12,7 +12,7 @@ final class Cache {
             func value(for key: String) -> Data? {
        -        storage[key]
        +        lock.withLock { storage[key] }
             }
        """#),
        CodeSample(language: "markdown", title: "README.md", code: #"""
        # Shiki Swift

        Native highlighting with **VS Code themes** and `TextMate` grammars.

        ```swift
        let tokens = try highlighter.codeToTokens(code, language: "swift")
        ```

        - [x] 240+ languages
        - [ ] Your language next?
        """#),
    ]

    /// Source written with Shiki transformer notation (`// [!code …]`).
    static let annotated: [CodeSample] = [
        CodeSample(language: "swift", title: "Diff", code: #"""
        func loadUser(id: Int) async throws -> User {
            let url = URL(string: "https://api.example.com/users/\(id)")!
            let data = try Data(contentsOf: url) // [!code --]
            let (data, _) = try await URLSession.shared.data(from: url) // [!code ++]
            return try JSONDecoder().decode(User.self, from: data)
        }
        """#),
        CodeSample(language: "typescript", title: "Highlight", code: #"""
        export function debounce<T extends (...args: any[]) => void>(fn: T, ms = 250) {
          let timer: ReturnType<typeof setTimeout> | undefined
          return (...args: Parameters<T>) => {
            clearTimeout(timer) // [!code highlight]
            timer = setTimeout(() => fn(...args), ms) // [!code highlight]
          }
        }
        """#),
        CodeSample(language: "python", title: "Focus", code: #"""
        import csv
        from pathlib import Path

        def load_rows(path: Path) -> list[dict[str, str]]:
            with path.open(newline="") as handle:  # [!code focus:2]
                return list(csv.DictReader(handle))

        rows = load_rows(Path("data.csv"))
        print(len(rows))
        """#),
        CodeSample(language: "rust", title: "Errors & warnings", code: #"""
        fn parse_port(input: &str) -> u16 {
            let unused = 42; // [!code warning]
            input.parse().unwrap() // [!code error]
        }

        fn main() {
            println!("{}", parse_port("8080")); // [!code info]
        }
        """#),
        CodeSample(language: "swift", title: "Word highlight", code: #"""
        let session = URLSession.shared // [!code word:session]
        let (data, _) = try await session.data(from: url)
        print(data.count)
        """#),
    ]

    static let inspector = CodeSample(language: "typescript", title: "inspect.ts", code: #"""
    // Click any token to see its TextMate scopes
    import { readFile } from "node:fs/promises"

    interface Config { port: number; debug?: boolean }

    export async function load(path = "./config.json"): Promise<Config> {
      const raw = await readFile(path, "utf8")
      const config = JSON.parse(raw) as Config
      return { port: 8080, ...config }
    }
    """#)

    static let docs = #"""
    # Getting started

    Add the package to your **Package.swift**, then create a highlighter. Everything runs natively — there is *no* JavaScript runtime or web view.

    ```swift title="Package.swift"
    dependencies: [
        .package(url: "https://github.com/fayazara/shiki-swift", from: "1.0.0"),
    ]
    ```

    ## Highlight some code

    `codeToTokens` returns lines of themed tokens that you can render however you like.

    ```swift title="Example.swift"
    let highlighter = try ShikiHighlighter(defaultTheme: "github-dark")
    let result = try highlighter.codeToTokens("let x = 1", language: "swift")
    for line in result.tokens {
        print(line.map(\.content).joined())
    }
    ```

    ## Works with every bundled language

    Fenced code in *any* of the bundled languages is highlighted with the same theme:

    ```python title="server.py"
    from http.server import HTTPServer, SimpleHTTPRequestHandler
    HTTPServer(("", 8000), SimpleHTTPRequestHandler).serve_forever()
    ```

    ```json title="config.json"
    { "theme": "github-dark", "lineNumbers": true }
    ```

    ```shellscript
    swift build -c release && ./.build/release/app
    ```

    That's it — see the other demos for streaming, diffs, and terminals.
    """#
}

/// Terminal transcripts with real ANSI SGR escape sequences.
enum TerminalSamples {
    private static let e = "\u{1B}["

    static let all: [(title: String, text: String)] = [
        ("swift test", """
        \(e)1m[1/4]\(e)0m Compiling \(e)36mShikiCore\(e)0m TextMateGrammar.swift
        \(e)1m[2/4]\(e)0m Compiling \(e)36mShiki\(e)0m ShikiHighlighter.swift
        \(e)1m[3/4]\(e)0m \(e)33mwarning:\(e)0m variable 'unused' was never used
        \(e)1m[4/4]\(e)0m Linking ShikiPackageTests
        \(e)1mBuild complete!\(e)0m \(e)2m(12.41s)\(e)0m

        Test Suite 'All tests' started
        \(e)32m✔\(e)0m testGrammarStateSurvivesLoadingAnotherLanguage \(e)2m(0.107s)\(e)0m
        \(e)32m✔\(e)0m testAnsiEscapesBecomeColoredTokens \(e)2m(0.006s)\(e)0m
        \(e)31m✘\(e)0m testSomethingFlaky \(e)2m(0.020s)\(e)0m
            \(e)31mXCTAssertEqual failed: ("1") is not equal to ("2")\(e)0m
        \(e)1mExecuted 182 tests, with \(e)31m1 failure\(e)0m\(e)1m in 9.1 seconds\(e)0m
        """),
        ("git log --graph", """
        \(e)33m*\(e)0m \(e)33m9f8fd5b\(e)0m \(e)1;36m(HEAD -> \(e)1;32mmain\(e)1;36m, \(e)1;31morigin/main\(e)1;36m)\(e)0m Fix grammar state reuse
        \(e)33m*\(e)0m \(e)33m4c1a2e7\(e)0m Add ANSI tokenizer
        \(e)31m|\(e)32m\\\(e)0m
        \(e)31m|\(e)0m \(e)32m*\(e)0m \(e)33m81be0f3\(e)0m \(e)1;31m(origin/perf)\(e)0m Faster scope matching
        \(e)31m|\(e)0m \(e)32m*\(e)0m \(e)33m5d9c3aa\(e)0m Cache scope attributes
        \(e)31m|\(e)32m/\(e)0m
        \(e)33m*\(e)0m \(e)33m1e2f4b0\(e)0m \(e)1;33m(tag: v0.9.0)\(e)0m Initial Swift port
        """),
        ("npm install", """
        \(e)1mnpm\(e)0m \(e)43;30mWARN\(e)0m \(e)35mdeprecated\(e)0m inflight@1.0.6: This module is not supported
        \(e)1mnpm\(e)0m \(e)43;30mWARN\(e)0m \(e)35mdeprecated\(e)0m glob@7.2.3: Glob versions prior to v9 are no longer supported

        added \(e)1m312\(e)0m packages, and audited \(e)1m313\(e)0m packages in \(e)1m4s\(e)0m

        \(e)1m42\(e)0m packages are looking for funding
          run `\(e)1mnpm fund\(e)0m` for details

        \(e)1m3\(e)0m vulnerabilities (\(e)1m1 \(e)33mmoderate\(e)0m, \(e)1m2 \(e)31mhigh\(e)0m)
        """),
        ("256 & true color", """
        \(e)1mStandard:\(e)0m \(e)30m■\(e)31m■\(e)32m■\(e)33m■\(e)34m■\(e)35m■\(e)36m■\(e)37m■\(e)0m  \(e)90m■\(e)91m■\(e)92m■\(e)93m■\(e)94m■\(e)95m■\(e)96m■\(e)97m■\(e)0m
        \(e)1m256:\(e)0m      \((16..<52).map { "\(e)38;5;\($0)m█" }.joined())\(e)0m
        \(e)1mTrue:\(e)0m     \((0..<36).map { i in "\(e)38;2;\(255 - i * 7);\(i * 7);200m█" }.joined())\(e)0m
        \(e)1mStyles:\(e)0m   \(e)1mbold\(e)0m \(e)2mdim\(e)0m \(e)3mitalic\(e)0m \(e)4munderline\(e)0m \(e)9mstrike\(e)0m \(e)7m reverse \(e)0m
        """),
    ]
}

/// Canned assistant responses for the streaming chat demo.
enum StreamingSamples {
    struct Response {
        let prompt: String
        let prose: String
        let language: String
        let code: String
    }

    static let all: [Response] = [
        Response(
            prompt: "Write a debounced search field in SwiftUI",
            prose: "Here's a search field that waits 300 ms after the last keystroke before querying. It uses a `.task(id:)` so SwiftUI cancels stale searches for you:",
            language: "swift",
            code: #"""
            import SwiftUI

            struct SearchView: View {
                @State private var query = ""
                @State private var results: [String] = []

                var body: some View {
                    List(results, id: \.self) { Text($0) }
                        .searchable(text: $query)
                        .task(id: query) {
                            // Debounce: cancelled automatically when query changes.
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            results = await search(query)
                        }
                }

                private func search(_ text: String) async -> [String] {
                    /* Pretend this hits the network. */
                    ["\(text) one", "\(text) two", "\(text) three"]
                }
            }
            """#
        ),
        Response(
            prompt: "Parse a CSV file in Python and sum a column",
            prose: "The standard library's `csv.DictReader` handles quoting and headers. This sums the `amount` column and skips malformed rows:",
            language: "python",
            code: #"""
            import csv
            from decimal import Decimal, InvalidOperation
            from pathlib import Path


            def total_amount(path: Path, column: str = "amount") -> Decimal:
                """Sum a numeric column, ignoring rows that don't parse."""
                total = Decimal(0)
                with path.open(newline="", encoding="utf-8") as handle:
                    for row in csv.DictReader(handle):
                        try:
                            total += Decimal(row[column])
                        except (KeyError, InvalidOperation):
                            continue
                return total


            if __name__ == "__main__":
                print(f"Total: {total_amount(Path('sales.csv')):,.2f}")
            """#
        ),
        Response(
            prompt: "Define a Rust error type with thiserror",
            prose: "With `thiserror` you get `Display` and `From` implementations for free. Multi-line strings and attributes stream in correctly because each line resumes from the previous grammar state:",
            language: "rust",
            code: #"""
            use thiserror::Error;

            #[derive(Debug, Error)]
            pub enum ConfigError {
                #[error("config file not found at {path}")]
                NotFound { path: String },

                #[error("invalid value for `{key}`: {reason}")]
                Invalid { key: String, reason: String },

                #[error(transparent)]
                Io(#[from] std::io::Error),
            }

            /// Loads the config, mapping low-level failures to `ConfigError`.
            pub fn load(path: &str) -> Result<String, ConfigError> {
                std::fs::read_to_string(path).map_err(|err| match err.kind() {
                    std::io::ErrorKind::NotFound => ConfigError::NotFound { path: path.into() },
                    _ => ConfigError::Io(err),
                })
            }
            """#
        ),
    ]
}
