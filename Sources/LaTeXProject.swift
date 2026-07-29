import Foundation

/// The files that give one editor window its project-level behavior.
struct LaTeXProjectContext: Equatable {
    let currentFile: URL
    let mainFile: URL
    let projectDirectory: URL
    let rootSource: String
    let includedFiles: Set<URL>

    var isEditingMainFile: Bool {
        currentFile.standardizedFileURL == mainFile.standardizedFileURL
    }
}

/// Resolves an arbitrary `.tex` file to the document that owns it.
///
/// Resolution is deliberately bounded: at most three ancestors, four directory levels, and 512
/// TeX files are inspected. This finds conventional `root/sections/foo.tex` layouts without ever
/// turning opening a file into an unbounded crawl of a home directory.
enum LaTeXProjectResolver {
    private static let maximumAncestorCount = 3
    private static let maximumDirectoryDepth = 4
    private static let maximumTexFiles = 512

    static func resolve(_ currentFile: URL, fileManager: FileManager = .default) -> LaTeXProjectContext {
        let current = currentFile.standardizedFileURL
        let currentSource = read(current)

        if let magicRoot = magicRoot(in: currentSource, relativeTo: current.deletingLastPathComponent()),
           fileManager.fileExists(atPath: magicRoot.path) {
            return context(current: current, main: magicRoot, fileManager: fileManager)
        }

        // The `subfiles` package encodes its owning document in the optional document-class
        // argument and is semantically the same as a root directive.
        if let subfilesRoot = subfilesRoot(
            in: currentSource, relativeTo: current.deletingLastPathComponent()
        ), fileManager.fileExists(atPath: subfilesRoot.path) {
            return context(current: current, main: subfilesRoot, fileManager: fileManager)
        }

        // A document with its own document class is a first-class root, even if another project
        // happens to include it (standalone/subfiles workflows can opt into the parent via magic).
        if containsDocumentClass(currentSource) {
            return context(current: current, main: current, fileManager: fileManager)
        }

        var candidates: [(url: URL, graphDistance: Int, ancestorDistance: Int)] = []
        var directory = current.deletingLastPathComponent()
        for ancestorDistance in 0..<maximumAncestorCount {
            let files = texFiles(below: directory, fileManager: fileManager)
            for candidate in files where candidate != current {
                let source = read(candidate)
                guard containsDocumentClass(source),
                      let distance = includeDistance(from: candidate, to: current, fileManager: fileManager)
                else { continue }
                candidates.append((candidate, distance, ancestorDistance))
            }
            if !candidates.isEmpty { break }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }

        let main = candidates.sorted {
            if $0.graphDistance != $1.graphDistance { return $0.graphDistance < $1.graphDistance }
            if $0.ancestorDistance != $1.ancestorDistance { return $0.ancestorDistance < $1.ancestorDistance }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }.first?.url ?? current
        return context(current: current, main: main, fileManager: fileManager)
    }

    /// TeXShop/TeXworks root directive. It is intentionally read from comments before ordinary
    /// comment removal; both `% !TEX root = main` and `% !TeX root = ../main.tex` are accepted.
    static func magicRoot(in source: String, relativeTo directory: URL) -> URL? {
        let pattern = #"(?im)^\s*%\s*!\s*tex\s+root\s*=\s*(.+?)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: source, range: NSRange(source.startIndex..., in: source)
              ),
              let range = Range(match.range(at: 1), in: source)
        else { return nil }
        var path = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if (path.hasPrefix("\"") && path.hasSuffix("\"")) ||
            (path.hasPrefix("'") && path.hasSuffix("'")) {
            path.removeFirst()
            path.removeLast()
        }
        guard !path.isEmpty else { return nil }
        return texURL(path, relativeTo: directory)
    }

    static func subfilesRoot(in source: String, relativeTo directory: URL) -> URL? {
        let pattern = #"\\documentclass\s*\[([^\]]+)\]\s*\{\s*subfiles\s*\}"#
        let uncommented = removingComments(from: source)
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ), let match = expression.firstMatch(
            in: uncommented, range: NSRange(uncommented.startIndex..., in: uncommented)
        ), let range = Range(match.range(at: 1), in: uncommented)
        else { return nil }
        return texURL(String(uncommented[range]), relativeTo: directory)
    }

    /// Included paths in source order, with comments ignored and omitted `.tex` suffixes filled.
    static func includedURLs(in source: String, sourceURL: URL) -> [URL] {
        includedURLs(
            in: source,
            sourceURL: sourceURL,
            projectDirectory: nil,
            fileManager: .default
        )
    }

    /// Resolve ordinary `\input`/`\include` paths the same way the compiler is launched: from
    /// the main document's working directory. A source-relative fallback also recognizes projects
    /// that intentionally keep child-relative paths (or use TeX path helpers to provide them).
    private static func includedURLs(
        in source: String,
        sourceURL: URL,
        projectDirectory: URL?,
        fileManager: FileManager
    ) -> [URL] {
        let uncommented = removingComments(from: source)
        let directory = sourceURL.deletingLastPathComponent()
        var matches: [(offset: Int, url: URL)] = []

        let simplePattern = #"\\(?:input|include|subfile)\*?\s*\{([^{}]+)\}"#
        matches += captures(simplePattern, in: uncommented).compactMap { offset, groups in
            guard let path = groups.first else { return nil }
            return (
                offset,
                inputURL(
                    path,
                    sourceDirectory: directory,
                    projectDirectory: projectDirectory,
                    fileManager: fileManager
                )
            )
        }
        let primitiveInputPattern = #"\\input\s+([^\s%{}]+)"#
        matches += captures(primitiveInputPattern, in: uncommented).compactMap { offset, groups in
            guard let path = groups.first else { return nil }
            return (
                offset,
                inputURL(
                    path,
                    sourceDirectory: directory,
                    projectDirectory: projectDirectory,
                    fileManager: fileManager
                )
            )
        }

        // import, subimport, inputfrom, subinputfrom, includefrom and subincludefrom all use
        // `{directory}{file}`. A star after the command is tolerated.
        let importPattern =
            #"\\(?:import|subimport|inputfrom|subinputfrom|includefrom|subincludefrom)\*?\s*\{([^{}]*)\}\s*\{([^{}]+)\}"#
        matches += captures(importPattern, in: uncommented).compactMap { offset, groups in
            guard groups.count == 2 else { return nil }
            let importDirectory = URL(filePath: groups[0], relativeTo: directory).standardizedFileURL
            return (offset, texURL(groups[1], relativeTo: importDirectory))
        }

        var seen = Set<URL>()
        return matches.sorted { $0.offset < $1.offset }.compactMap {
            let url = $0.url.standardizedFileURL
            return seen.insert(url).inserted ? url : nil
        }
    }

    private static func context(current: URL, main: URL,
                                fileManager: FileManager) -> LaTeXProjectContext {
        let normalizedMain = main.standardizedFileURL
        let source = read(normalizedMain)
        return LaTeXProjectContext(
            currentFile: current,
            mainFile: normalizedMain,
            projectDirectory: normalizedMain.deletingLastPathComponent(),
            rootSource: source,
            includedFiles: transitiveIncludes(from: normalizedMain, fileManager: fileManager)
        )
    }

    private static func includeDistance(from root: URL, to target: URL,
                                        fileManager: FileManager) -> Int? {
        let target = target.standardizedFileURL
        var queue: [(URL, Int)] = [(root.standardizedFileURL, 0)]
        var visited = Set<URL>()
        while !queue.isEmpty, visited.count < maximumTexFiles {
            let (file, distance) = queue.removeFirst()
            guard visited.insert(file).inserted else { continue }
            if file == target { return distance }
            for included in includedURLs(
                in: read(file),
                sourceURL: file,
                projectDirectory: root.deletingLastPathComponent(),
                fileManager: fileManager
            )
                where fileManager.fileExists(atPath: included.path) {
                queue.append((included, distance + 1))
            }
        }
        return nil
    }

    private static func transitiveIncludes(from root: URL,
                                           fileManager: FileManager) -> Set<URL> {
        var pending = [root.standardizedFileURL]
        var visited = Set<URL>()
        while let file = pending.popLast(), visited.count < maximumTexFiles {
            guard visited.insert(file).inserted else { continue }
            pending.append(contentsOf: includedURLs(
                in: read(file),
                sourceURL: file,
                projectDirectory: root.deletingLastPathComponent(),
                fileManager: fileManager
            )
                .filter { fileManager.fileExists(atPath: $0.path) })
        }
        visited.remove(root.standardizedFileURL)
        return visited
    }

    private static func texFiles(below root: URL, fileManager: FileManager) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - root.pathComponents.count
            if relativeDepth > maximumDirectoryDepth {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "tex" else { continue }
            files.append(url.standardizedFileURL)
            if files.count >= maximumTexFiles { break }
        }
        return files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private static func containsDocumentClass(_ source: String) -> Bool {
        removingComments(from: source).range(
            of: #"\\documentclass(?:\s*\[[^\]]*\])?\s*\{"#, options: .regularExpression
        ) != nil
    }

    private static func removingComments(from source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var escaped = false
            for index in line.indices {
                let character = line[index]
                if character == "%", !escaped { return String(line[..<index]) }
                if character == "\\" {
                    escaped.toggle()
                } else {
                    escaped = false
                }
            }
            return String(line)
        }.joined(separator: "\n")
    }

    private static func captures(_ pattern: String, in source: String)
        -> [(Int, [String])] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(source.startIndex..., in: source)
        return expression.matches(in: source, range: nsRange).map { match in
            let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let range = Range(match.range(at: index), in: source) else { return nil }
                return String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (match.range.location, groups)
        }
    }

    private static func texURL(_ path: String, relativeTo directory: URL) -> URL {
        var url = URL(filePath: path.trimmingCharacters(in: .whitespacesAndNewlines),
                      relativeTo: directory).standardizedFileURL
        if url.pathExtension.isEmpty { url.appendPathExtension("tex") }
        return url
    }

    private static func inputURL(
        _ path: String,
        sourceDirectory: URL,
        projectDirectory: URL?,
        fileManager: FileManager
    ) -> URL {
        if let projectDirectory {
            let rootRelative = texURL(path, relativeTo: projectDirectory)
            if fileManager.fileExists(atPath: rootRelative.path) { return rootRelative }
        }
        return texURL(path, relativeTo: sourceDirectory)
    }

    private static func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
