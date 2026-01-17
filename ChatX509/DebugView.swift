//
//  DebugView.swift
//  ChatX509
//
//  Created on 17.01.2026.
//

import SwiftUI

struct DebugView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    
    @State private var stats: MulticastService.DebugStats?
    @State private var timer: Timer?
    
    var body: some View {
        AnyNavigationStack {
            List {
                Section(header: Text("Multicast Diagnostic")) {
                    if let stats = stats {
                        statRow(label: "Status", value: stats.isRunning ? "Running" : "Stopped", color: stats.isRunning ? .green : .red)
                        statRow(label: "Interface IP", value: stats.interfaceAddress)
                        statRow(label: "RX FD", value: "\(stats.receiveSocketFD)")
                        statRow(label: "TX FD", value: "\(stats.sendSocketFD)")
                        statRow(label: "Listeners", value: "\(stats.activeListeners)")
                    } else {
                        Text("Loading stats...")
                    }
                }
                
                Section(header: Text("Traffic")) {
                    if let stats = stats {
                        statRow(label: "Total Sent", value: ByteCountFormatter.string(fromByteCount: Int64(stats.totalBytesSent), countStyle: .file))
                        statRow(label: "Total Received", value: ByteCountFormatter.string(fromByteCount: Int64(stats.totalBytesReceived), countStyle: .file))
                        statRow(label: "Transctions Processed", value: "\(stats.processedTransactionsCount)")
                    }
                }
                
                Section(header: Text("Queues (Reliability)")) {
                    if let stats = stats {
                        statRow(label: "Pending Assembly", value: "\(stats.pendingMessagesCount)")
                        statRow(label: "Sent Cache", value: "\(stats.sentMessagesCacheCount)")
                    }
                }
                
                Section(header: Text("Local Identity")) {
                    statRow(label: "Username", value: CertificateManager.shared.username)
                    statRow(label: "Serial", value: CertificateManager.shared.currentCertificate?.toBeSigned.serialNumber.map { String(format: "%02X", $0) }.joined() ?? "N/A")
                    statRow(label: "Private Key", value: CertificateManager.shared.currentPrivateKey != nil ? "Available" : "Missing", color: CertificateManager.shared.currentPrivateKey != nil ? .green : .red)
                }
                
                Section {
                     Button("Refresh Metrics") {
                         fetchStats()
                     }
                }
            }
            .navigationTitle("Developer Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                fetchStats()
                // Auto refresh every second
                timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                    fetchStats()
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
        }
    }
    
    private func fetchStats() {
        Task {
            let s = await MulticastService.shared.getDebugStats()
            await MainActor.run {
                self.stats = s
            }
        }
    }
    
    private func statRow(label: String, value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(color)
        }
    }
}

#Preview {
    DebugView()
}
