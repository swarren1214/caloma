import SwiftUI

/// Kids Today: a ring for each kid filling as their jobs get done, and how many things need
/// your OK.
struct KidsPage: View {
    @Environment(PhoneLink.self) private var link
    var showApprovals: () -> Void

    var body: some View {
        let snapshot = link.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                PageLabel(title: "Kids today", color: .accentColor)
                if snapshot.kids.isEmpty {
                    Text("Add kids in Caloma on your iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 10) {
                        ForEach(snapshot.kids) { kid in
                            KidRing(kid: kid, snapshot: snapshot)
                        }
                    }
                }
                if snapshot.needsOKCount > 0 {
                    Button(action: showApprovals) {
                        Label("\(snapshot.needsOKCount) need\(snapshot.needsOKCount == 1 ? "s" : "") your OK", systemImage: "checkmark.shield.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .navigationTitle("Kids")
        .containerBackground(Color.accentColor.gradient.opacity(0.25), for: .tabView)
    }
}

private struct KidRing: View {
    var kid: WatchSnapshot.Kid
    var snapshot: WatchSnapshot

    var body: some View {
        let color = Color(rgb: kid.color)
        let fraction = kid.total == 0 ? 1 : Double(kid.done) / Double(kid.total)
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.25), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if kid.total > 0 && kid.done >= kid.total {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                } else {
                    Text("\(kid.done)/\(kid.total)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: 46, height: 46)
            Text(kid.name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kid.name), \(kid.done) of \(kid.total) jobs done, \(snapshot.points(kid.balance))")
    }
}
