import SwiftUI
import SwiftData

/// An adaptive grid that switches to an even number of equal columns while an iPhone Duo is
/// partly folded (Book or Laptop), so the fold falls between two columns instead of through a
/// card. Flat, it's the same `.adaptive(minimum:)` grid the screen always had.
struct DuoAdaptiveGrid<Content: View>: View {
    var minimum: CGFloat
    var spacing: CGFloat = 10
    /// Space between rows; the column spacing when nil.
    var rowSpacing: CGFloat?
    var alignment: HorizontalAlignment = .center
    /// Each cell's alignment, as `GridItem(alignment:)`.
    var itemAlignment: Alignment?
    /// One full-width column (a compact Kid View), whatever the pose.
    var single = false
    @ViewBuilder var content: () -> Content

    @Environment(\.hearthDuoPose) private var pose
    @State private var width: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: columns, alignment: alignment, spacing: rowSpacing ?? spacing) {
            content()
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
    }

    private var columns: [GridItem] {
        if single {
            return [GridItem(.flexible(), spacing: spacing, alignment: itemAlignment)]
        }
        guard pose.isFolded else {
            return [GridItem(.adaptive(minimum: minimum), spacing: spacing, alignment: itemAlignment)]
        }
        let count = HearthEvenColumns.count(for: width + spacing, minimumCellWidth: minimum + spacing)
        return Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: itemAlignment), count: count)
    }
}

/// A parent's tap on a chore's check, the same everywhere a parent sees the board: open → done
/// (approved), waiting → approved, done → undone.
enum ParentChoreTap {
    static func toggle(_ item: BoardItem, for memberID: UUID, completions: [ChoreCompletion], in context: ModelContext) {
        switch item.status {
        case .open:
            Family.markDone(item, by: memberID, byParent: true, in: context)
        case .pending:
            if let completion = completions.first(where: { $0.id == item.completionID }) {
                Family.approve(completion, in: context)
            }
        case .approved:
            if let completion = completions.first(where: { $0.id == item.completionID }) {
                Family.undo(completion, in: context)
            }
        }
    }
}
