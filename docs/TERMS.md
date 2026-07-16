# Haven Terms of Use

_Version 1 — July 2026. Agreeing to these terms in the app is required to use Haven._

Haven is a private, end-to-end encrypted space for small circles of people who know each other.
There are no public feeds, no strangers, and no company reading your content — nobody *can* read
it, including the developer. That privacy comes with a responsibility that belongs to you and
your circle, and these terms exist to make that responsibility explicit.

## 1. Zero tolerance

**There is no tolerance for objectionable content or abusive users on Haven.** By using Haven
you agree not to create, share, or solicit:

- Harassment, bullying, or intimidation of any person
- Sexual content involving minors, in any form — reported entries of this category may be
  referred to law enforcement
- Non-consensual intimate imagery
- Threats, incitement of violence, or graphic violence shared to shock or harass
- Hate or discrimination targeting people for who they are
- Spam, scams, phishing, or impersonation
- Anything that is illegal where you live or where the people in your circles live

## 2. How enforcement works

Haven has no central server and the developer holds no decryption keys, so moderation power sits
with the people who actually see the content — the members of each circle:

- **Report** — any member can report a post. The report is shared with the whole circle
  (category and reporter visible) so everyone can act on it.
- **Filter** — media flagged as sensitive (automatically on-device, or by any circle member) is
  blurred for the whole circle.
- **Remove** — any member can remove a person from their circle; removal is immediate and the
  removed person cannot rejoin through them.
- **Block** — blocking drops a person's posts, messages, calls, and connection attempts
  instantly and removes their existing content from your view.

## 3. The moderation ledger

**Blocking is private.** Blocking someone happens entirely on your device and is never reported to
the developer or to anyone else.

When you **report** someone, a **content-free** record is added to a moderation ledger operated by
the developer: the reported identity key, the action, and the offense category. Never the content and
never any personal information. Your report is **signed by your identity key** so that nobody can file
one in your name and a captured report cannot be re-aimed at someone else. Verifying that signature
means your key is transmitted to the developer's server at the moment you report — but it is **not
stored**: the saved record holds only the reported identity, the action, and the category, and its
storage key is derived from a one-way hash of the signature, not from your identity. So the stored
ledger carries **no record of who reported whom**, even though the server briefly sees your key to
confirm the report is genuine. Records are deleted after 90 days.

Identities that accumulate abuse reports may be refused the services the developer does operate
(such as push notification relaying). Because identity keys are free to create, this is a limited
deterrent, not an identification system. Ledger records may be disclosed where legally required,
but they contain only a pseudonymous key, an action, a category, and a time — the developer cannot
link an identity key to a person, produce any content, or say who filed a report.

## 4. Your content and responsibility

You own what you share. Because Haven is end-to-end encrypted, only the members of your circles
receive it — and you are solely responsible for it. The developer cannot access, recover, or
delete your content for you.

## 5. Acceptance

You must agree to these terms before using Haven, and again if they materially change. Using
Haven to violate them is grounds for the enforcement above, at your circle members' discretion
and the developer's, without notice.
