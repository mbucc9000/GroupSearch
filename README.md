<img src="icon.png" width="80" align="right" alt="">

# GroupSearch

Find group chats from the To: field in iOS 6 Messages. Type part of a group's name in a new message and the group shows up with your contacts; tap it to add everyone in it.

## Features

- Matching group chats show above your contacts in the To: suggestions, with the members' first names underneath.
- Any word of the name works, and case and accents don't matter.
- Tap a group and everyone in it is added at once, the same way Messages adds a contact you tap.
- With ComposeHistory, the group's conversation shows right away.
- Group names come from GroupChatNameFix, since iOS 6 has no group names of its own. Only named groups show.

## How to use

1. Name your group chats with GroupChatNameFix.
2. In Messages, start a new message and type part of a group's name in the To: field.
3. Tap the group in the suggestions to add everyone in it.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate (Cydia installs them for you)

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **GroupSearch**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.
