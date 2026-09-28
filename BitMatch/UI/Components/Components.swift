// UI/Components/Components.swift
import SwiftUI

// MARK: - Custom Button Style
struct CustomButtonStyle: ButtonStyle {
    var isDestructive: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isDestructive ? .red : .white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isDestructive ? Color.red.opacity(0.15) : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isDestructive ? Color.red.opacity(0.3) : Color.white.opacity(0.2),
                        lineWidth: 0.5
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// The one high-emphasis action treatment used when BitMatch is ready to proceed.
struct PrimaryActionButtonStyle: ButtonStyle {
    var isEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(isEnabled ? .black : .white.opacity(0.45))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 42)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isEnabled ? Color.green : Color.white.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Color.white.opacity(isEnabled ? 0.11 : 0.06), lineWidth: 0.5)
            )
            .shadow(color: isEnabled ? Color.green.opacity(configuration.isPressed ? 0.12 : 0.22) : .clear, radius: 9, y: 3)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.75)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
