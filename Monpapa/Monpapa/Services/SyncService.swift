// MonPapa iOS — Sync Service
// Отвечает за маппинг и синхронизацию SwiftData с backend.

import Foundation
import SwiftData
import Combine

// MARK: - Уведомление для автосинхронизации

extension Notification.Name {
    /// Постить после сохранения транзакции, категории и т.д.
    /// SyncService подхватит и запустит sync с debounce.
    static let dataDidChange = Notification.Name("monpapa.dataDidChange")
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case success(Date)
    case error(String)
}

@MainActor
final class SyncService: ObservableObject {
    
    // MARK: - Состояние
    
    @Published private(set) var status: SyncStatus = .idle
    
    private var lastSyncAt: Date? {
        get {
            if let iso = KeychainService.load(key: KeychainService.Keys.lastSyncAt) {
                return ISO8601DateFormatter().date(from: iso)
            }
            return nil
        }
        set {
            if let newValue = newValue {
                let iso = ISO8601DateFormatter().string(from: newValue)
                KeychainService.save(key: KeychainService.Keys.lastSyncAt, value: iso)
            } else {
                KeychainService.delete(key: KeychainService.Keys.lastSyncAt)
            }
        }
    }
    
    private let modelContext: ModelContext
    
    // MARK: - Конфигурация API
    
    private var baseURL: String {
        APIConfig.baseURL
    }
    
    private var apiBase: String { "\(baseURL)/api/v1/sync" }
    
    // MARK: - Инициализатор
    
    private var syncDebounceTask: Task<Void, Never>?
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Подписка на автосинхронизацию с debounce 1.5 сек
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDataDidChange),
            name: .dataDidChange,
            object: nil
        )
    }
    
    @objc private func handleDataDidChange() {
        // Debounce: отменяем предыдущий таск, ждём 1.5 сек тишины
        syncDebounceTask?.cancel()
        syncDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            guard AuthService.shared.isAuthenticated else { return }
            print("[SyncService] 🔄 Автосинхронизация после изменения данных")
            await self.sync()
        }
    }
    
    // MARK: - Гибкий декодер дат
    
    /// Python datetime.isoformat() → "2026-04-06T15:30:00.123456+00:00"
    /// Swift ISO8601DateFormatter по умолчанию это НЕ парсит.
    /// Этот декодер обрабатывает все варианты.
    private static func makeFlexibleDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        
        nonisolated(unsafe) let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        nonisolated(unsafe) let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        
        decoder.dateDecodingStrategy = .custom { decoder -> Date in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            
            // Нормализация: "+00:00" → "Z"
            let normalized = str
                .replacingOccurrences(of: "+00:00", with: "Z")
                .replacingOccurrences(of: "+0000", with: "Z")
            
            if let d = isoFull.date(from: normalized) { return d }
            if let d = isoBasic.date(from: normalized) { return d }
            if str.count == 10, let d = dateOnly.date(from: str) { return d }
            
            // Fallback: DateFormatter с полным ISO паттерном
            let fallback = DateFormatter()
            fallback.locale = Locale(identifier: "en_US_POSIX")
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ"
            if let d = fallback.date(from: str) { return d }
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            if let d = fallback.date(from: str) { return d }
            
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot parse date: \(str)"
            )
        }
        
        return decoder
    }
    
    // MARK: - Публичный API
    
    /// Выполнить синхронизацию
    func sync() async {
        guard let token = AuthService.shared.token else {
            print("[SyncService] 🛑 Синхронизация пропущена: нет токена авторизации")
            return
        }
        
        status = .syncing
        
        // Детекция смены аккаунта: если текущий email отличается от последнего —
        // очищаем ВСЕ локальные данные чтобы не утекли данные чужого аккаунта.
        let currentEmail = AuthService.shared.userEmail
        let lastSyncedEmail = KeychainService.load(key: "monpapa.sync.email")
        
        if let currentEmail = currentEmail, let lastEmail = lastSyncedEmail, currentEmail != lastEmail {
            print("[SyncService] 🔄 Смена аккаунта: \(lastEmail) → \(currentEmail) — очистка локальных данных")
            clearLocalData()
            lastSyncAt = nil
            KeychainService.save(key: "monpapa.sync.email", value: currentEmail)
        } else if let currentEmail = currentEmail, lastSyncedEmail == nil {
            // Первый sync — запоминаем email
            KeychainService.save(key: "monpapa.sync.email", value: currentEmail)
        }
        
        // Детекция переустановки: Keychain на симуляторе сохраняется между установками.
        // Если lastSyncAt есть, но локальных данных нет — сбрасываем для полной загрузки.
        if lastSyncAt != nil {
            let localTxCount = (try? modelContext.fetchCount(FetchDescriptor<TransactionModel>())) ?? 0
            let localCatCount = (try? modelContext.fetchCount(FetchDescriptor<CategoryModel>())) ?? 0
            if localTxCount == 0 && localCatCount == 0 {
                print("[SyncService] 🔄 Обнаружена переустановка — сброс lastSyncAt для полной загрузки")
                lastSyncAt = nil
            }
        }
        
        do {
            let allOperations = try fetchLocalChanges(since: lastSyncAt)
            
            var currentServerTime: Date? = nil
            
            // Фаза 1: Push зависимости (Categories, Counterparts)
            // Они должны получить serverId ДО отправки Transactions/Debts,
            // чтобы FK (category_id, counterpart_id) были резолвлены.
            let phase1 = allOperations.filter { $0.entity == "category" || $0.entity == "counterpart" }
            if !phase1.isEmpty {
                let response = try await pushChanges(operations: phase1, token: token)
                updateLocalServerIds(from: response.results)
                currentServerTime = response.serverTime
                print("[SyncService] ✅ Push фаза 1: \(phase1.count) зависимостей")
            }
            
            // Фаза 2: Push зависимые сущности (Transactions, Debts, DebtPayments)
            // Теперь category.serverId / counterpart.serverId уже обновлены
            let phase2Entities = Set(["transaction", "debt", "debt_payment"])
            var phase2 = allOperations.filter { phase2Entities.contains($0.entity) }
            
            // Обновить FK-значения теперь когда serverId известны
            phase2 = try refreshFKInOperations(phase2)
            
            if !phase2.isEmpty {
                let response = try await pushChanges(operations: phase2, token: token)
                updateLocalServerIds(from: response.results)
                currentServerTime = response.serverTime
                print("[SyncService] ✅ Push фаза 2: \(phase2.count) сущностей")
            }
            
            let changesDateStr = lastSyncAt.map { ISO8601DateFormatter().string(from: $0) } ?? "1970-01-01T00:00:00Z"
            let changes = try await pullChanges(since: changesDateStr, token: token)
            
            applyPulledChanges(changes)
            
            try modelContext.save()
            
            let finalTime = currentServerTime ?? changes.serverTime
            lastSyncAt = finalTime
            status = .success(finalTime)
            print("[SyncService] ✅ Синхронизация завершена")
            
        } catch let decodingError as DecodingError {
            let detail: String
            switch decodingError {
            case .keyNotFound(let key, let ctx):
                detail = "Ключ '\(key.stringValue)' не найден в \(ctx.codingPath.map(\.stringValue)): \(ctx.debugDescription)"
            case .typeMismatch(let type, let ctx):
                detail = "Тип \(type) не совпадает в \(ctx.codingPath.map(\.stringValue)): \(ctx.debugDescription)"
            case .valueNotFound(let type, let ctx):
                detail = "Значение \(type) не найдено в \(ctx.codingPath.map(\.stringValue)): \(ctx.debugDescription)"
            case .dataCorrupted(let ctx):
                detail = "Данные повреждены в \(ctx.codingPath.map(\.stringValue)): \(ctx.debugDescription)"
            @unknown default:
                detail = decodingError.localizedDescription
            }
            print("[SyncService] ❌ Ошибка декодирования: \(detail)")
            status = .error(detail)
        } catch {
            print("[SyncService] ❌ Ошибка синхронизации: \(error)")
            
            // Если сервер сообщил «Устройство не найдено» — стейл-токен в Keychain.
            // Делаем logout чтобы UI перешёл в неавторизованное состояние.
            let errorStr = "\(error)"
            if errorStr.contains("Устройство не найдено") || errorStr.contains("Device not found") {
                print("[SyncService] ⚠️ Стейл-токен обнаружен. Авторизация сброшена.")
                AuthService.shared.logout()
            }
            
            status = .error(error.localizedDescription)
        }
    }
    
    /// Принудительно скачать все с сервера
    func fullSync() async {
        lastSyncAt = nil
        await sync()
    }
    
    /// Сброс состояния синхронизации (при logout)
    /// Очищает lastSyncAt и email привязку, чтобы при следующем входе
    /// под другим аккаунтом не было конфликтов.
    func resetSyncState() {
        lastSyncAt = nil
        KeychainService.delete(key: "monpapa.sync.email")
        status = .idle
        print("[SyncService] ♻️ Состояние синхронизации сброшено")
    }
    
    /// Очистить все локальные данные (при смене аккаунта / logout)
    ///
    /// Важно: `modelContext.delete(model:)` использует batch delete,
    /// который НЕ умеет обрабатывать @Relationship constraints в SwiftData.
    /// Поэтому удаляем записи по одной, в правильном порядке зависимостей:
    /// 1. DebtPayments (зависят от Debts)
    /// 2. Transactions (зависят от Categories)
    /// 3. Debts (зависят от Counterparts)
    /// 4. Categories (inverse → transactions)
    /// 5. Counterparts
    func clearLocalData() {
        do {
            // DebtPayments → зависят от Debt
            let payments = try modelContext.fetch(FetchDescriptor<DebtPaymentModel>())
            for p in payments { modelContext.delete(p) }
            
            // Transactions → зависят от Category
            let transactions = try modelContext.fetch(FetchDescriptor<TransactionModel>())
            for tx in transactions { modelContext.delete(tx) }
            
            // Debts → зависят от Counterpart
            let debts = try modelContext.fetch(FetchDescriptor<DebtModel>())
            for d in debts { modelContext.delete(d) }
            
            // Categories
            let categories = try modelContext.fetch(FetchDescriptor<CategoryModel>())
            for c in categories { modelContext.delete(c) }
            
            // Counterparts
            let counterparts = try modelContext.fetch(FetchDescriptor<CounterpartModel>())
            for cp in counterparts { modelContext.delete(cp) }
            
            try modelContext.save()
            print("[SyncService] 🗑️ Локальные данные очищены (\(payments.count) payments, \(transactions.count) txs, \(debts.count) debts, \(categories.count) cats, \(counterparts.count) cps)")
        } catch {
            print("[SyncService] ⚠️ Ошибка очистки: \(error)")
        }
    }
    
    // MARK: - Push логика
    
    private func fetchLocalChanges(since: Date?) throws -> [SyncOperationDTO] {
        var operations: [SyncOperationDTO] = []
        let sinceDate = since ?? Date(timeIntervalSince1970: 0)
        
        // 1. Categories
        let categoryDescriptor = FetchDescriptor<CategoryModel>(predicate: #Predicate { $0.updatedAt > sinceDate || $0.deletedAt != nil })
        for cat in try modelContext.fetch(categoryDescriptor) {
            guard let clientId = cat.clientId else { continue }
            let data: [String: Any] = [
                "name": cat.name,
                "type": cat.typeRaw,
                "icon": cat.icon ?? NSNull(),
                "parent_id": cat.parent?.serverId ?? NSNull()
            ]
            let action = cat.deletedAt != nil ? "delete" : (cat.serverId == nil ? "create" : "update")
            operations.append(SyncOperationDTO(entity: "category", action: action, clientId: clientId, data: data, updatedAt: cat.updatedAt))
        }
        
        // 2. Counterparts
        let counterpartDescriptor = FetchDescriptor<CounterpartModel>(predicate: #Predicate { $0.updatedAt > sinceDate || $0.deletedAt != nil })
        for cp in try modelContext.fetch(counterpartDescriptor) {
            guard let clientId = cp.clientId else { continue }
            let data: [String: Any] = [
                "name": cp.name,
                "icon": cp.icon ?? NSNull()
            ]
            let action = cp.deletedAt != nil ? "delete" : (cp.serverId == nil ? "create" : "update")
            operations.append(SyncOperationDTO(entity: "counterpart", action: action, clientId: clientId, data: data, updatedAt: cp.updatedAt))
        }
        
        // 3. Transactions
        let txDescriptor = FetchDescriptor<TransactionModel>(predicate: #Predicate { $0.updatedAt > sinceDate || $0.deletedAt != nil })
        for tx in try modelContext.fetch(txDescriptor) {
            guard let clientId = tx.clientId else { continue }
            let data: [String: Any] = [
                "type": tx.typeRaw,
                "amount": tx.amountString,
                "currency": tx.currency,
                "comment": tx.comment ?? NSNull(),
                "raw_text": tx.rawText ?? NSNull(),
                "transaction_date": ISO8601DateFormatter().string(from: tx.transactionDate).prefix(10),
                "category_id": tx.category?.serverId ?? NSNull(),
                // Fallback: client_id категории для резолва на бэкенде
                "category_client_id": tx.category?.clientId ?? NSNull()
            ]
            let action = tx.deletedAt != nil ? "delete" : (tx.serverId == nil ? "create" : "update")
            operations.append(SyncOperationDTO(entity: "transaction", action: action, clientId: clientId, data: data, updatedAt: tx.updatedAt))
        }
        
        // 4. Debts
        let debtDescriptor = FetchDescriptor<DebtModel>(predicate: #Predicate { $0.updatedAt > sinceDate || $0.deletedAt != nil })
        for debt in try modelContext.fetch(debtDescriptor) {
            guard let clientId = debt.clientId else { continue }
            let data: [String: Any] = [
                "direction": debt.directionRaw,
                "amount": debt.amountString,
                "currency": debt.currency,
                "comment": debt.comment ?? NSNull(),
                "raw_text": debt.rawText ?? NSNull(),
                "debt_date": ISO8601DateFormatter().string(from: debt.debtDate).prefix(10),
                "due_date": debt.dueDate.map { ISO8601DateFormatter().string(from: $0).prefix(10) } ?? NSNull(),
                "is_closed": debt.isClosed,
                "counterpart_id": debt.counterpart?.serverId ?? NSNull(),
                // Fallback: client_id контрагента для резолва на бэкенде
                "counterpart_client_id": debt.counterpart?.clientId ?? NSNull()
            ]
            let action = debt.deletedAt != nil ? "delete" : (debt.serverId == nil ? "create" : "update")
            operations.append(SyncOperationDTO(entity: "debt", action: action, clientId: clientId, data: data, updatedAt: debt.updatedAt))
        }
        
        // 5. DebtPayments
        let debtPaymentDescriptor = FetchDescriptor<DebtPaymentModel>(predicate: #Predicate { $0.createdAt > sinceDate || $0.deletedAt != nil })
        for p in try modelContext.fetch(debtPaymentDescriptor) {
            guard let clientId = p.clientId else { continue }
            let data: [String: Any] = [
                "amount": p.amountString,
                "payment_date": ISO8601DateFormatter().string(from: p.paymentDate).prefix(10),
                "comment": p.comment ?? NSNull(),
                "debt_id": p.debt?.serverId ?? NSNull(),
                // Fallback: client_id долга для резолва на бэкенде
                "debt_client_id": p.debt?.clientId ?? NSNull()
            ]
            let action = p.deletedAt != nil ? "delete" : (p.serverId == nil ? "create" : "update")
            // У платежей нет updatedAt, используем createdAt
            operations.append(SyncOperationDTO(entity: "debt_payment", action: action, clientId: clientId, data: data, updatedAt: p.createdAt))
        }
        
        return operations
    }
    
    private func pushChanges(operations: [SyncOperationDTO], token: String) async throws -> SyncResponseDTO {
        let url = URL(string: apiBase)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let body = ["operations": operations.map { $0.toDictionary() }]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            print("[SyncService] ⚠️ Push HTTP error: \(message)")
            throw SyncError.serverError(message)
        }
        
        #if DEBUG
        print("[SyncService] 📦 Push response: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
        #endif
        
        return try Self.makeFlexibleDecoder().decode(SyncResponseDTO.self, from: data)
    }
    
    private func updateLocalServerIds(from results: [SyncOperationResultDTO]) {
        for res in results {
            guard let serverId = res.serverId, res.status == "created", let clientId = res.clientId else { continue }
            
            if let cat = try? modelContext.fetch(FetchDescriptor<CategoryModel>(predicate: #Predicate { $0.clientId == clientId })).first {
                cat.serverId = serverId
            } else if let cp = try? modelContext.fetch(FetchDescriptor<CounterpartModel>(predicate: #Predicate { $0.clientId == clientId })).first {
                cp.serverId = serverId
            } else if let tx = try? modelContext.fetch(FetchDescriptor<TransactionModel>(predicate: #Predicate { $0.clientId == clientId })).first {
                tx.serverId = serverId
            } else if let db = try? modelContext.fetch(FetchDescriptor<DebtModel>(predicate: #Predicate { $0.clientId == clientId })).first {
                db.serverId = serverId
            } else if let dp = try? modelContext.fetch(FetchDescriptor<DebtPaymentModel>(predicate: #Predicate { $0.clientId == clientId })).first {
                dp.serverId = serverId
            }
        }
    }
    
    /// Обновляет FK-значения в операциях фазы 2 после получения serverId из фазы 1.
    /// Перечитывает serverId у Category/Counterpart/Debt и подставляет в data.
    private func refreshFKInOperations(_ operations: [SyncOperationDTO]) throws -> [SyncOperationDTO] {
        return operations.map { op in
            var data = op.data
            
            switch op.entity {
            case "transaction":
                // Обновить category_id: найти Category по clientId и взять свежий serverId
                if let catClientId = data["category_client_id"] as? String {
                    if let cat = try? modelContext.fetch(FetchDescriptor<CategoryModel>(
                        predicate: #Predicate { $0.clientId == catClientId }
                    )).first, let sid = cat.serverId {
                        data["category_id"] = sid
                    }
                }
                
            case "debt":
                // Обновить counterpart_id
                if let cpClientId = data["counterpart_client_id"] as? String {
                    if let cp = try? modelContext.fetch(FetchDescriptor<CounterpartModel>(
                        predicate: #Predicate { $0.clientId == cpClientId }
                    )).first, let sid = cp.serverId {
                        data["counterpart_id"] = sid
                    }
                }
                
            case "debt_payment":
                // Обновить debt_id
                if let debtClientId = data["debt_client_id"] as? String {
                    if let debt = try? modelContext.fetch(FetchDescriptor<DebtModel>(
                        predicate: #Predicate { $0.clientId == debtClientId }
                    )).first, let sid = debt.serverId {
                        data["debt_id"] = sid
                    }
                }
                
            default:
                break
            }
            
            return SyncOperationDTO(entity: op.entity, action: op.action, clientId: op.clientId, data: data, updatedAt: op.updatedAt)
        }
    }
    
    // MARK: - Pull логика
    
    private func pullChanges(since: String, token: String) async throws -> SyncChangesResponseDTO {
        var components = URLComponents(string: "\(apiBase)/changes")!
        components.queryItems = [URLQueryItem(name: "since", value: since)]
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown server error"
            print("[SyncService] ⚠️ Pull HTTP error: \(message)")
            throw SyncError.serverError(message)
        }
        
        #if DEBUG
        print("[SyncService] 📦 Pull response: \(String(data: data, encoding: .utf8)?.prefix(1000) ?? "nil")")
        #endif
        
        return try Self.makeFlexibleDecoder().decode(SyncChangesResponseDTO.self, from: data)
    }
    
    private func applyPulledChanges(_ changes: SyncChangesResponseDTO) {
        
        // 1. Categories
        let allCats = (try? modelContext.fetch(FetchDescriptor<CategoryModel>())) ?? []
        for catData in changes.categories {
            // Ищем по clientId, serverId, или name+type (защита от дублей при первом sync)
            let existing = catData.client_id.flatMap { cid in allCats.first(where: { $0.clientId == cid }) }
                            ?? allCats.first(where: { $0.serverId == catData.id })
                            // Если локальная категория без serverId совпадает по name+type —
                            // это та же категория, созданная анонимно → мёрджим, не дублируем
                            ?? allCats.first(where: {
                                $0.serverId == nil
                                && $0.deletedAt == nil
                                && $0.name.lowercased() == catData.name.lowercased()
                                && $0.typeRaw == catData.type
                            })
            
            if let existing {
                if catData.deleted_at != nil { existing.deletedAt = catData.deleted_at }
                else {
                    existing.serverId = catData.id
                    existing.name = catData.name
                    existing.typeRaw = catData.type
                    existing.icon = catData.icon ?? existing.icon  // Не затираем локальную иконку
                    existing.updatedAt = catData.updated_at
                    if let cid = catData.client_id { existing.clientId = cid }
                    print("[SyncService] 🔗 Смёрджена категория '\(catData.name)' (name+type match → serverId=\(catData.id))")
                }
            } else if catData.deleted_at == nil {
                let newCat = CategoryModel(
                    name: catData.name,
                    type: TransactionType(rawValue: catData.type) ?? .expense,
                    icon: catData.icon,
                    serverId: catData.id
                )
                if let cid = catData.client_id { newCat.clientId = cid }
                newCat.updatedAt = catData.updated_at
                modelContext.insert(newCat)
            }
        }
        // Восстанавливаем parent
        let updatedCats = (try? modelContext.fetch(FetchDescriptor<CategoryModel>())) ?? []
        for catData in changes.categories {
            let existing = catData.client_id.flatMap { cid in updatedCats.first(where: { $0.clientId == cid }) }
                            ?? updatedCats.first(where: { $0.serverId == catData.id })
            guard let existing else { continue }
            if let parentId = catData.parent_id {
                existing.parent = updatedCats.first(where: { $0.serverId == parentId })
            }
        }
        
        // 2. Counterparts
        let allCps = (try? modelContext.fetch(FetchDescriptor<CounterpartModel>())) ?? []
        for cpData in changes.counterparts {
            let existing = cpData.client_id.flatMap { cid in allCps.first(where: { $0.clientId == cid }) }
                            ?? allCps.first(where: { $0.serverId == cpData.id })
            
            if let existing {
                if cpData.deleted_at != nil { existing.deletedAt = cpData.deleted_at }
                else {
                    existing.serverId = cpData.id
                    existing.name = cpData.name
                    existing.icon = cpData.icon

                    existing.updatedAt = cpData.updated_at
                    if let cid = cpData.client_id { existing.clientId = cid }
                }
            } else if cpData.deleted_at == nil {
                let newCp = CounterpartModel(
                    name: cpData.name,
                    icon: cpData.icon,

                    serverId: cpData.id
                )
                if let cid = cpData.client_id { newCp.clientId = cid }
                newCp.updatedAt = cpData.updated_at
                modelContext.insert(newCp)
            }
        }
        
        // 3. Transactions
        // Перечитываем все категории (включая свежесозданные) для привязки
        let allLocalCats = (try? modelContext.fetch(FetchDescriptor<CategoryModel>())) ?? []
        let allTxs = (try? modelContext.fetch(FetchDescriptor<TransactionModel>())) ?? []
        for txData in changes.transactions {
            let existing = txData.client_id.flatMap { cid in allTxs.first(where: { $0.clientId == cid }) }
                            ?? allTxs.first(where: { $0.serverId == txData.id })
            
            if let existing {
                if txData.deleted_at != nil { existing.deletedAt = txData.deleted_at }
                else {
                    existing.serverId = txData.id
                    existing.typeRaw = txData.type
                    existing.amountString = txData.amount
                    existing.currency = txData.currency
                    existing.comment = txData.comment
                    existing.rawText = txData.raw_text
                    if let txDate = txData.transaction_date { existing.transactionDate = txDate }
                    // Привязка категории: ищем среди ВСЕХ локальных категорий по serverId
                    if let catId = txData.category_id { existing.category = allLocalCats.first(where: { $0.serverId == catId }) }
                    existing.updatedAt = txData.updated_at
                    if let cid = txData.client_id { existing.clientId = cid }
                }
            } else if txData.deleted_at == nil {
                let newTx = TransactionModel(
                    type: TransactionType(rawValue: txData.type) ?? .expense,
                    amount: Decimal(string: txData.amount) ?? 0,
                    currency: txData.currency,
                    transactionDate: txData.transaction_date ?? Date(),
                    comment: txData.comment,
                    rawText: txData.raw_text,
                    // Привязка категории: ищем среди ВСЕХ локальных категорий
                    category: txData.category_id.flatMap { catId in allLocalCats.first(where: { $0.serverId == catId }) },
                    serverId: txData.id
                )
                if let cid = txData.client_id { newTx.clientId = cid }
                newTx.updatedAt = txData.updated_at
                modelContext.insert(newTx)
            }
        }
        
        // 4. Debts
        let allDebts = (try? modelContext.fetch(FetchDescriptor<DebtModel>())) ?? []
        let allLocalCps = (try? modelContext.fetch(FetchDescriptor<CounterpartModel>())) ?? []
        for debtData in changes.debts {
            let existing = debtData.client_id.flatMap { cid in allDebts.first(where: { $0.clientId == cid }) }
                            ?? allDebts.first(where: { $0.serverId == debtData.id })
            
            if let existing {
                if debtData.deleted_at != nil { existing.deletedAt = debtData.deleted_at }
                else {
                    existing.serverId = debtData.id
                    existing.directionRaw = debtData.direction
                    existing.amountString = debtData.amount
                    existing.paidAmountString = debtData.paid_amount
                    existing.currency = debtData.currency
                    existing.comment = debtData.comment
                    existing.rawText = debtData.raw_text
                    if let dDate = debtData.debt_date { existing.debtDate = dDate }
                    existing.dueDate = debtData.due_date
                    existing.isClosed = debtData.is_closed
                    if let cpId = debtData.counterpart_id { existing.counterpart = allLocalCps.first(where: { $0.serverId == cpId }) }
                    existing.updatedAt = debtData.updated_at
                    if let cid = debtData.client_id { existing.clientId = cid }
                }
            } else if debtData.deleted_at == nil {
                let newDebt = DebtModel(
                    direction: DebtDirection(rawValue: debtData.direction) ?? .gave,
                    amount: Decimal(string: debtData.amount) ?? 0,
                    debtDate: debtData.debt_date ?? Date(),
                    dueDate: debtData.due_date,
                    currency: debtData.currency,
                    comment: debtData.comment,
                    rawText: debtData.raw_text,
                    counterpart: debtData.counterpart_id.flatMap { cpId in allLocalCps.first(where: { $0.serverId == cpId }) },
                    serverId: debtData.id
                )
                if let cid = debtData.client_id { newDebt.clientId = cid }
                newDebt.paidAmountString = debtData.paid_amount
                newDebt.isClosed = debtData.is_closed
                newDebt.updatedAt = debtData.updated_at
                modelContext.insert(newDebt)
            }
        }
        
        // 5. DebtPayments
        let allPayments = (try? modelContext.fetch(FetchDescriptor<DebtPaymentModel>())) ?? []
        let allLocalDebts = (try? modelContext.fetch(FetchDescriptor<DebtModel>())) ?? []
        for dpData in changes.debt_payments {
            let existing = dpData.client_id.flatMap { cid in allPayments.first(where: { $0.clientId == cid }) }
                            ?? allPayments.first(where: { $0.serverId == dpData.id })
            
            if let existing {
                if dpData.deleted_at != nil { existing.deletedAt = dpData.deleted_at }
                else {
                    existing.serverId = dpData.id
                    existing.amountString = dpData.amount
                    if let pDate = dpData.payment_date { existing.paymentDate = pDate }
                    existing.comment = dpData.comment
                    if let dbId = dpData.debt_id { existing.debt = allLocalDebts.first(where: { $0.serverId == dbId }) }
                    if let cid = dpData.client_id { existing.clientId = cid }
                }
            } else if dpData.deleted_at == nil {
                let newDp = DebtPaymentModel(
                    amount: Decimal(string: dpData.amount) ?? 0,
                    paymentDate: dpData.payment_date ?? Date(),
                    comment: dpData.comment,
                    debt: dpData.debt_id.flatMap { dbId in allLocalDebts.first(where: { $0.serverId == dbId }) },
                    serverId: dpData.id
                )
                if let cid = dpData.client_id { newDp.clientId = cid }
                modelContext.insert(newDp)
            }
        }
    }
}

// MARK: - DTOs

private struct SyncOperationDTO {
    let entity: String
    let action: String
    let clientId: String
    let data: [String: Any]
    let updatedAt: Date
    
    func toDictionary() -> [String: Any] {
        return [
            "entity": entity,
            "action": action,
            "client_id": clientId,
            "data": data,
            "updated_at": ISO8601DateFormatter().string(from: updatedAt)
        ]
    }
}

private struct SyncResponseDTO: Codable {
    let results: [SyncOperationResultDTO]
    let serverTime: Date
    
    enum CodingKeys: String, CodingKey {
        case results
        case serverTime = "server_time"
    }
}

private struct SyncOperationResultDTO: Codable {
    let clientId: String?
    let status: String
    let serverId: Int?
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case status
        case serverId = "server_id"
        case message
    }
}

private struct SyncChangesResponseDTO: Codable {
    let serverTime: Date
    let categories: [CategoryChangeDTO]
    let counterparts: [CounterpartChangeDTO]
    let transactions: [TransactionChangeDTO]
    let debts: [DebtChangeDTO]
    let debt_payments: [DebtPaymentChangeDTO]
    
    enum CodingKeys: String, CodingKey {
        case serverTime = "server_time"
        case categories, counterparts, transactions, debts, debt_payments
    }
}

private struct CategoryChangeDTO: Codable {
    let id: Int
    let client_id: String?
    let name: String
    let type: String
    let icon: String?
    let parent_id: Int?
    let updated_at: Date
    let deleted_at: Date?
}

private struct CounterpartChangeDTO: Codable {
    let id: Int
    let client_id: String?
    let name: String
    let icon: String?
    let updated_at: Date
    let deleted_at: Date?
}

private struct TransactionChangeDTO: Codable {
    let id: Int
    let client_id: String?
    let type: String
    let amount: String
    let currency: String
    let transaction_date: Date?
    let comment: String?
    let raw_text: String?
    let category_id: Int?
    let updated_at: Date
    let deleted_at: Date?
}

private struct DebtChangeDTO: Codable {
    let id: Int
    let client_id: String?
    let direction: String
    let amount: String
    let paid_amount: String
    let currency: String
    let debt_date: Date?
    let due_date: Date?
    let comment: String?
    let raw_text: String?
    let is_closed: Bool
    let counterpart_id: Int?
    let updated_at: Date
    let deleted_at: Date?
}

private struct DebtPaymentChangeDTO: Codable {
    let id: Int
    let client_id: String?
    let amount: String
    let payment_date: Date?
    let comment: String?
    let debt_id: Int?
    let deleted_at: Date?
}

enum SyncError: LocalizedError {
    case serverError(String)
    
    var errorDescription: String? {
        switch self {
        case .serverError(let str): return "Ошибка сервера: \(str)"
        }
    }
}
