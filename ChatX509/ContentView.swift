//
//  ContentView.swift
//  chat509
//
//  Created by Ihor Horobets on 24.12.2025.
//

import SwiftUI

enum AppScreen {
    case setup
    case connecting
    case chat
}

struct ContentView: View {
    @State private var currentScreen: AppScreen = .setup
    @State private var connectionError: String?
    
    var body: some View {
        ZStack {
            switch currentScreen {
            case .setup:
                SetupFormView(onConnect: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentScreen = .connecting
                    }
                })
                .transition(.opacity)
                
            case .connecting:
                ConnectingView(
                    onComplete: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .chat
                        }
                    },
                    onError: { error in
                        connectionError = error
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentScreen = .setup
                        }
                    }
                )
                .transition(.opacity)
                
            case .chat:
                UsersListView()
                    .transition(.opacity)
            }
        }
    }
}

#Preview {
    ContentView()
}
