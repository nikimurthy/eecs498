//
//  swiftUIChatterApp.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 1/14/26.
//

import SwiftUI

@Observable
final class ChattViewModel {
//    let onTrailingEnd = "qwen3:0.6b"
    let onTrailingEnd = "gemma3:270m"
    let appID = Bundle.main.bundleIdentifier
    let sysmsg = "Start every assistant reply with GO BLUE!!!"
    
    let instruction = "Type a message…"
    var message = "howdy?"
    
    var errMsg = ""
    var showError = false
}

@main
struct swiftUIChatterApp: App {
    let viewModel = ChattViewModel()
    
    init() {
        // disable interaction until llmPrep is done
        Task { [self] in
            if let appID = viewModel.appID, !viewModel.sysmsg.isEmpty {
                await ChattStore.shared.llmPrep(
                    appID: appID,
                    chatt: Chatt(name: viewModel.onTrailingEnd, message: viewModel.sysmsg),
                    errMsg: Bindable(viewModel).errMsg)
                viewModel.showError = !viewModel.errMsg.isEmpty
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ContentView()
                    .onAppear {
                        let scenes = UIApplication.shared.connectedScenes
                        let windowScene = scenes.first as? UIWindowScene
                        
                        if let wnd = windowScene?.windows.first {
                            let lagFreeField = UITextField()
                            
                            wnd.addSubview(lagFreeField)
                            lagFreeField.becomeFirstResponder()
                            lagFreeField.resignFirstResponder()
                            lagFreeField.removeFromSuperview()
                        }
                    }
            }
            .environment(viewModel)
        }
    }
}

