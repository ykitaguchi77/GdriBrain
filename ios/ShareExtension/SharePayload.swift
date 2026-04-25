import UIKit

enum SharePayload {
    case empty
    case memo(text: String)
    case link(url: String, title: String?)
    case screenshot(image: UIImage, ocrText: String)
}
