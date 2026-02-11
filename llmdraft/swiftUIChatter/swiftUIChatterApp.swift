//
//  swiftUIChatterApp.swift
//  swiftUIChatter
//
//  Created by Niki Murthy on 1/14/26.
//

import SwiftUI

@Observable
final class ChattViewModel {
    let onTrailingEnd = "nikivm"

    let instruction = "Type a message…"
    var message = "howdy?"
    var draft = ""           
    var isOllamaBusy = false
    
    var errMsg = ""
    var showError = false
    
    var messageInFocus: FocusState<Bool>.Binding!
}

@main
struct swiftUIChatterApp: App {
    let viewModel = ChattViewModel()

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

