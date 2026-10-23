import SwiftUI

struct ProductsView: View {
    @Environment(ProductLibrary.self) private var library
    @State private var query = ""
    @State private var scope: ProductScope = .all

    private var visibleProducts: [Product] {
        library.products.filter { scope.includes($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.drafts) { draft in
                        Button { UsageTelemetry.shared.action("ProductsView.button.17"); Task { await library.resume(draft.id) } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(draft.name.isEmpty ? "Новый продукт" : draft.name, systemImage: "square.and.pencil")
                                Text(draft.pendingVoiceStage != nil ? "Диктовка сохранена" : "Продолжить карточку")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.tint(.primary).accessibilityIdentifier("resumeProductDraft_" + draft.id.uuidString)
                    }
                    if visibleProducts.isEmpty {
                        emptyState
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(visibleProducts) { product in
                            Button { UsageTelemetry.shared.action("ProductsView.button.29"); Task { await library.begin(product) } } label: {
                                productRow(product)
                            }
                            .tint(.primary)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { UsageTelemetry.shared.action("ProductsView.button.34");
                                    Task { await library.remove(product, query: query) }
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                } header: {
                    // Section headers scroll with insetGrouped lists and are not
                    // clipped by a rounded list-cell background.
                    Picker("Каталог", selection: $scope) {
                        ForEach(ProductScope.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .font(.body)
                    .textCase(nil)
                    .accessibilityIdentifier("productScope")
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
                }
            }.usageScroll("ProductsView.scroll.14")
            .listStyle(.insetGrouped)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .contentMargins(.top, 0, for: .scrollContent)
            .listSectionSpacing(0)
            .environment(\.defaultMinListHeaderHeight, 0)
            .environment(\.defaultMinListRowHeight, 0)
            .navigationTitle("Продукты")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Найти продукт")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { UsageTelemetry.shared.action("ProductsView.button.70"); Task { await library.begin() } } label: {
                        Image(systemName: "plus")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Создать продукт")
                    .accessibilityIdentifier("createProduct")
                }
            }
            .task(id: query) {
                await library.load()
                guard !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                await library.search(query)
            }
        }
        .onChange(of: scope) { _, value in UsageTelemetry.shared.event("catalogScopeChanged", ["value": String(describing: value)]) }
        .onChange(of: query) { _, value in UsageTelemetry.shared.event("searchEdited", ["query": value]) }
        .onChange(of: library.showingEditor) { _, showing in
            if !showing { Task { await library.search(query) } }
        }
        .sensoryFeedback(.success, trigger: library.savedCount)
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { library.error != nil && !library.showingEditor },
            set: { if !$0 { library.error = nil } }
        )) {
            Button("Понятно", role: .cancel) { UsageTelemetry.shared.action("ProductsView.button.93"); library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ContentUnavailableView(
                scope == .mine ? "Пока нет своих продуктов" : "Каталог пуст",
                systemImage: "carrot",
                description: Text("Создайте продукт кнопкой +.")
            )
        }
    }

    private func productRow(_ product: Product) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.body)
                    .foregroundStyle(.primary)
                if !product.brand.isEmpty {
                    Text(product.brand).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(product.calories.map {
                    product.basis == .unknown
                        ? "\(Numbers.display($0)) ккал · уточните основу"
                        : "\(Numbers.display($0)) ккал / 100 \(product.basis.title)"
                } ?? "Калории не указаны")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
