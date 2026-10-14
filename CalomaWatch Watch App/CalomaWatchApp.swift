import SwiftUI

/// Caloma on a parent's Apple Watch: what needs your OK, what's coming up, how the kids are
/// doing today and the home care that's due. The iPhone sends it all (`PhoneLink`).
@main
struct CalomaWatchApp: App {
    @State private var link = PhoneLink.shared

    init() {
        PhoneLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(link)
        }
    }
}

enum WatchPage: String, Hashable {
    case approvals, comingUp = "comingup", kids, homeCare = "homecare"
}

/// The pages, one above the other: turn the crown to move between them. Opens on Needs Your
/// OK when something's waiting, otherwise on Coming Up.
struct WatchRootView: View {
    @Environment(PhoneLink.self) private var link
    @State private var page: WatchPage = PhoneLink.shared.snapshot.approvals.isEmpty ? .comingUp : .approvals

    var body: some View {
        NavigationStack {
            if link.hasData {
                TabView(selection: $page) {
                    ApprovalsPage().tag(WatchPage.approvals)
                    ComingUpPage().tag(WatchPage.comingUp)
                    KidsPage { page = .approvals }.tag(WatchPage.kids)
                    HomeCarePage().tag(WatchPage.homeCare)
                }
                .tabViewStyle(.verticalPage)
            } else {
                WaitingForPhone()
            }
        }
        .tint(Color(rgb: link.snapshot.accent))
        // From a complication or Smart Stack widget: caloma://comingup and so on.
        .onOpenURL { url in
            if let target = WatchPage(rawValue: url.host() ?? "") { page = target }
        }
        // From tapping a "Needs your OK" notification.
        .onChange(of: link.requestedPage) { _, requested in
            guard let requested else { return }
            page = requested
            link.requestedPage = nil
        }
    }
}

private struct WaitingForPhone: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("Open Caloma on your iPhone")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("Your family shows up here once it's set up there.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// The small header over each page: "NEEDS YOUR OK", in the page's color.
struct PageLabel: View {
    var title: String
    var color: Color

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A kid's initial in their color, where a photo would be on the phone.
struct InitialBadge: View {
    var name: String
    var color: Color
    var size: CGFloat = 30

    var body: some View {
        Text(name.prefix(1))
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The big check (or arrow) after a tap, as in the design.
struct ResultBadge: View {
    var symbol: String
    var color: Color
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(color, in: Circle())
                .transition(.scale.combined(with: .opacity))
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
