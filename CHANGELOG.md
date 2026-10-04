# 变更清单

版本：v1.1.0（Gemma 4 本地化 + 整合修复）
基线：`LiveCaptionsTranslator-DeepSeek-Consolidation` 分支（含此前 AutoNotes 补丁）

---

## 一、本次改动文件（6 个）

### `src/utils/AutoNotesService.cs`

| # | 改动 | 说明 |
|---|---|---|
| 1 | 新增 `using System.Diagnostics;` | 进度计时器需要 `Stopwatch` |
| 2 | `HttpClient` 超时 `300s` → `900s` | 原值会让串行逐片合并必然超时 |
| 3 | `CallOllamaAsync` 请求体新增 `think = false` | Gemma 4 默认开 thinking，实测浪费 901 token 且产出相同 |
| 4 | 删除主笔记头部的模型署名行 | `> 本笔记由本地 Ollama 模型 \`xxx\` 自动生成。` |
| 5 | 删除整合稿头部的 HTML 注释行 | `<!-- Updated ... by xxx -->` |
| 6 | 整合前预先切分所有片段 | 得到确定的总片数，作为进度分母 |
| 7 | 整合循环改为逐片播报进度 | 片数 / 已用时间 / 预计剩余 / 当前文件 |
| 8 | 新增 `ProgressChanged` 事件与 `ReportProgress()` | 供前端驱动进度条，含订阅者异常隔离 |
| 9 | 新增 `FormatEta()` | 秒数格式化为 `4m55s` / `1h20m`，含 NaN/Infinity 防护 |
| 10 | `finally` 中 `ReportProgress(null)` | 成功/取消/失败都收回进度条 |

### `src/pages/NotesPage.xaml`

| # | 改动 | 说明 |
|---|---|---|
| 1 | 删除「笔记整理」栏底部建议模型文案 | 该文案指向已弃用的 qwen2.5:7b / deepseek-r1:7b |
| 2 | 新增 `ProgressBar` + 容器 `StackPanel` | 默认 `Collapsed`，由进度事件控制显隐 |

### `src/pages/NotesPage.xaml.cs`

| # | 改动 | 说明 |
|---|---|---|
| 1 | 构造函数订阅 `ProgressChanged` | 与既有的 `StatusChanged` 并列 |
| 2 | `Unloaded` 中一并退订 | 避免页面卸载后残留订阅（原代码只退订了 StatusChanged） |
| 3 | 新增 `OnProgressChanged(double?)` | 有值显示并更新进度条，`null` 隐藏；经 `Dispatcher.Invoke` 回到 UI 线程 |

### `src/models/Setting.cs`

| # | 改动 | 说明 |
|---|---|---|
| 1 | `autoNotesConsolidationModelName` 默认值 | `"deepseek-r1:7b"` → `"gemma4-12b"` → 最终 `"gemma4-e4b"` |

> 注：此处默认值最终为 `gemma4-e4b`；运行配置以 `setting.json` 为准。

### `src/models/WindowState.cs` ⚠️ 未生效

| # | 改动 | 说明 |
|---|---|---|
| 1 | 新增 `CustomFontColor` 字段与属性 | `#RRGGBB` 持久化，非空时优先于 8 色预设 |

**此改动属于取色器功能，因 Smart App Control 拦截而未能部署**（详见 README 第二节）。

### `src/windows/ColorPickerWindow.xaml` / `.xaml.cs` ⚠️ 未生效

| # | 改动 | 说明 |
|---|---|---|
| 1 | 新增取色器窗口 | R/G/B 滑块 + 十六进制输入 + 实时预览 |
| 2 | 「恢复预设」按钮 | 清空自定义色，回退到预设色板 |
| 3 | 十六进制输入容错 | 缺 `#` 自动补全；非法输入标红但不打断用户 |

**同上，因 SAC 拦截未能部署。**

---

## 二、既有文件（7 个，非本次改动）

以下文件是此前 AutoNotes / 整合补丁建立的版本，本次为保持补丁来自洽而一并纳入。
它们与上游原版存在既有差异（整合功能、笔记页面、模型切换逻辑等），**不是本次改动**：

| 文件 | 状态 |
|---|---|
| `src/App.xaml.cs` | 既有 |
| `src/Translator.cs` | 既有 |
| `src/utils/TextUtil.cs` | 既有 |
| `src/windows/MainWindow.xaml` | 既有 |
| `src/windows/OverlayWindow.xaml` | 既有 + **本次新增取色按钮**（未生效） |
| `src/windows/OverlayWindow.xaml.cs` | 既有 + **本次新增取色处理**（未生效） |
| `src/pages/NotesPage.xaml` | 见上文「本次改动」 |

`OverlayWindow.xaml` / `.xaml.cs` 请特别注意：本次为取色器新增了
`FontColorPicker` 按钮、`FontColorPicker_Click`、`ApplyCustomFontColor()`，
以及 `FontColorCycle_Click` 中的一行（循环预设色板时清空自定义色）。
**这些代码存在于包中但未在部署的 DLL 里运行为可用功能。**

---

## 三、配置文件改动（不在本包内）

补丁不修改 `setting.json`。本机实际改动如下，供参考：

| 字段 | 原值 | 新值 |
|---|---|---|
| `Configs.Ollama[0].ModelName` | `qwen2.5:7b` | `gemma4-e4b` |
| `AutoNotesModelName` | `qwen2.5:7b` | `gemma4-e4b` |
| `AutoNotesConsolidationModelName` | `deepseek-r1:7b` | `gemma4-e4b` |

另有本机独有的环境调整（不属于补丁内容）：

- 用户级环境变量 `OLLAMA_CONTEXT_LENGTH=16384`（会用 Modelfile 的 `num_ctx` 绕开）
- `%USERPROFILE%\.ollama\models` 中手动导入的 `gemma4-e4b` / `gemma4-12b`

---

## 四、部署产物

`bin\LiveCaptionsTranslator.dll`

| 项 | 值 |
|---|---|
| MD5 | `C36AD8066B63FE0FB2BC47401403C4D0` |
| SHA256 | `A8FDDE379FB0DBC15459E25473EEDE4C5A417739F563A59A00D32E7EFBD936CE` |
| 大小 | 341,504 B |
| 构建时间 | 2026-10-04 11:45 |
| 基线对比 | 上游原版 332,288 B（+9,216 B） |

该 DLL 已在本机部署并实测：翻译请求 `200 / 0.17～0.58 s`。
