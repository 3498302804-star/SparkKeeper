import Foundation
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationView {
            List {
                let grouped = Dictionary(grouping: store.history) { rec -> String in
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    return f.string(from: rec.date)
                }
                ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                    Section(header: Text(day)) {
                        ForEach((grouped[day] ?? []).sorted(by: { $0.date > $1.date })) { r in
                            HStack(alignment: .top) {
                                Text(r.ok ? "✅" : "❌")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(r.account) → \(r.target)").font(.subheadline)
                                    Text(r.detail).font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(short(r.date)).font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if store.history.isEmpty {
                    Section { Text("还没有记录").foregroundColor(.secondary) }
                }
            }
            .navigationTitle("记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        store.history.removeAll()
                        store.save()
                    } label: { Image(systemName: "trash") }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}
