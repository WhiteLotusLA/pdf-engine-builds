import SwiftUI

@main
struct PDFiumSmokeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var summary = "Counting pages..."

    var body: some View {
        Text(summary)
            .font(.largeTitle)
            .accessibilityIdentifier("summary")
            .task {
                guard let url = Bundle.main.url(forResource: "three-pages", withExtension: "pdf") else {
                    summary = "Fixture missing"
                    return
                }
                do {
                    let pages = try PDFiumSmoke.pageCount(of: url)
                    summary = "PDFium counted \(pages) pages"
                } catch {
                    summary = "PDFium could not open the fixture"
                }
            }
    }
}
