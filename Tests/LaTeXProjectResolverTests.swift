import Foundation
import XCTest
@testable import iTex

final class LaTeXProjectResolverTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        super.tearDown()
    }

    func testMagicRootWins() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\begin{document}\\input{child}\\end{document}",
            "child.tex": "% !TEX root = main.tex\nChild"
        ])
        let result = LaTeXProjectResolver.resolve(root.appending(path: "child.tex"))
        XCTAssertEqual(result.mainFile, root.appending(path: "main.tex").standardizedFileURL)
    }

    func testDirectIncludeWithoutExtension() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\n\\input{section}",
            "section.tex": "Section"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "section.tex")).mainFile,
            root.appending(path: "main.tex").standardizedFileURL
        )
    }

    func testTransitiveInclude() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\n\\include{part}",
            "part.tex": "\\subfile{leaf}",
            "leaf.tex": "Leaf"
        ])
        let result = LaTeXProjectResolver.resolve(root.appending(path: "leaf.tex"))
        XCTAssertEqual(result.mainFile, root.appending(path: "main.tex").standardizedFileURL)
        XCTAssertTrue(result.includedFiles.contains(root.appending(path: "part.tex").standardizedFileURL))
        XCTAssertTrue(result.includedFiles.contains(root.appending(path: "leaf.tex").standardizedFileURL))
    }

    func testNestedInputCanRemainRelativeToMainWorkingDirectory() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\n\\input{sections/part}",
            "sections/part.tex": "\\input{shared/leaf}",
            "shared/leaf.tex": "Leaf"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "shared/leaf.tex")).mainFile,
            root.appending(path: "main.tex").standardizedFileURL
        )
    }

    func testCommentedIncludeIsIgnored() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\n% \\input{child}",
            "child.tex": "Not actually included"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "child.tex")).mainFile,
            root.appending(path: "child.tex").standardizedFileURL
        )
    }

    func testAmbiguousRootsChooseLexicographically() throws {
        let root = try fixture([
            "a.tex": "\\documentclass{article}\\input{child}",
            "b.tex": "\\documentclass{article}\\input{child}",
            "child.tex": "Shared"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "child.tex")).mainFile,
            root.appending(path: "a.tex").standardizedFileURL
        )
    }

    func testStandaloneDocumentFallsBackToItself() throws {
        let root = try fixture([
            "standalone.tex": "\\documentclass{article}\\begin{document}Hi\\end{document}"
        ])
        let file = root.appending(path: "standalone.tex").standardizedFileURL
        XCTAssertEqual(LaTeXProjectResolver.resolve(file).mainFile, file)
    }

    func testImportFamilyForm() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\import{sections/}{one}",
            "sections/one.tex": "One"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "sections/one.tex")).mainFile,
            root.appending(path: "main.tex").standardizedFileURL
        )
    }

    func testSubfilesDocumentClassPointsToRoot() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\subfile{sections/one}",
            "sections/one.tex": "\\documentclass[../main.tex]{subfiles}\\begin{document}One\\end{document}"
        ])
        XCTAssertEqual(
            LaTeXProjectResolver.resolve(root.appending(path: "sections/one.tex")).mainFile,
            root.appending(path: "main.tex").standardizedFileURL
        )
    }

    func testSuppliedSurveyProjectWhenAvailable() throws {
        let project = URL(filePath:
            "/Users/gyu/Desktop/02_ajou/02_vcl/01-2026-seminar/02-pbd-pd/ppt")
        let survey = project.appending(path: "survey.tex").standardizedFileURL
        guard FileManager.default.fileExists(atPath: survey.path) else {
            throw XCTSkip("Desktop survey fixture is not available")
        }
        for childName in ["sec_pbd.tex", "sec_pd.tex"] {
            let child = project.appending(path: childName)
            XCTAssertEqual(LaTeXProjectResolver.resolve(child).mainFile, survey, childName)
        }
    }

    private func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "itex-resolver-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        for (relativePath, source) in files {
            let file = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }
}

final class BuildDiagnosticParsingTests: XCTestCase {
    func testFileLineDiagnosticsRetainIncludedFile() {
        let project = URL(filePath: "/tmp/itex-project")
        let main = project.appending(path: "main.tex")
        let error = CompilerError.buildFailed(
            "sections/child.tex:17: Undefined control sequence.\nmain.tex:4: Missing $ inserted."
        )
        let diagnostics = LaTeXCompiler.diagnostics(from: error, mainFile: main)
        XCTAssertEqual(diagnostics.map(\.file), [
            project.appending(path: "sections/child.tex").standardizedFileURL,
            main.standardizedFileURL
        ])
        XCTAssertEqual(diagnostics.map(\.line), [17, 4])
    }

    func testPrivateRootDiagnosticMapsBackToMain() {
        let main = URL(filePath: "/tmp/project/main.tex")
        let privateRoot = URL(filePath: "/tmp/private/main-itexfinal.tex")
        let error = CompilerError.buildFailed(
            "\(privateRoot.path):9: Emergency stop."
        )
        XCTAssertEqual(
            LaTeXCompiler.diagnostics(
                from: error, mainFile: main, compiledRoot: privateRoot
            ).first?.file,
            main.standardizedFileURL
        )
    }
}

@MainActor
final class ProjectWorkspaceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories = []
        super.tearDown()
    }

    func testOpeningAndSwitchingIncludedEditorsKeepsSharedPreviewGeneration() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\begin{document}\\input{sections/child}\\end{document}",
            "sections/child.tex": "Child"
        ])
        let main = root.appending(path: "main.tex")
        let child = root.appending(path: "sections/child.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        let sharedCompiler = workspace.compiler
        let initialGeneration = sharedCompiler.compilationID

        workspace.openTab(child)

        XCTAssertTrue(workspace.compiler === sharedCompiler)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.activeFileURL, child.standardizedFileURL)
        XCTAssertEqual(workspace.projectContext.mainFile, main.standardizedFileURL)
        XCTAssertEqual(
            sharedCompiler.compilationID,
            initialGeneration,
            "Selecting an editor tab must not compile or refresh the shared PDF viewer."
        )

        workspace.selectPreviousTab()
        XCTAssertEqual(workspace.activeFileURL, main.standardizedFileURL)
        XCTAssertEqual(sharedCompiler.compilationID, initialGeneration)
    }

    func testSaveAllWritesDirtyChildWithoutChangingProjectRoot() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\begin{document}\\input{child}\\end{document}",
            "child.tex": "Before"
        ])
        let main = root.appending(path: "main.tex")
        let child = root.appending(path: "child.tex")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)
        workspace.openTab(child)
        workspace.activeTab?.source = "After"

        try workspace.saveAll()

        XCTAssertEqual(try String(contentsOf: child, encoding: .utf8), "After")
        XCTAssertFalse(workspace.hasDirtyTabs)
        XCTAssertEqual(workspace.projectContext.mainFile, main.standardizedFileURL)
    }

    func testNonTexEditorStaysInOwningProject() throws {
        let root = try fixture([
            "main.tex": "\\documentclass{article}\\begin{document}Hi\\end{document}",
            "refs.bib": "@book{x,title={X}}"
        ])
        let main = root.appending(path: "main.tex")
        let bibliography = root.appending(path: "refs.bib")
        let workspace = ProjectWorkspace(initialURL: main, tracksRecentDocuments: false)

        workspace.openTab(bibliography)

        XCTAssertEqual(workspace.projectContext.mainFile, main.standardizedFileURL)
        XCTAssertEqual(workspace.compiler.mainFileURL, main.standardizedFileURL)
        XCTAssertEqual(workspace.compiler.fileURL, bibliography.standardizedFileURL)
    }

    private func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "itex-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        for (relativePath, source) in files {
            let file = root.appending(path: relativePath)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try source.write(to: file, atomically: true, encoding: .utf8)
        }
        return root.standardizedFileURL
    }
}
