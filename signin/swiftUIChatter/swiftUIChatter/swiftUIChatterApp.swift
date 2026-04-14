//
//  swiftUIChatterApp.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 1/14/26.
//

import SwiftUI

@Observable
final class ChattViewModel {
    var onTrailingEnd = "qwen3:0.6b"
//    let onTrailingEnd = "gemma3:270m"
//    let onTrailingEnd = "qwen3:8b"
//    let onTrailingEnd = "qwen3"
    let appID = Bundle.main.bundleIdentifier
    let sysmsg = ""
    
    let instruction = "Type a message…"
    var message = "What is the weather at my location?"
    
    var errMsg = ""
    var showError = false
    
    var showOk = false
        
    var getSignedin: Bool = false
    @ObservationIgnored var signinCompletion: (() async -> Void)?
}

@main
struct swiftUIChatterApp: App {
    let viewModel = ChattViewModel()
    
    init() {
        LocManager.shared.startUpdates()
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
        
        Task(priority: .background) { [self] in
            await ChatterID.shared.open(errMsg: Bindable(vm).errMsg, showOk: Bindable(vm).showOk)
            if !ChatterID.shared.creator.isEmpty {
                vm.onTrailingEnd = ChatterID.shared.creator
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

