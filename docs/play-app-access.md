# Google Play — App access (Sign in details)

Paste this into **Play Console → Haven → Policy → App content → App access**, choosing
**"All or some functionality is restricted"** and adding one instruction entry. Option
"available without special access" is technically true but is what got version 1285 rejected:
the reviewer read the first screen as a login wall and had nothing telling them otherwise.

**Name of the flow**
```
First run — no account, no sign-in required
```

**Instructions**
```
Haven has no accounts, no sign-in, and no servers holding user data. No credentials exist to
give you, so none are needed to review the app.

On first launch the app shows three choices. Tap the FIRST one:

  "I'm new to Haven"

Then type any display name (for example "Reviewer"), optionally pick an emoji or photo, and tap
Continue. The app creates a private identity on the device itself and opens directly into the
app. Every feature is then available.

The other two choices are for people who already use Haven on another device:
  - "Add this as another of my devices" and "Move my account to this device" ask for a code that
    the person's OWN other device generates (You > Link a new device). They are not a login wall
    and are not needed to review the app — please use "I'm new to Haven".

Haven is peer to peer: content travels directly between devices the user has added to their own
circle, or through a relay the user chooses. To see two devices talk to each other, install the
app on a second device, tap the people icon in the Circle header, choose add friend, and scan the
QR code shown there with the second device.

No username, password, PIN, QR code or other resource is required to reach any part of the app.
```
