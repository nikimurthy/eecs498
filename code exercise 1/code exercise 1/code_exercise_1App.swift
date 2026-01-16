// UM EECS Reactive
// Solutions using ObservableObject, @Published, @StateObject,
// @ObservedObject, @EnvironmentObject NOT ACCEPTED

import SwiftUI

final class Hello {
    var hello = "hello"
}

struct TextView: View {
    @State var text: String
    var body: some View {
        Text(text)
    }
}

struct ButtonView: View {
    @State var text: String
    var body: some View {
        Button("Hello world!") { text = "Hello world!" }
    }
}

struct ContentView: View {
    let greetings = Hello() // DO NOT MODIFY LINE
    
    var body: some View {
        VStack {
            TextView(text: greetings.hello) // DO NOT MODIFY LINE
            Button("Change greetings") { greetings.hello = "hi there" }

            Text(greetings.hello)
            ButtonView(text: greetings.hello)
        }
    }
}
