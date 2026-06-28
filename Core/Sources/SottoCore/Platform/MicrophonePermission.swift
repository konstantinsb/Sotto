import AVFoundation

/// Доступ к микрофону (TCC). Понятный текст запроса задаётся ключом
/// `NSMicrophoneUsageDescription` в Info.plist.
public enum MicrophonePermission {
    public static var status: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Гарантировать доступ: вернуть true, если уже выдан или пользователь согласился.
    public static func ensure() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
