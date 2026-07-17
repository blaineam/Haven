import SwiftUI

/// Carrying an older circle onto one with a verified owner.
///
/// Circles made before 1.0.7 have no owner — nothing recorded who created them, because until the
/// group became shared it never mattered. Without an owner there's nobody a circle can check a
/// removal against, so those circles keep the encryption they already have (which does cut off
/// someone you remove) rather than moving to the newer group layer.
///
/// The way across is an offer: whoever made the circle offers a replacement whose id is tied to
/// them, and each member decides whether to follow it. That decision is deliberately a person's, not
/// the app's: the offer is signed, and we can prove it really came from whoever signed it and that
/// the replacement is genuinely theirs — but nothing can prove they made the ORIGINAL circle, since
/// it never had an owner to record. So we show who is asking and let the user choose. If two people
/// both claim it, both are shown; the app picks neither.
///
/// That reasoning only holds where a circle has no owner, so the core refuses to author, carry,
/// surface, or follow an offer on a circle that already names its creator — there the app CAN tell,
/// and asking the user to weigh a claim it has already disproven would be handing them a decision
/// under false pretences. Nothing here should ever present an offer the core didn't return.
struct CircleUpgradeBanner: View {
    let circleId: String
    @ObservedObject private var store = FeedStore.shared
    @State private var offers: [CircleUpgradeOffer] = []
    @State private var busy = false

    /// Offers from OTHER people — mine need no confirmation (I made the offer).
    private var theirs: [CircleUpgradeOffer] { offers.filter { !$0.mine } }

    /// Can I offer to upgrade this one? Only a shared circle I made. `default` is your own personal
    /// circle and `dm:` threads are two-party (both sides derive the same id, and there's nobody to
    /// remove), so neither has anything to gain here.
    private var iCanOffer: Bool {
        guard CircleCreatorStore.iCreated(circleId) else { return false }
        guard !circleId.hasPrefix(OwnedCircle.prefix), circleId != "default", !circleId.hasPrefix("dm:") else { return false }
        return offers.first(where: { $0.mine }) == nil
    }

    var body: some View {
        Group {
            if !theirs.isEmpty {
                VStack(spacing: 8) { ForEach(theirs, id: \.newCircleId) { follow($0) } }
            } else if iCanOffer {
                offerCard
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.postTick) { reload() }
        .onChange(of: circleId) { reload() }
    }

    private func reload() {
        offers = store.pendingUpgrades(circleId)
    }

    // MARK: - Member: someone is asking us to follow

    private func follow(_ o: CircleUpgradeOffer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ContactsStore.shared.name(forNodePrefix: o.fromHex) ?? String(o.fromHex.prefix(6))) is upgrading “\(o.name)”")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                // Say plainly what we can and can't vouch for — the user is the one deciding.
                Text("They say they made this circle. We can't check that, so only follow if that's right — whoever you follow will be able to remove people.")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Button {
                busy = true
                store.followCircleUpgrade(circleId, to: o.newCircleId)
                busy = false
                reload()
            } label: {
                Text("Follow").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        .padding(14)
        .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Owner: offer the upgrade

    private var offerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Upgrade this circle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("Give it a verified owner, so removing someone cuts them off for good. Everyone here will be asked to follow.")
                    .font(.caption).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            Button {
                busy = true
                store.offerCircleUpgrade(circleId)
                busy = false
                reload()
            } label: {
                Text("Upgrade").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
        .padding(14)
        .background(HavenTheme.brandHorizontal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The marker an owned circle's id carries. Kept next to the UI that reasons about it; the core mints
/// and verifies these ids — nothing here should ever try to construct one.
enum OwnedCircle {
    static let prefix = "c1"
}
