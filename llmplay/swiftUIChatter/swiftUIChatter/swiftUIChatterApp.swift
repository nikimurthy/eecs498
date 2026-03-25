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
//    let onTrailingEnd = "gemma3:12b"
    let appID = Bundle.main.bundleIdentifier
    let sysmsg = "Think of a city. Do not tell the user the name of the city. Ask the user if they are ready to start. If so, give the user 2 to 3 hints at a time and let the user guess. If the user guessed wrong, give them more hints about the city they guessed wrong. When they guessed right, say the following **in the provided format**, along with the lat/lon of the city, and then ask the user if they want to play again. If yes, give them the 2 to 3 hints for the next city:WINNER!!!:lat:lon:"
        
//    let sysmsg = "Repeat after user, verbatim."
    
    let instruction = "Type a message…"
    var message = ""
    var hints = ""
    var errMsg = ""
    var showError = false
}

@main
struct swiftUIChatterApp: App {
    let viewModel = ChattViewModel()
    
    init() {
        LocManager.shared.startUpdates()
        // disable interaction until llmPrep is done
        Task { [self] in
            if let appID = viewModel.appID, !viewModel.sysmsg.isEmpty {
                // 1. send system prompt
                await ChattStore.shared.llmPrep(
                    appID: appID,
                    chatt: Chatt(name: viewModel.onTrailingEnd,
                                 message: viewModel.sysmsg),
                    errMsg: Bindable(viewModel).errMsg
                )

                // 2. send "Yes" to start game
                await ChattStore.shared.llmPlay(
                    appID: appID,
                    chatt: Chatt(name: viewModel.onTrailingEnd, message: "Yes"),
                    hints: Bindable(viewModel).hints,
                    winner: nil,
                    errMsg: Bindable(viewModel).errMsg
                )
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

