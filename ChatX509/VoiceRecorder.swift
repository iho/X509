//
//  VoiceRecorder.swift
//  ChatX509
//
//  Created on 16.01.2026.
//

import Foundation
import AVFoundation
import Combine

@MainActor
class VoiceRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var recordingTime: TimeInterval = 0
    @Published var permissionGranted = false
    
    private var audioRecorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    
    override init() {
        super.init()
        checkPermission()
    }
    
    func checkPermission() {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            permissionGranted = true
        case .denied:
            permissionGranted = false
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                Task { @MainActor in
                    self.permissionGranted = allowed
                }
            }
        @unknown default:
            permissionGranted = false
        }
    }
    
    func startRecording() {
        guard permissionGranted else { return }
        
        let recordingSession = AVAudioSession.sharedInstance()
        
        do {
            try recordingSession.setCategory(.playAndRecord, mode: .default)
            try recordingSession.setActive(true)
            
            let fileName = "voice_msg_\(Date().timeIntervalSince1970).m4a"
            let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let audioFilename = docPath.appendingPathComponent(fileName)
            recordingURL = audioFilename
            
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 12000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            
            isRecording = true
            recordingTime = 0
            
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                Task { @MainActor in
                    self.recordingTime += 0.1
                }
            }
            
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
    
    func stopRecording() -> (URL, TimeInterval)? {
        audioRecorder?.stop()
        timer?.invalidate()
        isRecording = false
        
        let duration = recordingTime
        recordingTime = 0
        
        guard let url = recordingURL else { return nil }
        return (url, duration)
    }
    
    func cancelRecording() {
        audioRecorder?.stop()
        timer?.invalidate()
        isRecording = false
        recordingTime = 0
        
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
