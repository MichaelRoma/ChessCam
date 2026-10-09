import Photos

@MainActor
final class PhotoLibraryExporter {
    enum ExportError: LocalizedError {
        case accessDenied
        case assetCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Разрешите ChessCam добавлять видео в Фото в настройках iPhone."
            case .assetCreationFailed:
                return "Не удалось добавить видео в Фото."
            }
        }
    }

    func saveVideo(at url: URL) async throws {
        let status = await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
        guard status == .authorized || status == .limited else {
            throw ExportError.accessDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { saved, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if saved {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ExportError.assetCreationFailed)
                }
            }
        }
    }
}
