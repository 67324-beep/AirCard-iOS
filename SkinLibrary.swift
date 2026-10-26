//
//  SkinLibrary.swift
//  AirCard-iOS — galerie / bibliothèque de skins
//
//  Fichier autonome : à glisser dans ios-app/ puis à ajouter au projet
//  (si vous utilisez XcodeGen avec project.yml, le dossier ios-app est
//  normalement pris en compte automatiquement : relancez `xcodegen`).
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Modèle

enum SkinKind: String, Codable, CaseIterable, Identifiable {
    case wallet
    case passcode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wallet:   return "Cartes"
        case .passcode: return "Code"
        }
    }

    /// Ratio largeur/hauteur utilisé pour l'aperçu dans la grille.
    var aspectRatio: CGFloat {
        switch self {
        case .wallet:   return 1.586   // format carte bancaire
        case .passcode: return 1.0
        }
    }
}

struct SavedSkin: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: SkinKind
    var fileName: String
    var isFavorite = false
    var createdAt = Date()
}

// MARK: - Stockage

@MainActor
final class SkinLibraryStore: ObservableObject {
    @Published private(set) var skins: [SavedSkin] = []

    private let folder: URL
    private let indexURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        folder = base.appendingPathComponent("SkinLibrary", isDirectory: true)
        indexURL = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        load()
    }

    // MARK: API publique

    /// Ajoute une image à la bibliothèque. À appeler aussi depuis vos écrans
    /// existants (ex. juste après que l'utilisateur a choisi une image).
    @discardableResult
    func add(image: UIImage, name: String, kind: SkinKind) -> SavedSkin? {
        guard let data = image.pngData() else { return nil }
        let fileName = UUID().uuidString + ".png"
        do {
            try data.write(to: folder.appendingPathComponent(fileName),
                           options: .atomic)
        } catch {
            return nil
        }
        let skin = SavedSkin(name: name, kind: kind, fileName: fileName)
        skins.insert(skin, at: 0)
        save()
        return skin
    }

    func rename(_ skin: SavedSkin, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: skin) else { return }
        skins[i].name = trimmed
        save()
    }

    func toggleFavorite(_ skin: SavedSkin) {
        guard let i = index(of: skin) else { return }
        skins[i].isFavorite.toggle()
        save()
    }

    func delete(_ skin: SavedSkin) {
        try? FileManager.default.removeItem(at: url(for: skin))
        skins.removeAll { $0.id == skin.id }
        save()
    }

    func fullImage(for skin: SavedSkin) -> UIImage? {
        UIImage(contentsOfFile: url(for: skin).path)
    }

    func thumbnail(for skin: SavedSkin) async -> UIImage? {
        let path = url(for: skin).path
        return await Task.detached(priority: .utility) {
            guard let img = UIImage(contentsOfFile: path) else { return nil }
            return img.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? img
        }.value
    }

    // MARK: Interne

    private func url(for skin: SavedSkin) -> URL {
        folder.appendingPathComponent(skin.fileName)
    }

    private func index(of skin: SavedSkin) -> Int? {
        skins.firstIndex { $0.id == skin.id }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([SavedSkin].self, from: data)
        else { return }
        // Ignore les entrées dont le fichier a disparu.
        skins = decoded.filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(skins) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Vignette asynchrone

private struct SkinThumbnail: View {
    let skin: SavedSkin
    @ObservedObject var store: SkinLibraryStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(skin.kind.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if skin.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.red.gradient, in: Circle())
                    .padding(6)
            }
        }
        .task(id: skin.fileName) {
            image = await store.thumbnail(for: skin)
        }
    }
}

// MARK: - Vue principale

struct SkinLibraryView: View {
    @ObservedObject var store: SkinLibraryStore

    /// Appelé quand l'utilisateur touche un skin : branchez ici votre
    /// logique existante (application de l'image sur une carte, etc.).
    var onApply: (UIImage, SavedSkin) -> Void

    @State private var kind: SkinKind = .wallet
    @State private var search = ""
    @State private var onlyFavorites = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var renaming: SavedSkin?
    @State private var newName = ""
    @State private var deleting: SavedSkin?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    private var filtered: [SavedSkin] {
        store.skins.filter { skin in
            skin.kind == kind
            && (!onlyFavorites || skin.isFavorite)
            && (search.isEmpty || skin.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("Type", selection: $kind) {
                    ForEach(SkinKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                if filtered.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(filtered) { skin in
                            cell(for: skin)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Bibliothèque")
            .searchable(text: $search, prompt: "Rechercher un skin")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onlyFavorites.toggle()
                    } label: {
                        Image(systemName: onlyFavorites ? "heart.fill" : "heart")
                    }
                    .accessibilityLabel("Favoris uniquement")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Importer des images")
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importItems(items) }
            }
            .alert("Renommer", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Nom", text: $newName)
                Button("Annuler", role: .cancel) { renaming = nil }
                Button("OK") {
                    if let skin = renaming { store.rename(skin, to: newName) }
                    renaming = nil
                }
            }
            .confirmationDialog("Supprimer ce skin ?",
                                isPresented: Binding(
                                    get: { deleting != nil },
                                    set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let skin = deleting { store.delete(skin) }
                    deleting = nil
                }
            }
        }
    }

    // MARK: Sous-vues

    private func cell(for skin: SavedSkin) -> some View {
        Button {
            if let image = store.fullImage(for: skin) {
                onApply(image, skin)
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                SkinThumbnail(skin: skin, store: store)
                Text(skin.name)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.toggleFavorite(skin)
            } label: {
                Label(skin.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
                      systemImage: skin.isFavorite ? "heart.slash" : "heart")
            }
            Button {
                newName = skin.name
                renaming = skin
            } label: {
                Label("Renommer", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = skin
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(onlyFavorites || !search.isEmpty
                 ? "Aucun résultat"
                 : "Votre bibliothèque est vide")
                .font(.headline)
            Text("Touchez + pour importer des images.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // MARK: Import

    private func importItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let count = store.skins.filter { $0.kind == kind }.count + 1
            store.add(image: image, name: "\(kind.label) \(count)", kind: kind)
        }
        pickerItems = []
    }
}
