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
    
    var focus: FocusState<Bool>.Binding

    var body: some View {
        Button {
            isSending = true
            Task (priority: .background){
                if (ChatterID.shared.id == nil) {
                    await withUnsafeContinuation { submitAt in
                        vm.signinCompletion = { () -> Void in
                            vm.onTrailingEnd = ChatterID.shared.creator
                            submitAt.resume()
                        }
                        vm.getSignedin = true
                    }
                    // here be submitAt
                }
                
                // may still be nil if signin failed
                if (ChatterID.shared.id != nil) {
                    if let appID = vm.appID {
                        await ChattStore.shared.llmTools(
                            appID: appID,
                            chatt: Chatt(name: vm.onTrailingEnd, message: vm.message),
                            errMsg: Bindable(vm).errMsg
                        )
                    }

                    Task (priority: .userInitiated) {
                        withAnimation {
                            scrollProxy?.scrollTo(ChattStore.shared.chatts.last?.id, anchor: .bottom)
                            focus.wrappedValue = false
                        }
                    }
                }
                vm.message = ""
                isSending = false
                vm.showError = !vm.showOk && !vm.errMsg.isEmpty
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
            }
            // prompt input and submit
            HStack (alignment: .bottom) {
                TextField(vm.instruction, text: Bindable(vm).message)
                    .focused($messageInFocus) // to dismiss keyboard
                    .textFieldStyle(.roundedBorder)
                    .cornerRadius(20)
                    .shadow(radius: 2)
                    .background(Color(.clear))
                    .border(Color(.clear))

                SubmitButton(scrollProxy: $scrollProxy, focus: $messageInFocus)
            }
            .padding(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 0))
          
        }
        // tap background to dismiss kbd
        .contentShape(.rect)
        .onTapGesture {
            messageInFocus.toggle()
        }
        .navigationTitle("llmAction")
        .navigationBarTitleDisplayMode(.inline)
        // show error in an alert dialog
        .alert("LLM Error", isPresented: Bindable(vm).showError) {
            Button("OK") {
                vm.errMsg = ""
            }
        } message: {
            Text(vm.errMsg)
        }
        .alert("Advisory", isPresented: Bindable(vm).showOk) {
            Button("OK") {
                vm.errMsg = ""
            }
        } message: {
            Text(vm.errMsg)
        }
        .sheet(isPresented: Bindable(vm).getSignedin) {
            SigninView(isPresenting: Bindable(vm).getSignedin)
                .presentationDetents([.fraction(0.25)])
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled()
        }
    }
}
