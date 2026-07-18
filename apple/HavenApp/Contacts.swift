import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Someone in your circle.
struct Contact: Identifiable, Codable, Equatable {
    var id: String { idHex }
    /// A local nickname you can give them (free text, your reference).
    var name: String
    var idHex: String
    /// BLAKE3 verification hash from their reach-me link — used to verify the public
    /// bundle they send during the handshake (MITM guard). Optional for older contacts.
    var verificationHex: String?
    /// The name they signed and sent in the handshake — the owner has authority over
    /// this, so it's preferred over the handshake nickname.
    var authoritativeName: String?
    /// A nickname *you* deliberately set for this person. Highest priority — it's how
    /// you've chosen to see them, so it overrides even their signed name.
    var nickname: String?
    /// The bio + link they signed and shared (their "business card"). Optional.
    var bio: String?
    var link: String?
    /// The avatar (base64 JPEG) + emoji they signed and shared, so others see their real photo.
    var avatarB64: String?
    var emoji: String?

    /// What to show: your explicit nickname, else the owner's signed name, else the
    /// name from the original handshake.
    var displayName: String {
        if let n = nickname, !n.isEmpty { return n }
        return authoritativeName ?? name
    }
}

/// Your circle, persisted locally on this device.
@MainActor
final class ContactsStore: ObservableObject {
    static let shared = ContactsStore()

    @Published private(set) var contacts: [Contact] = []
    private let key = "haven.contacts"

    /// LWW contact-removal tombstone. Contacts sync ADDITIVE-ONLY (so a freshly-restored device can't
    /// wipe the account), which means a delete never stuck on a multi-device account — a sibling's
    /// `contact:` record silently re-added them every sync. These timestamps make a removal a real,
    /// newest-wins decision (a fresh delete beats a stale re-add and vice-versa). Mirrors circle removal.
    private(set) var contactRemovedAt: [String: UInt64] = [:]
    private(set) var contactReaddedAt: [String: UInt64] = [:]
    private let removedAtKey = "haven.contacts.removedAt.v1"
    private let readdedAtKey = "haven.contacts.readdedAt.v1"
    private func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    /// A contact currently removed (removal newer than any re-add) — must not be re-added by sync.
    func isContactRemoved(_ hex: String) -> Bool { (contactRemovedAt[hex] ?? 0) > (contactReaddedAt[hex] ?? 0) }
    private func persistContactTombstones() {
        UserDefaults.standard.set(contactRemovedAt.mapValues { NSNumber(value: $0) }, forKey: removedAtKey)
        UserDefaults.standard.set(contactReaddedAt.mapValues { NSNumber(value: $0) }, forKey: readdedAtKey)
    }

    /// Factory-reset this store — clear in-memory + persisted contacts.
    func wipe() {
        contacts = []; avatarCache.removeAll(); contactRemovedAt = [:]; contactReaddedAt = [:]
        [key, removedAtKey, readdedAtKey].forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Contact].self, from: data) {
            contacts = list
        }
        contactRemovedAt = (UserDefaults.standard.dictionary(forKey: removedAtKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
        contactReaddedAt = (UserDefaults.standard.dictionary(forKey: readdedAtKey) as? [String: NSNumber])?.mapValues { $0.uint64Value } ?? [:]
    }

    func add(name: String, idHex: String, verificationHex: String? = nil) {
        contactReaddedAt[idHex] = nowMs(); persistContactTombstones()   // explicit add lifts any removal (LWW)
        guard !contacts.contains(where: { $0.idHex == idHex }) else { return }
        contacts.append(Contact(name: name, idHex: idHex, verificationHex: verificationHex))
        save()
    }

    func verification(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.verificationHex
    }

    func name(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.displayName
    }
    func contact(forNodePrefix prefix: String) -> Contact? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }
    }

    /// Record the authoritative (signed) name a contact sent during the handshake.
    func setAuthoritativeName(idHex: String, _ authName: String) {
        guard let i = contacts.firstIndex(where: { $0.idHex == idHex }),
              contacts[i].authoritativeName != authName else { return }
        contacts[i].authoritativeName = authName
        save()
    }

    /// Record the signed business card (name + bio + link) a contact shared in the handshake.
    func setCard(idHex: String, name: String, bio: String, link: String, avatar: String = "", emoji: String = "") {
        guard let i = contacts.firstIndex(where: { $0.idHex == idHex }) else { return }
        var changed = false
        if !name.isEmpty, contacts[i].authoritativeName != name { contacts[i].authoritativeName = name; changed = true }
        let newBio = bio.isEmpty ? nil : bio
        let newLink = link.isEmpty ? nil : link
        if contacts[i].bio != newBio { contacts[i].bio = newBio; changed = true }
        if contacts[i].link != newLink { contacts[i].link = newLink; changed = true }
        // Only overwrite avatar/emoji when the peer actually sent one (don't wipe on a legacy blob).
        // Cap the avatar: ours is a ≤192px JPEG (~40KB b64); reject anything an order of magnitude
        // larger so a malformed/hostile card from another client can't bloat storage or hitch the
        // main thread when it's decoded for display.
        if !avatar.isEmpty, avatar.count <= 200_000, contacts[i].avatarB64 != avatar {
            contacts[i].avatarB64 = avatar; changed = true
            avatarCache[contacts[i].idHex] = nil   // decoded cache is stale — re-decode on next read
        }
        if !emoji.isEmpty, contacts[i].emoji != emoji { contacts[i].emoji = emoji; changed = true }
        if changed { save() }
    }

    /// Decoded-avatar cache, keyed by contact idHex. `avatarImage` is called from `PeerAvatar.body`
    /// on EVERY render for EVERY visible row — without this it base64-decoded the string and built a
    /// fresh UIImage (JPEG-decoded on the main thread at draw) every time, which also defeated UIKit's
    /// own decoded-bitmap cache (a new instance each call). That main-thread decode-per-render, times
    /// every avatar on screen, was a major scroll-jank + device-heat source. Invalidated on avatar change.
    private var avatarCache: [String: PlatformImage] = [:]

    /// A contact's shared avatar image (decoded + cached), by node-id prefix — for rendering others' photos.
    func avatarImage(forNodePrefix prefix: String) -> PlatformImage? {
        guard let c = contact(forNodePrefix: prefix) else { return nil }
        if let cached = avatarCache[c.idHex] { return cached }
        guard let b64 = c.avatarB64, let data = Data(base64Encoded: b64), let img = PlatformImage(data: data) else { return nil }
        avatarCache[c.idHex] = img
        return img
    }
    func emoji(forNodePrefix prefix: String) -> String? { contact(forNodePrefix: prefix)?.emoji }

    /// The stored business card for a contact, if any.
    func card(forNodePrefix prefix: String) -> (bio: String?, link: String?)? {
        guard let c = contacts.first(where: { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }) else { return nil }
        return (c.bio, c.link)
    }

    /// Set (or clear, with "") a nickname you chose for this person.
    func setNickname(idHex: String, _ nickname: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = contacts.firstIndex(where: { $0.idHex == idHex || $0.idHex.hasPrefix(idHex) }) else { return }
        contacts[i].nickname = trimmed.isEmpty ? nil : trimmed
        save()
    }

    /// The full node id for a (possibly short) prefix — needed to start a DM from a story.
    func idHex(forNodePrefix prefix: String) -> String? {
        contacts.first { $0.idHex == prefix || $0.idHex.hasPrefix(prefix) }?.idHex
    }

    func remove(_ contact: Contact) {
        contacts.removeAll { $0.idHex == contact.idHex }
        contactRemovedAt[contact.idHex] = nowMs(); persistContactTombstones()   // tombstone so sync can't re-add
        save()
    }

    /// Insert or replace a contact by node id — used by multi-device sync to apply a peer
    /// device's roster. No-op if an identical contact already exists (avoids churn/loops).
    func syncUpsert(_ contact: Contact) {
        if isContactRemoved(contact.idHex) { return }   // a removed contact must not be resurrected by sync
        if let i = contacts.firstIndex(where: { $0.idHex == contact.idHex }) {
            guard contacts[i] != contact else { return }
            contacts[i] = contact
        } else {
            contacts.append(contact)
        }
        save()
    }

    /// Apply a REMOTE contact removal/re-add timestamp (self-sync LWW), keeping the newer per hex and
    /// enforcing the verdict locally. Returns whether the contact is removed after the merge.
    @discardableResult func mergeContactRemovedAt(_ hex: String, ms: UInt64) -> Bool {
        if ms > (contactRemovedAt[hex] ?? 0) { contactRemovedAt[hex] = ms; persistContactTombstones() }
        if isContactRemoved(hex), contacts.contains(where: { $0.idHex == hex }) {
            contacts.removeAll { $0.idHex == hex }; save()
        }
        return isContactRemoved(hex)
    }
    @discardableResult func mergeContactReaddedAt(_ hex: String, ms: UInt64) -> Bool {
        if ms > (contactReaddedAt[hex] ?? 0) { contactReaddedAt[hex] = ms; persistContactTombstones() }
        return isContactRemoved(hex)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
