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
    @State private var currentScreen: AppScreen
    @State private var connectionError: String?
    
    init() {
        // Check if user is already enrolled - skip setup if so
        if CertificateManager.shared.isEnrolled {
            _currentScreen = State(initialValue: .chat)
        } else {
            _currentScreen = State(initialValue: .setup)
        }
    }
    
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
        .onReceive(NotificationCenter.default.publisher(for: .userDidLogout)) { _ in
            withAnimation(.easeInOut(duration: 0.3)) {
                currentScreen = .setup
            }
        }
    }
}

#Preview {
    ContentView()
}
