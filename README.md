<h3 align="center">🎧 VoiceTap</h3>

<p align="center">
  <strong>One press, and you are talking to your favorite voice IME.</strong><br>
  Use the headset button or a keyboard shortcut — no manual input-method switching.
</p>

<p align="center">
  <a href="https://github.com/lifedever/VoiceTap/stargazers"><img src="https://img.shields.io/github/stars/lifedever/VoiceTap?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square" alt="Swift">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/">🌐 <strong>Website</strong></a> ｜ <a href="#installation">🚀 <strong>Get Started</strong></a> ｜ <a href="https://www.lifedever.com/">💖 <strong>Sponsor</strong></a>
</p>

<p align="center">
  <a href="README_zh.md">中文文档</a>
</p>

---

## Why

Voice input on macOS means holding `fn` — your hand has to leave whatever it was doing and go back to the keyboard. If you are already wearing earbuds, the button is right there on the cord.

VoiceTap maps that button to your input method's push-to-talk shortcut:

```
headset button --HID--> VoiceTap --synthesized key--> IME push-to-talk --> text
```

There is a nastier half: **an input method only responds to its voice shortcut while it is the active one.** So even if you prefer one vendor's recognition, typing in a different IME means switching over first — and remembering to switch back.

VoiceTap borrows instead of switching: the target IME is held for the few seconds you speak, then handed straight back. Your own input method never changes.

```
hotkey --> borrow target IME --> synthesized key --> text --> restore
```

It also handles a third problem: making sure the recording actually goes through the **headset microphone** rather than the built-in one.

## Features

- **Pick your voice IME** — choose from the input methods installed on your Mac (WeType, Doubao, …). Press the hotkey to talk through it; your own input method is restored the moment it finishes. The list is discovered at runtime, so an IME you install later shows up on its own.
- **Global hotkey** — works in any app, with no headset plugged in.
- **Hold to talk** — hold the center button, speak, release. The text lands wherever your cursor is.
- **Single click still works** — play/pause is synthesized back, so you do not lose media control.
- **Volume buttons still work** — same story.
- **Microphone routing** — see which input device is active, switch it from the menu, and optionally auto-switch to the headset mic when you plug in.
- **Warns when the mic is wrong** — headset plugged in but recording through the built-in mic is easy to miss; VoiceTap points it out.
- **Live event monitor** — see exactly which HID events arrive and what gets synthesized. Makes "nothing happened" debuggable.
- **Auto-update** — checks GitHub Releases, installs in place and relaunches. macOS will ask you to re-grant permissions after an update.

## Requirements

- macOS 14+
- At least one input method with voice input (WeType, Doubao, … — works out of the box)
- Only if you want the headset trigger: wired earbuds with inline controls (Apple EarPods and similar)

## Installation

Download the DMG for your architecture from [Releases](https://github.com/lifedever/VoiceTap/releases/latest) and drag it to Applications.

If macOS says the developer cannot be verified, open **System Settings → Privacy & Security**, scroll down to VoiceTap and click **Open Anyway**. Or, from a terminal:

```bash
xattr -dr com.apple.quarantine /Applications/VoiceTap.app
```

Or build from source:

```bash
git clone https://github.com/lifedever/VoiceTap.git
cd VoiceTap
./build.sh && ./install.sh
```

## Permissions

VoiceTap needs two permissions. **Without either one it fails silently** — pressing the button does nothing, with no error. The app checks on launch and shows exactly what is missing.

| Permission | Why |
|---|---|
| **Input Monitoring** | Read headset button presses and the global hotkey |
| **Accessibility** | Send the shortcut to your input method |

## How it works

VoiceTap does not know your input method exists. It just **presses a key** — whoever listens for that key responds. So the only rule is:

> Set VoiceTap's trigger key to the same shortcut your input method uses for push-to-talk.

Open **Settings** and click the trigger key field to record any combination you like — a bare modifier such as `fn`, or something like `⌃⌥⌘Z`. It defaults to `fn`, which matches WeType's factory setting, so it usually works with no configuration at all.

If a bare `fn` proves unreliable with your input method, record a regular combination instead and change the input method's shortcut to match. `fn` is a special modifier and travels a different code path than normal keys.

## Troubleshooting

Open **Event Monitor** from the menu, then hold the button.

| What you see | What it means |
|---|---|
| Nothing at all | The button press is not reaching the app — check Input Monitoring |
| `Center button pressed` but nothing after | Below the long-press threshold — try lowering it in the menu |
| `Long press → pressing fn` but no voice input | The synthesized key is not reaching the IME — switch to a regular key combination |

## License

MIT © lifedever
