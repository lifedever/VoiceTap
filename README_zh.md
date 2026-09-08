<h3 align="center">🎧 VoiceTap</h3>

<p align="center">
  <strong>随手一按，就用你惯用的语音输入法说话</strong><br>
  按耳机线控或键盘快捷键说话，松开即成文字——不必手动切换输入法。
</p>

<p align="center">
  <a href="https://github.com/lifedever/VoiceTap/stargazers"><img src="https://img.shields.io/github/stars/lifedever/VoiceTap?style=flat-square&color=F59E0B&label=Stars" alt="Stars"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?style=flat-square" alt="Platform">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square" alt="Swift">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <a href="https://www.lifedever.com/">🌐 <strong>官网</strong></a> ｜ <a href="#安装">🚀 <strong>快速开始</strong></a> ｜ <a href="https://www.lifedever.com/">💖 <strong>赞助</strong></a>
</p>

<p align="center">
  <a href="README.md">English</a>
</p>

---

## 为什么做这个

macOS 上用语音输入要长按 `fn`——手必须从当前动作离开、回到键盘。而如果你正戴着耳机，那颗按钮就在线上，触手可及。

VoiceTap 把线控按钮映射到输入法的「按住说话」快捷键：

```
线控按键 --HID--> VoiceTap --合成按键--> 输入法 PTT --> 出字
```

还有更麻烦的一半：**输入法只有在自己是当前输入法时才响应语音快捷键**。所以哪怕你更喜欢某一家的识别效果，只要正在用别的输入法打字，就得先切过去——切完还得记得切回来，打字习惯全乱。

VoiceTap 的做法是「借一下就还」：按住快捷键的那几秒把目标输入法借过来，说完立刻还回去。你的默认输入法始终不变。

```
键盘快捷键 --> 借用目标输入法 --> 合成按键 --> 出字 --> 归还
```

它还解决了第三个问题：确保录音真的走**耳机麦克风**，而不是电脑内置麦。

## 功能

- **指定语音输入法** —— 从本机装的输入法里挑一个（微信输入法、豆包输入法……），按下快捷键就用它说话，说完自动切回你原来的输入法。名单是运行时发现的，以后装了别的语音输入法会自动出现。
- **全局快捷键** —— 在任何 App 里按下都能说话，不需要插耳机。
- **按住说话** —— 长按中键，说话，松开。文字落在光标处。
- **单击照常控制播放** —— 播放/暂停被合成回去，不会因为接管线控而失去媒体控制。
- **音量键照常可用** —— 同上。
- **麦克风输入源管理** —— 查看当前输入设备、从菜单直接切换，也可以设置成插入耳机时自动切到耳机麦。
- **麦克风走错会提示** —— 耳机插着却在用内置麦录音，这件事用户很难自己察觉，VoiceTap 会直接指出来。
- **实时事件监视器** —— 看清楚抓到了哪些 HID 事件、合成了什么按键。让「按了没反应」变得可排查。
- **自动更新** —— 检查 GitHub Releases，原地安装，权限授权不丢失。

## 环境要求

- macOS 14+
- 至少一个带语音输入的输入法（微信输入法、豆包输入法等，开箱即用）
- 想用线控触发的话，还需要一副带线控的有线耳机（Apple EarPods 及同类）；只用键盘快捷键则不需要

## 安装

从 [Releases](https://github.com/lifedever/VoiceTap/releases/latest) 下载对应架构的 DMG，拖进「应用程序」。

首次打开如果提示无法验证开发者，去「系统设置 → 隐私与安全性」往下找到 VoiceTap，点「仍要打开」。嫌麻烦也可以在终端跑一行：

```bash
xattr -dr com.apple.quarantine /Applications/VoiceTap.app
```

或从源码构建：

```bash
git clone https://github.com/lifedever/VoiceTap.git
cd VoiceTap
./build.sh && ./install.sh
```

## 权限

VoiceTap 需要两个权限。**缺任何一个都会静默失效**——按线控毫无反应，也不报错。所以 app 启动时会主动检查并明确告诉你缺哪一项。

| 权限 | 用途 |
|---|---|
| **输入监控** | 读取耳机线控和键盘快捷键 |
| **辅助功能** | 把快捷键发送给输入法 |

## 工作原理

VoiceTap 并不知道输入法的存在，它只是**按下某个键**——谁监听那个键谁响应。所以规则只有一条：

> 把 VoiceTap 的触发键设成和输入法「按住说话」相同的快捷键。

打开**设置**，点击触发键输入框即可录制任意组合：单独一个 `fn`，或者 `⌃⌥⌘Z` 这样的组合都行。默认是 `fn`，与微信输入法的出厂设置一致，通常不需要任何配置。

如果单独的 `fn` 在你的输入法上不稳定，就录一个普通组合键，再把输入法的快捷键改成同一个。`fn` 是特殊修饰键，走的代码路径和普通按键不同。

## 排查

菜单 → **事件监视器**，然后长按线控。

| 看到什么 | 说明 |
|---|---|
| 什么都没有 | 按键没到达 app —— 检查「输入监控」权限 |
| 有 `中键(播放/暂停) 按下`，之后没了 | 没达到长按阈值 —— 在菜单里把阈值调小 |
| 有 `长按 → 按下 fn`，但语音没起来 | 合成的按键没被输入法接受 —— 换成普通组合键 |

## 许可证

MIT © lifedever
