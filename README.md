<h3 align="center">🎧 VoiceTap</h3>

<p align="center">
  <strong>Extend voice input to your headset.</strong><br>
  Hold the button on your wired earbuds to talk — release and the text appears.
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

It also handles the other half of the problem: making sure the recording actually goes through the **headset microphone** rather than the built-in one.

## Features

- **Hold to talk** — hold the center button, speak, release. The text lands wherever your cursor is.
- **Single click still works** — play/pause is synthesized back, so you do not lose media control.
- **Volume buttons still work** — same story.
- **Microphone routing** — see which input device is active, switch it from the menu, and optionally auto-switch to the headset mic when you plug in.
- **Warns when the mic is wrong** — headset plugged in but recording through the built-in mic is easy to miss; VoiceTap points it out.
- **Live event monitor** — see exactly which HID events arrive and what gets synthesized. Makes "nothing happened" debuggable.
- **Auto-update** — checks GitHub Releases, installs in place, keeps your permission grants.

## Requirements

- macOS 14+
- Wired headset with inline controls (Apple EarPods and similar)
- An input method with a push-to-talk shortcut (WeType's "hold to talk" is supported out of the box)

## Installation

Download the DMG for your architecture from [Releases](https://github.com/lifedever/VoiceTap/releases/latest), drag to Applications, and launch.

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
| **Input Monitoring** | Read the button presses from the headset |
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
