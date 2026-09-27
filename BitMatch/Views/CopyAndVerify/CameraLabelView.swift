import SwiftUI
import BitMatchEngine

// MARK: - Camera Label Configuration View
struct CameraLabelView: View {
    @Binding var settings: CameraLabelSettings
    var sourceURL: URL? = nil
    
    var body: some View {
        CameraLabelEditor(settings: $settings, sourceURL: sourceURL)
    }
}
