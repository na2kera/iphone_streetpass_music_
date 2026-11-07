import SwiftData
import SwiftUI

struct SongEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(PassbyManager.self) private var manager
    @Query(sort: \MySong.updatedAt, order: .reverse) private var songs: [MySong]

    @State private var title = ""
    @State private var artist = ""
    @State private var url = ""
    @State private var message: String?
    @State private var loaded = false

    /// 512 バイトのペイロードに収めやすくするための入力上限（文字数）
    private let maxTextLength = 100
    private let maxURLLength = 300

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedArtist: String { artist.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var urlIsValid: Bool { url.trimmingCharacters(in: .whitespaces).isEmpty || SongURLValidator.sanitized(url) != nil }
    private var canSave: Bool { !trimmedTitle.isEmpty && !trimmedArtist.isEmpty && urlIsValid }

    var body: some View {
        NavigationStack {
            Form {
                Section("お気に入りの曲（1曲）") {
                    TextField("曲名", text: $title)
                        .onChange(of: title) { _, v in if v.count > maxTextLength { title = String(v.prefix(maxTextLength)) } }
                    TextField("アーティスト名", text: $artist)
                        .onChange(of: artist) { _, v in if v.count > maxTextLength { artist = String(v.prefix(maxTextLength)) } }
                    TextField("URL（任意・https のみ）", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: url) { _, v in if v.count > maxURLLength { url = String(v.prefix(maxURLLength)) } }
                    if !urlIsValid {
                        Text("https:// で始まる URL のみ登録できます").font(.footnote).foregroundStyle(.red)
                    }
                }
                Section {
                    Button("保存") { save() }
                        .disabled(!canSave)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("曲名・アーティスト名・URL だけを交換します。音声ファイルは送りません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("曲登録")
            .onAppear {
                // タブ切り替えのたびに編集中の入力を上書きしないよう、初回のみ読み込む
                guard !loaded else { return }
                loaded = true
                load()
            }
        }
    }

    private func load() {
        guard let song = songs.first else { return }
        title = song.title
        artist = song.artist
        url = song.url ?? ""
    }

    private func save() {
        let sanitizedURL = SongURLValidator.sanitized(url)
        if let song = songs.first {
            song.title = trimmedTitle
            song.artist = trimmedArtist
            song.url = sanitizedURL
            song.updatedAt = .now
            // 2件以上あれば古いものを消す
            for extra in songs.dropFirst() { context.delete(extra) }
        } else {
            context.insert(MySong(title: trimmedTitle, artist: trimmedArtist, url: sanitizedURL))
        }
        do {
            try context.save()
            manager.songDidChange()
            message = "保存しました（\(Date().formatted(date: .omitted, time: .shortened))）"
        } catch {
            message = "保存に失敗: \(error.localizedDescription)"
        }
    }
}
