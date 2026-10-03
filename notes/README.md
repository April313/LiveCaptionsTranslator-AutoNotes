# notes —— 笔记输出目录

程序生成的 Markdown 都在这里。

- `note-YYYYMMDD-HHmmss.md` —— 每攒够 N 条字幕生成一份分段笔记，内容含摘要、要点、待办、术语，以及中英对照字幕。
- `consolidated.md` —— 开启「生成后自动整合并清理分段笔记」后，用 `deepseek-r1:7b` 把所有分段笔记合并去重成这一份，并滚动更新。

只有 `consolidated.md` 原子替换成功后，程序才会删除 `note-*.md`；失败或中途取消时分段笔记原样保留。
删除范围严格限定在文件名匹配 `note-*.md` 的文件，你自己放进来的 Markdown 不会被碰。

想换目录（比如直接写进 Obsidian 库）：改 `setting.json` 的 `AutoNotesDirectory` 为绝对路径，
或重新运行 `install.ps1 -NotesDir "D:\Obsidian Vault\LiveCaptions"`。
