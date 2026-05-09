// ContentView.swift

import SwiftUI
import BattyKit

struct ContentView: View {
    @State private var terminal = TerminalViewState()

    var body: some View {
        TerminalSurfaceView(context: terminal)
            .frame(minWidth: 600, minHeight: 400)
            .navigationTitle(terminal.title.isEmpty ? "Batty" : terminal.title)
    }
}

#Preview {
    ContentView()
}
