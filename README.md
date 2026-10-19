# Polish：双击空格，用大模型润色输入框

一个原生 macOS 小工具（Swift / AppKit + SwiftUI，无第三方依赖）。在任意应用的输入框里**快速连按两次空格**，Polish 会把整个输入框的内容交给大模型润色，然后替换回去。按 **⌘Z** 撤销润色。

## 功能

- **双击空格触发**：第二个空格会被吞掉，不会输入进去。间隔可调（默认 0.35 秒）。
- **目标语言可选**：默认英文；也可以选中文、日语、韩语、法语、德语、西班牙语、俄语、「保持原语言」，或者自定义。输入其他语言时会边翻译边润色。
- **语气**：内置 学术（默认）/ 正式 / 商务 / 口语 / 友好 / 简洁 / 仅纠错，每个语气的提示词都能改，也能新增或删除语气。
- **自定义提示词**：系统提示词模板可以编辑，占位符为 `{language}` 和 `{tone}`。
- **Provider / 模型**：可以自由添加。支持两种接口：
  - **OpenAI 兼容**（`/chat/completions`）：OpenAI、DeepSeek、通义千问、Kimi、智谱、Gemini、OpenRouter、Ollama / LM Studio 等
  - **Anthropic**（`/v1/messages`）：默认 `claude-opus-5-5`，effort 设为 `low` 以加快响应
- **撤销**：润色后的第一次 ⌘Z 恢复原文（对所有应用都有效），⇧⌘Z 重新应用润色。之后的 ⌘Z 交还给应用本身。
- **后台常驻**：平时只显示菜单栏图标，不占 Dock。打开设置窗口时 Dock 图标才出现，关闭窗口后自动隐藏、继续在后台运行。菜单栏图标可以快速切换语言、语气和模型，或打开设置；再次从「应用程序」或 Spotlight 打开 Polish 也会弹出设置。
- **登录时自动启动**：在设置 › 通用 ›「启动」中开关（使用系统的登录项机制，也可以在「系统设置 › 通用 › 登录项」里管理）。
- **安全措施**：
  - 在终端和代码编辑器里默认不触发（排除列表可编辑）
  - 在列表、按钮、网页正文等非输入区域连按空格不会触发
  - 密码框不会触发
  - 超过字数上限时不处理
  - 润色过程中按 Esc 或继续打字会取消
  - 如果输入焦点已经换到别处，结果只复制到剪贴板，不会粘贴

## 下载安装

在 [Releases](https://github.com/JoeZhang-0x000/polish-mac/releases) 下载 `Polish-<版本>.dmg`，打开后把 Polish 拖进「应用程序」。支持 Apple 芯片和 Intel，需要 macOS 13 及以上。

这个 App 没有经过 Apple 公证，第一次打开时 macOS 会拦截。解决方法任选其一：

- 在「应用程序」里右键 Polish → 打开 → 打开
- 或者在终端运行 `xattr -dr com.apple.quarantine /Applications/Polish.app`，然后正常打开

## 构建与安装

需要 macOS 13 及以上，并安装 Xcode 或 Command Line Tools。

```bash
./scripts/build_app.sh --install
```

不加 `--install` 时只生成 `build/Polish.app`。

打包发布用的 DMG（通用二进制，同时支持 Apple 芯片和 Intel）：

```bash
VERSION=0.0.1 ./scripts/make_dmg.sh   # 输出 dist/Polish-0.0.1.dmg
```

首次启动后，在 **系统设置 › 隐私与安全性 › 辅助功能** 中允许 Polish。授权后菜单栏图标会从 ⚠️ 变成魔法棒。然后打开设置，在「模型服务」里填写 API Key，再点「测试润色」确认能用。

### 让授权在重新编译后保留（推荐，只需做一次）

```bash
./scripts/setup_signing.sh
```

这个脚本会在登录钥匙串里创建一张只在本机使用的自签名代码签名证书「Polish Local Signing」。macOS 会要求输入一次登录密码，用来把它标记为可信。之后 `build_app.sh` 会自动用它签名。切换后需要最后一次重新授权，以后再编译就不用了。

为什么需要这样做：没有证书时用的是 ad-hoc 签名，macOS 只能用二进制文件的哈希（cdhash）来识别应用，每次编译哈希都会变，系统就把它当成一个新应用，旧的授权失效。设置里那一条看起来还是打开的，其实属于旧的版本，所以必须删掉后重新添加。用固定证书签名后，系统按「Bundle ID + 证书」来识别应用，重新编译也不会变。

如果你有自己的签名证书，也可以用 `SIGN_IDENTITY="证书名" ./scripts/build_app.sh`。

## 工作原理

1. 用 `CGEventTap` 监听键盘，检测两次间隔很短的空格。
2. 通过辅助功能 API 判断当前焦点是否是可编辑的文本控件。
3. 模拟 ⌘A、⌘C 读取输入框内容，然后立即恢复你原来的剪贴板。
4. 调用所选模型。
5. 模拟 ⌘A、⌘V 写回润色结果，再恢复剪贴板。写入的临时内容带有 `org.nspasteboard.TransientType` 标记，剪贴板管理器会忽略它。
6. 记住原文；紧接着的 ⌘Z 会把原文粘贴回去。

因为用的是 ⌘A，Polish 处理的是**整个输入框**的内容，适合聊天框、邮件、表单和搜索框。在长文档编辑器里请谨慎使用，或者把这类应用加入排除列表。

配置文件（包含 API Key）保存在 `~/Library/Application Support/Polish/config.json`，权限为 600，只有当前用户可读。

## 代码结构

| 文件 | 作用 |
|---|---|
| `Sources/Polish/KeyMonitor.swift` | 全局键盘监听：双击空格、Esc、⌘Z / ⇧⌘Z |
| `Sources/Polish/PolishController.swift` | 一次润色的完整流程，以及撤销 / 重做 |
| `Sources/Polish/TextBridge.swift` | 模拟按键、剪贴板快照、辅助功能焦点检测 |
| `Sources/Polish/LLMClient.swift` | OpenAI 兼容接口和 Anthropic 接口的请求 |
| `Sources/Polish/Config.swift` | 配置模型、默认语气 / 提示词 / Provider、JSON 持久化 |
| `Sources/Polish/SettingsView.swift` | SwiftUI 设置界面 |
| `Sources/Polish/AppDelegate.swift` | Dock 菜单、菜单栏、主菜单、权限轮询 |
| `Sources/Polish/HUD.swift` | 光标附近的浮动提示 |
