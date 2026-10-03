# 与 Obsidian 配合使用

Auto Notes 输出的是普通 Markdown，任何编辑器都能看。如果你用 Obsidian，这里是把笔记接进库的几种做法，以及对笔记做二次整理的可选配置。

## 把这个包的目录结构记一下

Auto Notes 把笔记写到程序目录下的 `notes\`（可以在 Auto Notes 页改成任意绝对路径）：

```text
<解压目录>\notes\
├─ note-20261004-101500.md     ← 分段笔记（每 N 条字幕一份）
├─ note-20261004-102500.md
└─ consolidated.md              ← 整合去重后的那一份
```

## 方案 A（推荐）：直接把 notes 当 Vault 打开

Obsidian → **Open folder as vault** → 选 `<解压目录>\notes`。

零配置、零延迟。缺点是笔记和程序目录绑在一起，移动程序目录要重新打开。

## 方案 B：写进已有的 Vault（改一个配置项就行）

把 Auto Notes 页的「笔记保存目录」改成 Vault 里的绝对路径即可，比如
`D:\Obsidian Vault\LiveCaptions`，也可以重新初始化一次：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1 -NotesDir "D:\Obsidian Vault\LiveCaptions"
```

想反过来（程序目录不变、Vault 里能看到）可以用目录联接（junction，不需要管理员）：

```cmd
mklink /J "D:\Obsidian Vault\LiveCaptions" "<解压目录>\notes"
```

Obsidian 重新加载 Vault 后即可看到。

> 注意：把笔记目录放在 OneDrive / 坚果云等同步盘里时，注意同步冲突；`consolidated.md` 是持续改写的，同步盘上容易产生冲突副本。

## 可选：在 Obsidian 里做二次整理

社区插件 **Local LLM Helper**（<https://github.com/manimohans/obsidian-local-llm-helper>）可以接着本机的 Ollama 继续加工笔记：摘要、抽取行动项、跨笔记关联、语义检索。

安装：`Settings → Community plugins → Browse` → 搜 **Local LLM Helper** → Install → Enable。
（网络受限时可以手动把 `main.js` / `manifest.json` / `styles.css` 放进
`<Vault>\.obsidian\plugins\local-llm-helper\`）

然后 `Settings → Local LLM Helper`：

| 设置项 | 值 |
|---|---|
| Provider | `Ollama` |
| Chat / default server URL | `http://localhost:11434` |
| Chat model | `qwen2.5:7b` |
| Embedding model | `nomic-embed-text` |

语义检索（RAG / Related Notes / Vault Radar）需要**嵌入模型**，`qwen2.5:7b` 不能当嵌入用：

```powershell
ollama pull nomic-embed-text     # 约 274 MB
```

装好后：

1. `Ctrl+P` → **Vault Radar: Open** → *Run now*：把最近变动的笔记整理成带引用的简报卡片。
2. `Ctrl+P` → **Notes: Index notes for RAG**：用嵌入模型建索引（只跑一次，之后增量）。
3. 处理当前笔记：命令面板里的 *Summarize* / *Generate action items*。

隐私：插件自身无遥测、无云端后端，只发往你配置的 endpoint；`http://localhost:11434` 表示内容不出本机。唯一的例外是你在 Vault Radar 里主动点了 Web search。

## 排错

| 现象 | 处理 |
|---|---|
| Auto Notes 一直显示 disabled | 打开页内开关；开关状态存在 `setting.json` 的 `AutoNotesEnabled` |
| 状态显示 `Auto note failed: ...` | 确认 `ollama serve` 在跑、模型名拼写正确；首次调用要等模型加载（7B 约 5~15 秒） |
| 摘要很慢 | 把「每多少条字幕生成一次」调大（20→30），或换 `qwen2.5:3b` |
| 笔记里中文乱码 | 用 Obsidian/VSCode 打开（UTF-8）；别用记事本另存为 ANSI |
| Obsidian 看不到新笔记 | 重新加载 Vault，或检查 Auto Notes 页里的目录设置 |
| Local LLM Helper 检索为空 | 没装嵌入模型，或没跑 *Notes: Index notes for RAG* |
| 整合后的笔记丢了分段内容 | 不会丢：`consolidated.md` 原子替换成功后才删 `note-*.md`（详见 `笔记整合与去重.md`） |
