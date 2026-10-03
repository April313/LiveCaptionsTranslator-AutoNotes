# LiveCaptionsTranslator-AutoNotes

Windows 11 实时字幕翻译与本地自动笔记工具。项目基于 [SakiRinn/LiveCaptions-Translator](https://github.com/SakiRinn/LiveCaptions-Translator)，增加 Auto Notes：通过本机 Ollama 将已完成字幕整理为 Markdown，并可用 DeepSeek-R1 合并去重。

## 使用

1. 下载 GitHub Releases 中的 `LiveCaptionsTranslator-AutoNotes.exe`，或自行按 `源码补丁/说明.md` 编译。
2. 解压后运行 `install.ps1` 初始化配置；也可直接双击 `启动.cmd`。
3. 按 `使用说明.md` 配置 Windows 实时字幕与 Ollama。

默认模型：`qwen2.5:7b`（生成笔记）和 `deepseek-r1:7b`（整合去重），服务地址为 `http://localhost:11434`。

## 仓库内容

- `源码补丁/`：相对上游项目的源码改动与编译脚本
- `docs/`：自动笔记、笔记整合和 Obsidian 配置说明
- `install.ps1`、`launch.ps1`：初始化与启动脚本
- `fdd/`：框架依赖版运行文件

单文件自包含 EXE 超过 GitHub 普通文件大小限制，因此作为 Release 附件发布，不纳入 Git 历史。

## 授权

请同时遵守上游项目及本仓库所附 `LICENSE.txt` 的许可条款。
