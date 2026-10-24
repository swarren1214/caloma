import SwiftData
import SwiftUI

/// Who to call: the Family Boards (one, or all of them at once) and the family's phones and
/// iPads (woken by push when Caloma isn't open on them). From the Home tab on a phone, and the Intercom button on the board's rail.
struct IntercomSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accent) private var accent
    @Query(sort: \HouseDevice.createdAt) private var devices: [HouseDevice]
    @Query(sort: \Room.sortOrder) private var rooms: [Room]
    @State private var service = IntercomService.shared
    @State private var center = CallCenter.shared

    private var others: [HouseDevice] {
        devices.filter { $0.id != DeviceIdentity.id && $0.takesCalls }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
    private var boards: [HouseDevice] { others.filter(\.isBoard) }
    private var phones: [HouseDevice] { others.filter { !$0.isBoard } }
    private var boardsHome: [HouseDevice] { boards.filter { service.isOnline($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                if service.networkDenied {
                    LocalNetworkOffSection()
                }
                if !center.missed.isEmpty {
                    Section {
                        ForEach(center.missed) { call in
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(call.name)
                                        Text(call.at.formatted(date: .omitted, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "phone.arrow.down.left")
                                }
                                .foregroundStyle(.red)
                                .tint(.red)
                                Spacer()
                                Button("Call Back") { start { await center.callBack(call) } }
                                    .buttonStyle(.bordered)
                            }
                            .swipeActions {
                                Button("Clear", role: .destructive) { center.forget(call) }
                            }
                        }
                    } header: {
                        Text("Missed")
                    }
                }

                if boards.count > 1 {
                    Section {
                        Button {
                            start { await center.call(boardsHome, video: true) }
                        } label: {
                            Label("Call All Boards", systemImage: "rectangle.3.group.fill")
                                .font(.headline)
                                .tint(.primary)
                        }
                        .disabled(boardsHome.isEmpty)
                    } footer: {
                        Text("Every Family Board at home rings. Whoever picks up joins the call.")
                    }
                }

                Section {
                    if boards.isEmpty {
                        Text("No Family Boards yet. Start the Family Board on an iPad and it shows up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(boards) { device in
                        row(device)
                    }
                } header: {
                    Text("Family Boards")
                }

                if !phones.isEmpty {
                    Section {
                        ForEach(phones) { device in
                            row(device)
                        }
                    } header: {
                        Text("Phones and iPads")
                    } footer: {
                        Text("Phones and iPads ring even when they're locked, as long as they're at home on the same Wi-Fi. Calls from away from home come next.")
                    }
                }
            }
            .navigationTitle("Intercom")
            .navigationBarTitleDisplayMode(.inline)
            // The text color for Done, Call Back and the rest, whatever tint the sheet was opened
            // with (white over the app's color on Home). Only the video button is the app's color.
            .tint(.primary)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Can't Call", isPresented: Binding(get: { center.problem != nil }, set: { if !$0 { center.problem = nil } })) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(center.problem ?? "")
            }
        }
    }

    private func row(_ device: HouseDevice) -> some View {
        let online = service.isOnline(device.id)
        let room = device.roomID.flatMap { id in rooms.first { $0.id == id } }
        return HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                    Text([room?.name, online ? "Available" : "Rings if it's home"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(online ? Color.green : Color.secondary)
                }
            } icon: {
                Image(systemName: device.symbol)
            }
            .tint(.primary)
            Spacer()
            // Colors set here, not inherited: the sheet opens from toolbars tinted white over the
            // app's color, which made the filled video button a blank white circle.
            Button {
                start { await center.call([device], video: false) }
            } label: {
                Image(systemName: "phone.fill")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .accessibilityLabel("Audio call \(device.displayName)")
            Button {
                start { await center.call([device], video: true) }
            } label: {
                Image(systemName: "video.fill")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(accent)
            .accessibilityLabel("Video call \(device.displayName)")
        }
    }

    /// Starts the call (its screen opens over everything), then closes this sheet once it's ringing.
    private func start(_ work: @escaping @MainActor () async -> Void) {
        Task {
            await work()
            if center.state.isBusy { dismiss() }
        }
    }
}

/// The intercom button for toolbars: opens the intercom, with a red dot for missed calls.
struct IntercomButton: View {
    @State private var showing = false
    @State private var center = CallCenter.shared

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "phone.bubble.fill")
                .overlay(alignment: .topTrailing) {
                    if !center.missed.isEmpty {
                        Circle().fill(.red).frame(width: 9, height: 9).offset(x: 3, y: -3)
                    }
                }
        }
        .accessibilityLabel(center.missed.isEmpty ? "Intercom" : "Intercom, \(center.missed.count) missed")
        .sheet(isPresented: $showing) {
            IntercomSheet()
        }
    }
}
