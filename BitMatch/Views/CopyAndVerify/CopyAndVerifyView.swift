// Views/CopyAndVerify/CopyAndVerifyView.swift
import SwiftUI

/// The Mac Copy & Verify workspace: Setup remains visible while the transfer
/// list beneath its composer carries live progress and final verdicts.
struct CopyAndVerifyView: View {
    @ObservedObject var coordinator: SharedAppCoordinator
    @Binding var optionsExpanded: Bool

    var body: some View {
        MacSetupView(coordinator: coordinator, optionsExpanded: $optionsExpanded)
    }
}
