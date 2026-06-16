// ContentView.swift

import SwiftUI
import BattyKit

struct ContentView: View {
    let windowID: WindowID

    init(windowID: WindowID = WindowID()) {
        self.windowID = windowID
    }

    var body: some View {
        RootWindowView(windowID: windowID)
    }
}

#Preview {
    ContentView()
}
