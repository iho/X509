//
//  ConnectingView.swift
//  chat509
//
//  Created on 24.12.2025.
//

import SwiftUI

struct ConnectingView: View {
    @State private var rotationAngle: Double = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var statusText: String = "Connecting to CA Server..."
    
    let onComplete: () -> Void
    let onError: (String) -> Void
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    Color(red: 0.1, green: 0.1, blue: 0.2),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 48) {
                Spacer()
                
                // Animated spinner
                spinnerView
                
                // Status text
                VStack(spacing: 12) {
                    Text(statusText)
                        .font(.headline)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                    
                    Text("Please wait...")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Cancel button
                Button(action: { onError("Connection cancelled") }) {
                    Text("Cancel")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }
                .padding(.bottom, 48)
            }
        }
        .onAppear {
            startAnimations()
            simulateConnection()
        }
    }
    
    // MARK: - Spinner View
    private var spinnerView: some View {
        ZStack {
            // Pulsing background circle
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.3), Color.clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 80
                    )
                )
                .frame(width: 160, height: 160)
                .scaleEffect(pulseScale)
            
            // Outer rotating ring
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    LinearGradient(
                        colors: [.blue, .purple, .blue.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 100, height: 100)
                .rotationEffect(.degrees(rotationAngle))
            
            // Inner rotating ring (opposite direction)
            Circle()
                .trim(from: 0, to: 0.5)
                .stroke(
                    LinearGradient(
                        colors: [.purple, .pink, .purple.opacity(0.2)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 70, height: 70)
                .rotationEffect(.degrees(-rotationAngle * 1.5))
            
            // Center icon
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }
    
    // MARK: - Animations
    private func startAnimations() {
        // Rotation animation
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
        
        // Pulse animation
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulseScale = 1.2
        }
    }
    
    // MARK: - Connection Simulation
    private func simulateConnection() {
        // Quick 1-second connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            onComplete()
        }
    }
}

#Preview {
    ConnectingView(
        onComplete: { print("Complete") },
        onError: { error in print("Error: \(error)") }
    )
}
