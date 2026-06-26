import SwiftUI

@main
struct iTexApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: LaTeXDocument()) { config in
            ContentView(document: config.$document, fileURL: config.fileURL)
        }
    }
}
