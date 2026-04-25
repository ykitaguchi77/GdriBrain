import UIKit
import Vision

enum OCRError: Error {
    case noCGImage
}

enum OCR {
    /// On-device VisionKit OCR. Free, private, and fast — the screenshot
    /// never leaves the phone unless the user confirms.
    static func recognise(image: UIImage) async throws -> String {
        guard let cg = image.cgImage else { throw OCRError.noCGImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ja-JP", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        try handler.perform([request])
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
