import SwiftUI
import UIKit

/// A planned meal's picture: the recipe's photo, or the restaurant's logo on a white tile when
/// eating out. Without either (or while it loads, or offline), BigTable's fork and knife on its
/// red.
struct MealArtwork: View {
    var meal: HearthMealPlan.Meal
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let url = meal.artworkURL {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        if meal.isDineOut {
                            logo(image)
                        } else {
                            image.resizable().scaledToFill()
                        }
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Logos are small and square: centered on white, with room around them.
    private func logo(_ image: Image) -> some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * 0.62
            ZStack {
                Color.white
                image.resizable().interpolation(.high).scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(.rect(cornerRadius: side * 0.18, style: .continuous))
            }
        }
    }

    private var placeholder: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [HearthLink.bigTableColor.mix(with: .white, by: 0.12), HearthLink.bigTableColor.mix(with: .black, by: 0.25)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: meal.symbol)
                    .font(.system(size: max(min(proxy.size.width, proxy.size.height) * 0.36, 10), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }
}

/// Tonight's dinner from BigTable on Home: its photo (or the restaurant's logo) large, the
/// name over it, and the day's other meals underneath. Tapping opens it in BigTable. Shows
/// nothing when BigTable hasn't planned today.
struct DinnerTonightCard: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var link: HearthLink { HearthLink.shared }

    var body: some View {
        let meals = link.meals(on: .now)
        let dinner = meals.first { $0.slot == "dinner" }
        let others = meals.filter { $0.slot != "dinner" }
        if dinner != nil || !others.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(dinner != nil ? "Dinner Tonight" : "Meals Today")
                if let dinner {
                    Button { open(dinner) } label: { hero(dinner) }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Dinner tonight: \(dinner.title)")
                        .accessibilityHint("Opens in BigTable")
                }
                if !others.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(others) { meal in
                            Button { open(meal) } label: { compact(meal) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens in BigTable")
                        }
                    }
                }
            }
        }
    }

    private func open(_ meal: HearthMealPlan.Meal) {
        if let url = meal.openURL { openURL(url) }
    }

    // MARK: Dinner

    private func hero(_ meal: HearthMealPlan.Meal) -> some View {
        let height: CGFloat = sizeClass == .regular ? 220 : 180
        return ZStack(alignment: .bottomLeading) {
            if meal.isDineOut {
                dineOutBackdrop(meal)
            } else {
                // In an overlay, so a tall photo fills the card instead of stretching it.
                Color.clear.overlay { MealArtwork(meal: meal, cornerRadius: 0) }
            }
            // Keeps the words readable on any photo.
            LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(meal.isDineOut ? "EATING OUT" : "FROM BIGTABLE")
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(meal.isDineOut ? (meal.placeName ?? meal.title) : meal.title)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let notEating = meal.notEatingLabel {
                        Text(notEating)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: Circle())
            }
            .padding(16)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
    }

    /// Eating out: BigTable's red with the restaurant's logo as a tile up top.
    private func dineOutBackdrop(_ meal: HearthMealPlan.Meal) -> some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [HearthLink.bigTableColor.mix(with: .white, by: 0.1), HearthLink.bigTableColor.mix(with: .black, by: 0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            MealArtwork(meal: meal, cornerRadius: 16)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(16)
        }
    }

    // MARK: Breakfast and lunch

    private func compact(_ meal: HearthMealPlan.Meal) -> some View {
        HStack(spacing: 10) {
            MealArtwork(meal: meal, cornerRadius: 10)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(meal.slotLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(meal.isDineOut ? (meal.placeName ?? meal.title) : meal.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
    }
}

/// A meal on the calendar's day list: its picture, the meal and what it is. Tapping opens it in
/// BigTable.
struct MealStrip: View {
    var meal: HearthMealPlan.Meal

    var body: some View {
        HStack(spacing: 10) {
            MealArtwork(meal: meal, cornerRadius: 8)
                .frame(width: 30, height: 30)
            Text(meal.isDineOut ? (meal.placeName ?? meal.title) : meal.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(meal.slotLabel)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .opacity(0.85)
        }
        .foregroundStyle(HearthLink.bigTableColor.mix(with: .primary, by: 0.25))
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(minHeight: 42)
        .background(HearthLink.bigTableColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }
}
