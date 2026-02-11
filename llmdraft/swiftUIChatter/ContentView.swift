//
//  ContentView.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 1/14/26.
//

import SwiftUI

struct SubmitButton: View {
    @Binding var scrollProxy: ScrollViewProxy?
    @Environment(ChattViewModel.self) private var vm
    
    @State private var isSending = false

    var body: some View {
        Button {
            isSending = true
            Task (priority: .background){
                await ChattStore.shared.postChatt(Chatt(name: vm.onTrailingEnd, message: vm.message), errMsg: Bindable(vm).errMsg)
                if vm.errMsg.isEmpty { await ChattStore.shared.getChatts(errMsg: Bindable(vm).errMsg) }

                // completion code
                vm.message = ""
                isSending = false
                vm.showError = !vm.errMsg.isEmpty
                Task (priority: .userInitiated) {
                    withAnimation {
                        scrollProxy?.scrollTo(ChattStore.shared.chatts.last?.id, anchor: .bottom)
                    }
                }
            }
        } label: {
            // icons
            if isSending {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .secondary))
                    .padding(10)
            } else {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(vm.message.isEmpty ? .gray : .yellow)
                    .padding(10)
            }
        }
        // modifiers
        .disabled(isSending || vm.message.isEmpty)
        .background(Color(isSending || vm.message.isEmpty ? .secondarySystemBackground : .systemBlue))
        .clipShape(Circle())
        .padding(.trailing)
    }
}

struct AiButton: View {
    @Environment(ChattViewModel.self) private var vm

    var body: some View {
        Button {
            // Set busy BEFORE starting task (requirement)
            vm.isOllamaBusy = true
            vm.errMsg = ""

            Task(priority: .background) {
                await promptLlm(vm, prompt: """
                You are a poet. Rewrite the content below to a poetic version. Don't list options. Here's the content I want you to rewrite:
                """)
                vm.isOllamaBusy = false
                vm.showError = !vm.errMsg.isEmpty
            }
        } label: {
            Image(systemName: "sparkles")
                .foregroundColor((vm.message.isEmpty || vm.isOllamaBusy) ? .gray : .blue)
                .padding(10)
        }
        .disabled(vm.message.isEmpty || vm.isOllamaBusy)
    }
}

struct ContentView: View {
    @Environment(ChattViewModel.self) private var vm
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var messageInFocus: Bool // tap background to dismiss kbd
    
    var body: some View {
        VStack {
            ScrollViewReader { proxy in
                ChattScrollView()
                    .onAppear {
                        scrollProxy = proxy
                    }
                    .refreshable {
                        await ChattStore.shared.getChatts(errMsg: Bindable(vm).errMsg)
                        Task (priority: .userInitiated) {
                            withAnimation {
                                scrollProxy?.scrollTo(ChattStore.shared.chatts.last?.id, anchor: .bottom)
                            }
                        }
                    }
            }
            // prompt input and submit
            HStack (alignment: .bottom) {
                AiButton()
                
                TextField(vm.instruction, text: Bindable(vm).message, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($messageInFocus) // to dismiss keyboard
                    .textFieldStyle(.roundedBorder)
                    .cornerRadius(20)
                    .shadow(radius: 2)
                    .background(Color(.clear))
                    .border(Color(.clear))

                SubmitButton(scrollProxy: $scrollProxy)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 0))
          
        }
        // tap background to dismiss kbd
        .contentShape(.rect)
        .onTapGesture {
            messageInFocus.toggle()
        }
        .navigationTitle("llmPrompt")
        .navigationBarTitleDisplayMode(.inline)
        .task (priority: .background) {
            await ChattStore.shared.getChatts(errMsg: Bindable(vm).errMsg)
            vm.showError = !vm.errMsg.isEmpty
            Task (priority: .userInitiated) {
                withAnimation {
                    scrollProxy?.scrollTo(ChattStore.shared.chatts.last?.id, anchor: .bottom)
                }
            }
        }
        // show error in an alert dialog
        .alert("LLM Error", isPresented: Bindable(vm).showError) {
            Button("OK") {
                vm.errMsg = ""
            }
        } message: {
            Text(vm.errMsg)
        }

    }
}

func promptLlm(_ vm: ChattViewModel, prompt: String) async {

    let modelName = "gemma3:270m"   // or gemma3 if using mada

    let content = vm.message
    let fullPrompt = "\(prompt)\n\n\(content)"

    // clear textbox so streamed draft shows
    vm.message = ""

    let chatt = Chatt(name: modelName, message: fullPrompt)

    await ChattStore.shared.llmDraft(
        chatt,
        draft: Bindable(vm).message,
        errMsg: Bindable(vm).errMsg
    )
}
