import SwiftUI

struct DiaryEntryActionButton: View {
    @Environment(MealSession.self) private var meal
    @Environment(DiaryStore.self) private var store
    @State private var choosingDraft = false
    let day: Day
    var body: some View {
        content
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $choosingDraft) {
            NavigationStack {
                List {
                    ForEach(meal.drafts) { value in
                        Button {
                            UsageTelemetry.shared.action("MealDraft.select")
                            choosingDraft = false
                            Task { await meal.resume(value.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(value.meal.title + " · " + value.day.title(relativeTo: store.today))
                                Text(value.rows.isEmpty ? "Пустой черновик" : value.rows.map(\.displayName).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.tint(.primary).accessibilityIdentifier("mealDraft_" + value.id.uuidString)
                    }
                }.navigationTitle("Черновики еды")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") {
                    UsageTelemetry.shared.action("MealDraft.closeList"); choosingDraft = false
                } } }
            }
        }
    }
    @ViewBuilder private var content: some View {
        if let draft = meal.draft {
            HStack(spacing: 0) {
                Button { UsageTelemetry.shared.action("MealDraftAccessory.button.25");
                    if meal.drafts.count > 1 { choosingDraft = true } else { Task { await meal.resume(draft.id) } }
                } label: {
                    Text("Продолжить").font(.headline)
                        .padding(.leading, 20).padding(.trailing, 16)
                        .padding(.vertical, 10)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("resumeMealDraft")
                .accessibilityLabel("Продолжить черновик")
                .accessibilityValue(subtitle(draft))
                .disabled(meal.saving)
                Rectangle().fill(.separator).frame(width: 0.5, height: 18)
                    .accessibilityHidden(true)
                Menu {
                    Button("Новый приём", systemImage: "plus") { beginMeal(controlID: "MealDraft.new") }
                    Button("Все черновики", systemImage: "list.bullet") { UsageTelemetry.shared.action("MealDraft.list"); choosingDraft = true }
                    Button { UsageTelemetry.shared.action("MealDraftAccessory.button.32"); Task { await meal.commit() } } label: {
                        Label("Сохранить еду", systemImage: "checkmark")
                    }.disabled(!meal.canCommit).accessibilityIdentifier("saveMealDraft")
                    Button(role: .destructive) { UsageTelemetry.shared.action("MealDraftAccessory.button.35"); Task { await meal.discard() } } label: {
                        Label("Удалить черновик", systemImage: "trash")
                    }.accessibilityIdentifier("discardMealDraft")
                } label: {
                    if meal.saving { ProgressView().frame(width: 44, height: 44) }
                    else {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .accessibilityLabel("Действия с черновиком").disabled(meal.saving)
            }
            .fixedSize(horizontal: false, vertical: true)
            .glassEffect(.regular.interactive(), in: .capsule)
        } else if !meal.drafts.isEmpty {
            HStack {
                Button("Продолжить") { UsageTelemetry.shared.action("CacalcApp.button.290"); choosingDraft = true }
                Menu { Button("Новый приём", systemImage: "plus") { beginMeal(controlID: "MealDraft.newFromList") } }
                    label: { Image(systemName: "ellipsis") }
            }.padding(.horizontal, 20).padding(.vertical, 12).glassEffect(.regular.interactive(), in: .capsule)
        } else {
            Button { beginMeal() } label: {
                Label("Добавить", systemImage: "plus").font(.headline)
                    .frame(minWidth: 180)
            }
            .buttonStyle(.glass(.regular.interactive())).buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityLabel("Добавить еду")
            .accessibilityHint("Открывает новый приём пищи")
            .accessibilityIdentifier("recordMeal")
        }
    }
    private func beginMeal(controlID: String = "CacalcApp.button.283") {
        UsageTelemetry.shared.action(controlID)
        Task { await meal.begin(day: day) }
    }
    private func subtitle(_ draft: MealDraft) -> String {
        let text = meal.hasPendingDictation ? "Диктовка сохранена" : draft.rows.isEmpty ? "Добавьте еду" : draft.rows.map(\.displayName).joined(separator: ", ")
        return draft.day == store.today ? text : draft.day.title(relativeTo: store.today) + ": " + text
    }
}
