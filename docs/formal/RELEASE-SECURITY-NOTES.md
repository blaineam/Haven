# Security release notes (2.1.3)

Working copy for the release that ships the circle key tree fix. Three parts: what the problem
means in plain words, the text for each store's reviewer, and the text users see.

## 1. Impact, in plain words

**What Haven promised.** Two things about circles, beyond ordinary end-to-end encryption:

* *Forward secrecy*: if someone steals a device's keys today, they still cannot read what the
  circle said before today.
* *Healing* (post-compromise security): once a compromised device is removed, or simply after the
  circle's keys next change, the thief is locked out again.

**What was actually true.** Ordinary end-to-end encryption held: a relay, a network observer, or
anyone outside a circle could not read a post, and that never changed. The two extra promises did
not hold against one specific theft. The circle's key tree computed its secrets from each device's
permanent identity seed and rebuilt them from the circle's first key change every time. So the
identity seed alone was enough to rebuild every key the device had ever held or would hold in that
circle.

**What an attacker needed.** Both of these:

1. A member device's secret identity seed. That means malware running as the user on that device,
   a forensic copy of an unlocked device, or a copy of the app's data from an unencrypted backup.
   It cannot be obtained over the network, from a relay, or from another member.
2. The circle's encrypted traffic, for example by running or compromising a relay the circle
   uses, or by recording the network.

**What they got.** Everything that device could read in its circles, including posts from before
the theft, and everything posted afterwards until the device was revoked. Removing a *different*
member or waiting for keys to rotate did not shut them out, which is the part a user would not
expect.

**What they did not get.** Other circles the device was not in. Anything from a circle after the
device was revoked. Direct access to anyone else's device. The ability to post as someone else
beyond what holding that device's keys already allows.

**How serious.** High as a broken promise: the documented guarantee was absent. Moderate as a
practical risk: someone who already controls a device can read what that device shows on screen
anyway, so the real loss is (a) the history from before the compromise and (b) the circle not
healing afterwards. It is the difference between "Signal-like" and "encrypted, but a stolen
device key is a skeleton key for that circle".

**Is anyone known to be affected?** No exploitation is known. Haven keeps no logs and runs no
central server, so there is also no record that could show it; that is stated plainly rather than
as reassurance.

**What the update does.** Tree secrets become random and are never derived from the identity
seed; each device stores only the state it needs and deletes older secrets; every member device
refreshes its own keys; new members are welcomed to one-time keys. A circle moves to the new tree
automatically once all of its members' devices run the update. Nothing is asked of the user and
every existing post stays readable.

**What the update cannot do.** Traffic recorded before a circle moved stays protected only by the
old keys. If a device seed from that period is stolen later, that old traffic is still exposed.
The remaining limits of the new design are listed in `PROTOCOL-SPEC.md` §15.1.

**What backs the claim.** Machine-checked symbolic proofs of the design as built (Tamarin), tests
that tie the code to the model, and CI jobs that re-run each when its inputs change. Not a
computational proof and not an outside audit; both are named as future work.

## 2. Reviewer notes

Short, at the top of the review notes for this version only, so a reviewer sees why it is urgent.

### Apple (App Review notes, iOS and macOS) — also the text for the expedite request

```
SECURITY UPDATE — PLEASE PRIORITISE
Version 2.1.3 is a security patch with no new features and no UI changes.
It fixes a weakness in how the app protects group ("circle") encryption keys: if an
attacker had already stolen a device's secret key, they could also read that circle's
earlier messages and were not locked out when keys rotated. Severity: high. It is not
remotely exploitable and no exploitation is known, but users stay exposed until they update.
The fix is applied automatically in the background; users do nothing and lose no content.
Nothing reviewable has changed: same screens, same permissions, same entitlements, same data
collection (none). The usual review walkthrough below still applies.
```

### Google Play (release notes are public; this goes in the review/expedite contact, not the listing)

```
Security patch, no feature or UI change. Fixes a weakness in group encryption key handling
that let an attacker who had already stolen a device's secret key read earlier group messages
and stay in after key rotation. Severity high, not remotely exploitable, no known exploitation.
Applied automatically; no permissions, data-safety or policy declarations change.
```

### Microsoft Store (Notes for certification)

```
Security patch release. No new features, no UI changes, no new capabilities or permissions.
Fixes a high-severity weakness in group encryption key handling (an attacker who had already
stolen a device's secret key could read earlier group messages and was not locked out when keys
rotated). Not remotely exploitable; no known exploitation. Please certify promptly so users
receive the fix. Test steps are unchanged from the previous submission.
```

## 3. What users see

Kept calm and short; the full account is the CHANGELOG entry and the GitHub security advisory.

```
2.1.3 — Security update. Please update all your devices.
• Stronger protection for your circles' encryption keys if a device is ever compromised.
  It applies automatically once everyone in a circle has updated. Your posts are untouched.
```
