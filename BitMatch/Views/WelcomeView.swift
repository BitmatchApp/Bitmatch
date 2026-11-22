// Views/WelcomeView.swift - One-time welcome from the maintainer
import AppKit
import SwiftUI

/// The welcome panel's content: icon, a short personal note, and two buttons.
struct WelcomeView: View {
    let starOnGitHub: () -> Void
    let close: () -> Void

    static let size = CGSize(width: 440, height: 520)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                Text("Welcome to BitMatch 👋")
                    .font(.title2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)

            Text("BitMatch is a passion project. I'm a working film professional and I wanted reliable, verified card backups to be free for everyone.")

            Group {
                Text("It's a one-person project, and I can't test every camera, card, reader and drive out there. Before trusting it with real footage, please try it on non-essential files first, and keep your cards until you've confirmed your backups.")
                Text("Found a bug or have an idea? Open an issue on GitHub. Want to contribute? Please do. And if BitMatch is useful to you, a star helps other filmmakers find it.")
                Text("Thanks for giving it a shot! 👋 Mike")
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Star on GitHub", action: starOnGitHub)
                Button("Close", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .preferredColorScheme(.dark)
    }
}
