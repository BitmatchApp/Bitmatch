import SwiftUI

enum InterfaceLabRoute: String, CaseIterable, Identifiable {
    case welcome = "Welcome"
    case setup = "Setup"
    case transfer = "Transfer"
    case evidence = "Evidence"
    case issues = "Issues"
    case compare = "Compare"
    case report = "Report"
    case settings = "Settings"

    var id: String { rawValue }

    static func next(after route: InterfaceLabRoute) -> InterfaceLabRoute {
        switch route {
        case .welcome: .setup
        case .setup: .transfer
        case .transfer: .evidence
        case .evidence, .issues, .compare, .report, .settings: .setup
        }
    }
}

/// A no-I/O visual harness. Launch with `--interface-lab` to review the complete UX safely.
struct InterfaceLabView: View {
    private enum RouteEndpoint: Equatable {
        case source
        case destinations

        var title: String {
            switch self {
            case .source: "source"
            case .destinations: "destinations"
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var route: InterfaceLabRoute = .welcome
    @State private var usesProjectWorkflow = true
    @State private var transferPhase = "Copying"
    @State private var progress = 0.62
    @State private var remoteQueued = false
    @State private var showingDestinationEditor = false
    @State private var syntheticDestinationSaved = false
    @State private var connectionTested = false
    @State private var destinationName = "Post-production archive"
    @State private var destinationHost = "archive.studio.example"
    @State private var destinationRoot = "Projects/2026"
    @State private var handoffRecordReady = false
    @State private var selectedRouteEndpoint: RouteEndpoint?
    @State private var sourceValue = "A_CAM · CARD 003"
    @State private var sourceDetail = "486 files · 218.4 GB"
    @State private var backupValue = "2 local + 1 off-site"
    @State private var backupDetail = "Primary, safety, and cloud evidence"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.09))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    navigation
                    content
                        .id(route)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
                }
                .padding(22)
                .frame(maxWidth: 980, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(red: 0.09, green: 0.10, blue: 0.12), Color(red: 0.035, green: 0.04, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: route)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: selectedRouteEndpoint)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: usesProjectWorkflow)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: transferPhase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: remoteQueued)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showingDestinationEditor)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: handoffRecordReady)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 17, weight: .semibold)).foregroundColor(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("BitMatch").font(.system(size: 17, weight: .bold))
                Text("INTERFACE LAB · NO FILE ACCESS").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundColor(.white.opacity(0.48))
            }
            Spacer()
            Text("Synthetic data only").font(.system(size: 10, weight: .medium)).foregroundColor(.green.opacity(0.86))
                .padding(.horizontal, 9).padding(.vertical, 5).background(Capsule().fill(Color.green.opacity(0.12)))
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var navigation: some View {
        GeometryReader { proxy in
            if InterfaceLabNavigationPolicy.presentation(for: proxy.size.width) == .segmented {
                Picker("", selection: $route) {
                    ForEach(InterfaceLabRoute.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(InterfaceLabCopy.navigationLabel)
            } else {
                HStack(spacing: 8) {
                    Text("PREVIEW")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.white.opacity(0.46))
                    Spacer()
                    Menu {
                        ForEach(InterfaceLabRoute.allCases) { route in
                            Button {
                                self.route = route
                            } label: {
                                Label(route.rawValue, systemImage: route.symbol)
                            }
                        }
                    } label: {
                        Label(route.rawValue, systemImage: route.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel(InterfaceLabCopy.navigationLabel)
                    .accessibilityValue(route.rawValue)
                }
            }
        }
        .frame(height: 32)
    }

    @ViewBuilder private var content: some View {
        switch route {
        case .welcome: welcome
        case .setup: setup
        case .transfer: transfer
        case .evidence: evidence
        case .issues: issues
        case .compare: compare
        case .report: report
        case .settings: settings
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ready when the media is.")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("BitMatch stays quiet until you choose a card or folder. There is nothing to configure before the first safe copy.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "camera.badge.ellipsis").font(.system(size: 24)).foregroundColor(.orange)
                    Text("A card or folder goes here").font(.system(size: 13, weight: .semibold))
                    Text("Connect media, or choose any source when you are ready.").font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "checkmark.shield").font(.system(size: 24)).foregroundColor(.green)
                    Text("Nothing is copied yet").font(.system(size: 13, weight: .semibold))
                    Text("The interface lab uses synthetic media only and never opens a file picker.").font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel()
            }
            HStack(spacing: 10) {
                Button { route = .setup } label: {
                    Label("Preview a transfer", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Button("Review destinations") { route = .settings }
                    .buttonStyle(CustomButtonStyle())
            }
            Text("This is the synthetic interface lab. No cards, drives, credentials, or network services are accessed.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.42))
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(InterfaceLabCopy.setupTitle, detail: "Review the source and destination route before anything starts.")
            HStack(alignment: .top, spacing: 12) {
                Button { toggleRouteEndpoint(.source) } label: {
                    routeCard(title: "SOURCE", value: sourceValue, detail: sourceDetail, icon: "camera.fill", tint: .orange, actionTitle: "Change", selected: selectedRouteEndpoint == .source)
                }
                .buttonStyle(.plain)
                Image(systemName: "arrow.right").padding(.top, 46).foregroundColor(.white.opacity(0.36))
                Button { toggleRouteEndpoint(.destinations) } label: {
                    routeCard(title: "DESTINATIONS", value: backupValue, detail: backupDetail, icon: "externaldrive.fill", tint: .blue, actionTitle: "Change", selected: selectedRouteEndpoint == .destinations)
                }
                .buttonStyle(.plain)
            }
            if let selectedRouteEndpoint {
                routeEditor(for: selectedRouteEndpoint)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            HStack(spacing: 10) {
                workflowButton(TransferWorkflowPresentation.quick.title, detail: TransferWorkflowPresentation.quick.detail, selected: !usesProjectWorkflow) { usesProjectWorkflow = false }
                workflowButton(TransferWorkflowPresentation.project.title, detail: TransferWorkflowPresentation.project.detail, selected: usesProjectWorkflow) { usesProjectWorkflow = true }
            }
            if usesProjectWorkflow {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Project setup").font(.system(size: 13, weight: .semibold)); Spacer(); Text("PHOTO WORKFLOW").font(.system(size: 9, weight: .bold)).foregroundColor(.green) }
                    HStack(spacing: 8) { field("Client", value: "Acme Studio"); field("Job", value: "Summer campaign"); field("Camera", value: "Sony A7 IV") }
                    Label("Acme Studio / Summer campaign / A_CAM / Card 003", systemImage: "folder.badge.gearshape")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.66))
                }.panel()
            }
            Button { route = InterfaceLabRoute.next(after: route) } label: { Label("Review transfer", systemImage: "arrow.right") .frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private var transfer: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Transfer progress", detail: "The only controls you need stay visible while the proof accumulates.")
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label(transferPhase, systemImage: transferPhase == "Verifying" ? "checkmark.shield.fill" : (transferPhase == "Paused" ? "pause.circle.fill" : "arrow.right.circle.fill")).font(.system(size: 15, weight: .semibold)).foregroundColor(transferPhase == "Paused" ? .orange : .green); Spacer(); Text("A_CAM → 3 destinations").font(.system(size: 11)).foregroundColor(.white.opacity(0.6)) }
                ProgressView(value: progress).tint(.green)
                HStack { Text("\(Int(progress * 100))% complete · 302 of 486 files").font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.7)); Spacer(); Text("1.2 GB/s · 04:18 left").font(.system(size: 11, design: .monospaced)).foregroundColor(.white.opacity(0.55)) }
                Slider(value: $progress, in: 0...1).tint(.green)
                HStack { Button(transferPhase == "Paused" ? "Resume" : "Pause") { transferPhase = transferPhase == "Paused" ? "Copying" : "Paused" }.buttonStyle(CustomButtonStyle()); Button("Cancel") { route = .issues }.buttonStyle(CustomButtonStyle(isDestructive: true)); Spacer(); Text("DSC_0417.ARW").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.46)) }
            }.panel()
            Button { route = InterfaceLabRoute.next(after: route) } label: { Label("Show completed evidence", systemImage: "checkmark.circle") .frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryActionButtonStyle())
        }
    }

    private var evidence: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Evidence, not ceremony", detail: "Your project stays visible after the transfer, with the next safety step in context.")
            HStack(spacing: 12) { Image(systemName: "checkmark.seal.fill").font(.system(size: 38)).foregroundColor(.green); VStack(alignment: .leading) { Text("3 verified copies are safe").font(.system(size: 17, weight: .semibold)); Text("486 files · 218.4 GB · SHA-256 verified").font(.system(size: 11)).foregroundColor(.white.opacity(0.6)) }; Spacer() }.panel()
            VStack(alignment: .leading, spacing: 8) { HStack { Text("Project media").font(.system(size: 13, weight: .semibold)); Spacer(); Text(remoteQueued ? "OFF-SITE QUEUED" : "LOCAL COPIES SAFE").font(.system(size: 9, weight: .bold)).foregroundColor(remoteQueued ? .green : .white.opacity(0.48)) }; evidenceRow("A_CAM · Card 003", detail: "486 files · 218.4 GB · 3 of 3 verified", status: "Locally Safe"); evidenceRow("B_CAM · Card 001", detail: "312 files · 119.8 GB · 3 of 3 verified", status: "Locally Safe"); Button(remoteQueued ? "Off-site backup queued" : "Queue off-site backup") { remoteQueued.toggle() }.buttonStyle(CustomButtonStyle()).disabled(remoteQueued) }.panel()
            Button("Start next transfer") { route = InterfaceLabRoute.next(after: route) }.buttonStyle(CustomButtonStyle())
        }
    }

    private var compare: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(InterfaceLabCopy.compareTitle, detail: "Check two folders and see exactly whether they agree.")
            HStack(alignment: .top, spacing: 12) {
                routeCard(title: "REFERENCE", value: "PRIMARY / A_CAM", detail: "486 files · 218.4 GB", icon: "folder.fill", tint: .blue)
                Image(systemName: "arrow.left.arrow.right").padding(.top, 46).foregroundColor(.white.opacity(0.36))
                routeCard(title: "CHECK", value: "SAFETY / A_CAM", detail: "486 files · 218.4 GB", icon: "folder.badge.checkmark", tint: .green)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Folders match", systemImage: "checkmark.shield.fill").font(.system(size: 15, weight: .semibold)).foregroundColor(.green)
                    Spacer()
                    Text("SHA-256 · completed 14:32").font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.52))
                }
                HStack(spacing: 8) {
                    compareMetric("486", "matched", tint: .green)
                    compareMetric("0", "missing", tint: .white.opacity(0.72))
                    compareMetric("0", "changed", tint: .white.opacity(0.72))
                }
                Text("No action needed. This comparison is ready for the job record.")
                    .font(.system(size: 11)).foregroundColor(.white.opacity(0.62))
            }.panel()
            Button("Compare another pair") { route = .setup }.buttonStyle(CustomButtonStyle())
        }
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Nothing is hidden", detail: "BitMatch stops before calling a transfer safe, and gives you the smallest useful next step.")
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("1 file needs attention").font(.system(size: 17, weight: .semibold))
                    Text("485 files were copied and verified before the interruption.").font(.system(size: 11)).foregroundColor(.white.opacity(0.62))
                }
                Spacer()
            }.panel()
            VStack(alignment: .leading, spacing: 9) {
                HStack { Text("Action required").font(.system(size: 13, weight: .semibold)); Spacer(); Text("NOT SAFE YET").font(.system(size: 9, weight: .bold)).foregroundColor(.orange) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("DSC_0417.ARW").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    Text("Copy stopped while writing the safety drive. The existing verified copies remain untouched.").font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
                HStack { Button("Resume safely") { route = .transfer; transferPhase = "Copying" }.buttonStyle(CustomButtonStyle()); Button("Start over") { route = .setup }.buttonStyle(CustomButtonStyle(isDestructive: true)); Spacer() }
            }.panel()
        }
    }

    private var report: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("The day, in one glance", detail: "A compact handoff record that says exactly what became safe and where.")
            HStack(spacing: 12) {
                reportMetric("2", "cards secured", icon: "camera.fill", tint: .orange)
                reportMetric("798", "files verified", icon: "checkmark.shield.fill", tint: .green)
                reportMetric("338.2 GB", "protected", icon: "externaldrive.fill", tint: .blue)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Today’s verified transfers").font(.system(size: 13, weight: .semibold)); Spacer(); Text("JUL 16 · 2026").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.46)) }
                reportRow("A_CAM · Card 003", detail: "3 verified copies · 218.4 GB", state: "Safe")
                reportRow("B_CAM · Card 001", detail: "3 verified copies · 119.8 GB", state: "Safe")
            }.panel()
            if handoffRecordReady {
                Label("Handoff record ready · PDF + JSON", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.green.opacity(0.09)))
            }
            HStack {
                Button(handoffRecordReady ? "Handoff record generated" : "Generate handoff record") {
                    handoffRecordReady = true
                }
                .buttonStyle(PrimaryActionButtonStyle())
                Spacer()
                Text("PDF + JSON · synthetic preview").font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Saved destinations", detail: "Manage reusable destination locations once; choose them quickly on set.")
            ForEach(syntheticDestinations, id: \.0) { profile in
                HStack {
                    Image(systemName: profile.1.contains("SFTP") ? "network" : "externaldrive.fill")
                        .foregroundColor(profile.1.contains("SFTP") ? .green : .blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.0).font(.system(size: 13, weight: .semibold))
                        Text(profile.1).font(.system(size: 11)).foregroundColor(.white.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
                }
                .panel()
            }
            if showingDestinationEditor { destinationEditor }
            Button(showingDestinationEditor ? "Cancel" : "Add destination") {
                showingDestinationEditor.toggle()
                connectionTested = false
            }
            .buttonStyle(CustomButtonStyle())
        }
    }

    private var syntheticDestinations: [(String, String)] {
        var profiles = [
            ("Primary shuttle", "Local SSD · /Volumes/T7"),
            ("Off-site archive", "SFTP · archive.acme.studio"),
            ("Client safety", "Local SSD · /Volumes/Client")
        ]
        if syntheticDestinationSaved {
            profiles.append((destinationName, "SFTP · \(destinationHost) · /\(destinationRoot)"))
        }
        return profiles
    }

    private var destinationEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Add SFTP destination").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("SYNTHETIC").font(.system(size: 9, weight: .bold)).foregroundColor(.green)
            }
            Text("Credentials stay outside BitMatch; this preview only shows the reusable location record.")
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
            TextField("Destination name", text: $destinationName).textFieldStyle(.roundedBorder)
            TextField("Host", text: $destinationHost).textFieldStyle(.roundedBorder)
            TextField("Relative root", text: $destinationRoot).textFieldStyle(.roundedBorder)
            HStack {
                Button(connectionTested ? "Connection verified" : "Test connection") { connectionTested = true }
                    .buttonStyle(CustomButtonStyle())
                Spacer()
                Button("Save destination") {
                    syntheticDestinationSaved = true
                    showingDestinationEditor = false
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
            if connectionTested {
                Label("Synthetic SSH-agent connection verified", systemImage: "checkmark.shield.fill")
                    .font(.system(size: 10)).foregroundColor(.green)
            }
        }
        .panel()
    }

    private func toggleRouteEndpoint(_ endpoint: RouteEndpoint) {
        selectedRouteEndpoint = selectedRouteEndpoint == endpoint ? nil : endpoint
    }

    private func routeEditor(for endpoint: RouteEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Change \(endpoint.title)", systemImage: endpoint == .source ? "camera.fill" : "externaldrive.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { selectedRouteEndpoint = nil }
                    .buttonStyle(CustomButtonStyle())
            }
            Text("Synthetic selections only — the interface lab never opens a card, drive, or file picker.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.58))
            if endpoint == .source {
                HStack(spacing: 8) {
                    routeChoice("A_CAM · CARD 003", detail: "486 files · 218.4 GB") {
                        sourceValue = "A_CAM · CARD 003"
                        sourceDetail = "486 files · 218.4 GB"
                    }
                    routeChoice("B_CAM · CARD 001", detail: "312 files · 119.8 GB") {
                        sourceValue = "B_CAM · CARD 001"
                        sourceDetail = "312 files · 119.8 GB"
                    }
                }
            } else {
                HStack(spacing: 8) {
                    routeChoice("2 local + 1 off-site", detail: "Primary, safety, and cloud evidence") {
                        backupValue = "2 local + 1 off-site"
                        backupDetail = "Primary, safety, and cloud evidence"
                    }
                    routeChoice("2 local destinations", detail: "Primary and safety drives") {
                        backupValue = "2 local destinations"
                        backupDetail = "Primary and safety drives"
                    }
                }
            }
        }
        .panel()
    }

    private func routeChoice(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            selectedRouteEndpoint = nil
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.2)))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 19, weight: .bold)); Text(detail).font(.system(size: 12)).foregroundColor(.white.opacity(0.62)) } }
    private func routeCard(title: String, value: String, detail: String, icon: String, tint: Color, actionTitle: String? = nil, selected: Bool = false) -> some View { VStack(alignment: .leading, spacing: 7) { HStack { Label(title, systemImage: icon).font(.system(size: 9, weight: .bold)).tracking(1).foregroundColor(tint); Spacer(); if let actionTitle { Label(actionTitle, systemImage: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.62)) } }; Text(value).font(.system(size: 14, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundColor(.white.opacity(0.58)) }.frame(maxWidth: .infinity, alignment: .leading).panel().overlay(RoundedRectangle(cornerRadius: 13).stroke(selected ? tint.opacity(0.65) : .clear, lineWidth: 1)) }
    private func workflowButton(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundColor(.green) }
                }
                Text(detail).font(.system(size: 10)).foregroundColor(.white.opacity(0.58))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(selected ? Color.green.opacity(0.12) : Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.green.opacity(0.4) : Color.white.opacity(0.09)))
            )
        }
        .buttonStyle(.plain)
    }
    private func field(_ title: String, value: String) -> some View { VStack(alignment: .leading, spacing: 4) { Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.45)); Text(value).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.22))) }.frame(maxWidth: .infinity) }
    private func evidenceRow(_ name: String, detail: String, status: String) -> some View { HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(.green); VStack(alignment: .leading) { Text(name).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundColor(.white.opacity(0.58)) }; Spacer(); Text(status).font(.system(size: 9, weight: .bold)).foregroundColor(.green) }.padding(9).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2))) }
    private func compareMetric(_ value: String, _ label: String, tint: Color) -> some View { VStack(alignment: .leading, spacing: 2) { Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(tint); Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.48)) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.2))) }
    private func reportMetric(_ value: String, _ label: String, icon: String, tint: Color) -> some View { VStack(alignment: .leading, spacing: 6) { Image(systemName: icon).foregroundColor(tint); Text(value).font(.system(size: 19, weight: .bold, design: .rounded)); Text(label.uppercased()).font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.48)) }.frame(maxWidth: .infinity, alignment: .leading).panel() }
    private func reportRow(_ name: String, detail: String, state: String) -> some View { HStack { VStack(alignment: .leading, spacing: 2) { Text(name).font(.system(size: 12, weight: .semibold)); Text(detail).font(.system(size: 10)).foregroundColor(.white.opacity(0.58)) }; Spacer(); Label(state, systemImage: "checkmark.circle.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.green) }.padding(9).background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.2))) }
}

private extension View { func panel() -> some View { padding(14).background(RoundedRectangle(cornerRadius: 13).fill(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.09)))) } }

private extension InterfaceLabRoute {
    var symbol: String {
        switch self {
        case .welcome: "sparkles"
        case .setup: "slider.horizontal.3"
        case .transfer: "arrow.right.circle"
        case .evidence: "checkmark.seal"
        case .issues: "exclamationmark.triangle"
        case .compare: "arrow.left.arrow.right"
        case .report: "doc.text"
        case .settings: "gearshape"
        }
    }
}
