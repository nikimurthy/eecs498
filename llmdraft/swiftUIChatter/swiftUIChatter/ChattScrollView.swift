import SwiftUI

struct ChattView: View {
    @Environment(ChattViewModel.self) private var vm

    let chatt: Chatt
    let onTrailingEnd: Bool

    var body: some View {
        VStack(alignment: onTrailingEnd ? .trailing : .leading, spacing: 4) {
            if let msg = chatt.message, !msg.isEmpty {

                Text(onTrailingEnd ? "" : (chatt.name ?? ""))
                    .font(.subheadline)
                    .foregroundColor(.purple)
                    .padding(.leading, 4)

                Text(msg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(onTrailingEnd ? .systemBlue : .systemBackground))
                    .foregroundColor(onTrailingEnd ? .white : .primary)
                    .cornerRadius(20)
                    .shadow(radius: 2)
                    .frame(maxWidth: 300, alignment: onTrailingEnd ? .trailing : .leading)
                    .onLongPressGesture {
                        // REQUIREMENT 1: must be another user's chatt
                        guard !onTrailingEnd else { return }

                        // REQUIREMENT 2: no outstanding Ollama request
                        guard !vm.isOllamaBusy else { return }

                        // Copy selected message into textbox + focus it (optional UX)
                        vm.message = msg
                        vm.messageInFocus?.wrappedValue = true

                        vm.isOllamaBusy = true
                        vm.errMsg = ""

                        Task(priority: .background) {
                            await promptLlm(vm, prompt: """
                            You are a poet. Write a poetic reply to this message I received. Don't list options. Here's the message I want you to write a poetic reply to:
                            """)
                            vm.isOllamaBusy = false
                            vm.showError = !vm.errMsg.isEmpty
                        }
                    }

                Text(chatt.timestamp ?? "")
                    .font(.caption2)
                    .foregroundColor(.gray)

                Spacer()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct ChattScrollView: View {
    @Environment(ChattViewModel.self) private var vm

    var body: some View {
        ScrollView {
            LazyVStack {
                ForEach(ChattStore.shared.chatts) { chatt in
                    ChattView(chatt: chatt, onTrailingEnd: chatt.name == vm.onTrailingEnd)
                }
            }
        }
    }
}
