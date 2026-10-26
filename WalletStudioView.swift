//
//  WalletStudioView.swift
//  AirCard-iOS — écran unique « Cartes » (remplace Wallet + Passcode + Wallpapers)
//
//  Dépend de SkinLibrary.swift (SkinLibraryStore / SavedSkin).
//  Cette vue ne connaît PAS le moteur d'AirCard : elle reçoit les cartes
//  détectées et appelle onScan / onFlash. Le branchement sur AppViewModel
//  se fait dans un petit adaptateur (voir la réponse).
//

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Types d'échange avec le moteur

struct WalletCardItem: Identifiable, Hashable {
    let id: String          // identifiant de la carte détecté par l'app
    var name: String        // surnom ou nom de la banque
    var network: String?    // Visa, Mastercard, ...
}

struct StatusMessage: Equatable {
    var text: String
    var isError: Bool
}

struct FlashJob {
    let cardID: String
    let image: UIImage
}

// MARK: - Vue

struct WalletStudioView: View {
    @ObservedObject var library: SkinLibraryStore

    let cards: [WalletCardItem]
    let status: StatusMessage?
    let isScanning: Bool
    var onScan: () -> Void
    /// Doit renvoyer true si tout s'est bien passé.
    var onFlash: ([FlashJob]) async -> Bool

    @State private var selectedCardID: String?
    @State private var assignedImages: [String: UIImage] = [:]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isFlashing = false
    @State private var flashSuccessCount = 0
    @State private var deleting: SavedSkin?

    private let gridColumns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    // MARK: Corps

    var body: some View {
        NavigationStack {
            Group {
                if cards.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cartes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { scanButton }
            }
            .safeAreaInset(edge: .bottom) {
                if !cards.isEmpty { flashBar }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
            .onChange(of: cards) { _, newCards in
                if selectedCardID == nil || !newCards.contains(where: { $0.id == selectedCardID }) {
                    selectedCardID = newCards.first?.id
                }
            }
            .onAppear { selectedCardID = selectedCardID ?? cards.first?.id }
            .sensoryFeedback(.success, trigger: flashSuccessCount)
            .confirmationDialog("Supprimer cette photo ?",
                                isPresented: Binding(get: { deleting != nil },
                                                     set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    if let s = deleting { library.delete(s) }
                    deleting = nil
                }
            }
        }
    }

    // MARK: Contenu principal

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let status { StatusBanner(status: status) }

                section("1. Choisissez une carte") { cardCarousel }
                section("2. Aperçu") { preview }
                section("3. Choisissez une photo", trailing: { importButton }) { photoGrid }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    // MARK: Cartes détectées

    private var cardCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(cards) { card in
                    let selected = card.id == selectedCardID
                    Button {
                        selectedCardID = card.id
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CardFace(image: assignedImages[card.id])
                                .frame(width: 148)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: selected ? 3 : 0)
                                )
                            Text(card.name)
                                .font(.footnote.weight(selected ? .semibold : .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let n = card.network {
                                Text(n).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.name)\(assignedImages[card.id] != nil ? ", photo choisie" : "")")
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
        }
    }

    // MARK: Aperçu

    private var preview: some View {
        VStack(spacing: 10) {
            CardFace(image: selectedCardID.flatMap { assignedImages[$0] })
                .frame(maxWidth: 340)
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                .animation(.easeOut(duration: 0.25), value: selectedCardID.flatMap { assignedImages[$0] }?.hashValue)

            if let id = selectedCardID, assignedImages[id] != nil {
                Button(role: .destructive) {
                    assignedImages[id] = nil
                } label: {
                    Label("Retirer la photo", systemImage: "xmark.circle")
                        .frame(minHeight: 44)
                }
                .font(.subheadline)
            } else {
                Text("Touchez une photo ci-dessous pour l'appliquer à cette carte.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Bibliothèque

    private var walletSkins: [SavedSkin] {
        library.skins.filter { $0.kind == .wallet }
    }

    private var photoGrid: some View {
        Group {
            if walletSkins.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Aucune photo")
                        .font(.headline)
                    Text("Importez des images depuis votre galerie.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                LazyVGrid(columns: gridColumns, spacing: 10) {
                    ForEach(walletSkins) { skin in
                        PhotoTile(skin: skin, library: library)
                            .onTapGesture { assign(skin) }
                            .contextMenu {
                                Button {
                                    library.toggleFavorite(skin)
                                } label: {
                                    Label(skin.isFavorite ? "Retirer des favoris" : "Favori",
                                          systemImage: skin.isFavorite ? "heart.slash" : "heart")
                                }
                                Button(role: .destructive) {
                                    deleting = skin
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                            .accessibilityElement()
                            .accessibilityLabel(skin.name)
                            .accessibilityHint("Applique cette photo à la carte sélectionnée")
                            .accessibilityAddTraits(.isButton)
                    }
                }
            }
        }
    }

    private var importButton: some View {
        PhotosPicker(selection: $pickerItems, matching: .images) {
            Label("Importer", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
    }

    // MARK: Barre du bas

    private var flashBar: some View {
        let count = assignedImages.count
        return VStack(spacing: 0) {
            Button {
                Task { await flash() }
            } label: {
                HStack(spacing: 8) {
                    if isFlashing {
                        ProgressView().tint(.white)
                        Text("Envoi en cours…")
                    } else {
                        Image(systemName: "bolt.fill")
                        Text(count == 0 ? "Flasher" : "Flasher \(count) carte\(count > 1 ? "s" : "")")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(count == 0 || isFlashing)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    // MARK: État vide (aucune carte détectée)

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let status { StatusBanner(status: status) }

                Image(systemName: "creditcard.and.123")
                    .font(.system(size: 52))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 24)
                Text("Aucune carte détectée")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Touchez « Rechercher mes cartes ».")
                    step(2, "Double-cliquez sur le bouton latéral, validez avec Face ID, puis touchez votre carte.")
                    step(3, "Elle apparaît ici automatiquement.")
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: onScan) {
                    Label(isScanning ? "Recherche en cours…" : "Rechercher mes cartes",
                          systemImage: "wave.3.right")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isScanning)
            }
            .padding(16)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.body)
        }
    }

    private var scanButton: some View {
        Button(action: onScan) {
            if isScanning {
                ProgressView()
            } else {
                Label("Rechercher", systemImage: "wave.3.right")
            }
        }
        .disabled(isScanning)
        .frame(minWidth: 44, minHeight: 44)
    }

    // MARK: Actions

    private func assign(_ skin: SavedSkin) {
        guard let id = selectedCardID,
              let image = library.fullImage(for: skin) else { return }
        assignedImages[id] = image
    }

    private func flash() async {
        let jobs = assignedImages.map { FlashJob(cardID: $0.key, image: $0.value) }
        guard !jobs.isEmpty else { return }
        isFlashing = true
        let ok = await onFlash(jobs)
        isFlashing = false
        if ok { flashSuccessCount += 1 }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { continue }
            let n = walletSkins.count + 1
            library.add(image: image, name: "Photo \(n)", kind: .wallet)
        }
        pickerItems = []
    }

    // MARK: Aide de mise en page

    private func section<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                trailing()
            }
            content()
        }
    }
}

// MARK: - Composants

/// Face d'une carte bancaire (ratio 1,586) avec photo ou fond neutre.
private struct CardFace: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "creditcard")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1.586, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct PhotoTile: View {
    let skin: SavedSkin
    @ObservedObject var library: SkinLibraryStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemGroupedBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(1.586, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if skin.isFavorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(Color.red, in: Circle())
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .task(id: skin.fileName) { image = await library.thumbnail(for: skin) }
    }
}

private struct StatusBanner: View {
    let status: StatusMessage

    /// Traduit les erreurs techniques en phrase compréhensible.
    private var friendly: String {
        guard status.isError else { return status.text }
        let t = status.text
        if t.contains("RSD") || t.contains("TunnelFailure") || t.contains("timed out") {
            return "Connexion à l'iPhone impossible. Vérifiez que LocalDevVPN est activé, puis réessayez."
        }
        return "Une erreur est survenue."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(friendly,
                  systemImage: status.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(status.isError ? Color.red : Color.primary)

            if status.isError {
                DisclosureGroup("Détails techniques") {
                    Text(status.text)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.footnote)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((status.isError ? Color.red : Color.accentColor).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
