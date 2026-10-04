using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LiveCaptionsTranslator.models;

namespace LiveCaptionsTranslator.utils
{
    /// <summary>
    /// Collects logged captions, creates local notes with Ollama, and optionally
    /// consolidates completed note files into one Markdown file.
    /// </summary>
    public static class AutoNotesService
    {
        // 900s：本地模型在 8GB 显卡上会有部分层落在 CPU，冷加载本身就可能耗时数分钟；
        // 300s 会在「已有整合稿 + 全部分段笔记」的串行逐片合并中被打满，导致整合整体失败。
        private static readonly HttpClient client = new() { Timeout = TimeSpan.FromSeconds(900) };
        private static readonly object sync = new();
        private static readonly List<TranslationHistoryEntry> buffer = [];
        private static CancellationTokenSource? cts;
        private static bool started;
        private static bool generating;

        public static event Action<string>? StatusChanged;
        /// <summary>整合进度：0.0～1.0；null 表示没有进行中的整合（用于隐藏进度条）。</summary>
        public static event Action<double?>? ProgressChanged;
        public static string LastStatus { get; private set; } = "Auto notes is disabled.";

        public static void Start()
        {
            if (started)
                return;
            started = true;
            Translator.TranslationLogged += OnTranslationLogged;
            cts = new CancellationTokenSource();
            _ = Task.Run(() => MonitorAsync(cts.Token));
            Publish(Translator.Setting.AutoNotesEnabled ? "Auto notes is ready." : "Auto notes is disabled.");
        }

        public static void Stop()
        {
            cts?.Cancel();
            Translator.TranslationLogged -= OnTranslationLogged;
            started = false;
        }

        private static async void OnTranslationLogged()
        {
            try
            {
                var entry = await SQLiteHistoryLogger.LoadLastTranslation();
                if (entry == null || string.IsNullOrWhiteSpace(entry.SourceText))
                    return;
                lock (sync)
                    buffer.Add(entry);
            }
            catch (Exception ex)
            {
                Publish($"Unable to collect caption: {ex.Message}");
            }
        }

        private static async Task MonitorAsync(CancellationToken token)
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    if (Translator.Setting.AutoNotesEnabled && !generating)
                    {
                        List<TranslationHistoryEntry>? batch = null;
                        lock (sync)
                        {
                            if (buffer.Count >= Math.Max(1, Translator.Setting.AutoNotesInterval))
                            {
                                batch = [.. buffer];
                                buffer.Clear();
                            }
                        }
                        if (batch != null)
                            await GenerateNoteAsync(batch, token);
                    }
                    await Task.Delay(1000, token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    Publish($"Auto note error: {ex.Message}");
                    await Task.Delay(3000, token);
                }
            }
        }

        public static async Task GenerateNowAsync(CancellationToken token = default)
        {
            List<TranslationHistoryEntry> batch;
            lock (sync)
            {
                batch = [.. buffer];
                buffer.Clear();
            }
            if (batch.Count == 0)
            {
                Publish("No new captions to summarize.");
                return;
            }
            await GenerateNoteAsync(batch, token);
        }

        /// <summary>整合全部分段笔记（「立即整合并清理（全部）」走这里）。</summary>
        public static async Task ConsolidateNowAsync(CancellationToken token = default)
        {
            if (generating)
            {
                Publish("Another note operation is already running.");
                return;
            }
            await ConsolidateNotesAsync(ResolveNotesDirectory(), token);
        }

        private static async Task GenerateNoteAsync(List<TranslationHistoryEntry> entries, CancellationToken token)
        {
            if (generating || entries.Count == 0)
                return;
            generating = true;
            try
            {
                Publish($"Summarizing {entries.Count} captions with Ollama...");
                var transcript = new StringBuilder();
                foreach (var entry in entries)
                {
                    transcript.AppendLine($"[{entry.TimestampFull}] English: {entry.SourceText}");
                    if (!string.IsNullOrWhiteSpace(entry.TranslatedText) && entry.TranslatedText != "N/A")
                        transcript.AppendLine($"Chinese: {entry.TranslatedText}");
                }

                string prompt = "You are an offline meeting and lecture note taker. " +
                    "Summarize the transcript below in Simplified Chinese. " +
                    "Return Markdown only with exactly these headings: " +
                    "## 摘要, ## 关键要点, ## 待办事项, ## 重要术语. " +
                    "Do not invent facts. If a section has no information, write 无。\n\n" + transcript;
                string note = await CallOllamaAsync(Translator.Setting.AutoNotesModelName,
                    "You create concise, factual Markdown notes.", prompt, 0.2, token);

                string directory = ResolveNotesDirectory();
                Directory.CreateDirectory(directory);
                string filename = $"note-{DateTime.Now:yyyyMMdd-HHmmss}.md";
                string header = $"# 自动笔记 {DateTime.Now:yyyy-MM-dd HH:mm:ss}\n\n";
                string source = "\n\n---\n\n## 原始字幕\n\n" + transcript;
                await File.WriteAllTextAsync(Path.Combine(directory, filename), header + note.Trim() + source, Encoding.UTF8, token);
                Publish($"Saved: {Path.Combine(directory, filename)}");

                if (Translator.Setting.AutoNotesConsolidateEnabled)
                    await ConsolidateNotesAsync(directory, token);
            }
            catch (OperationCanceledException)
            {
                Publish("Auto note canceled.");
            }
            catch (Exception ex)
            {
                Publish($"Auto note failed: {ex.Message}");
            }
            finally
            {
                generating = false;
            }
        }

        private const int ConsolidationChunkChars = 12000;

        /// <summary>用户自选笔记栏的标题（整合时原样保留，不喂模型、不重写）。</summary>
        private const string CustomSectionHeading = "## 我的笔记（自选）";

        // 新格式：[ts] 原文: …   旧格式：[ts] English: …
        private static readonly Regex CaptionLineRegex = new(
            @"^\[(?<ts>[^\]]+)\]\s*(?:English:|原文[:：])\s*(?<en>.*)$", RegexOptions.Compiled);

        // 新格式：[ts] 译文: …（中文原声没有这一行）
        private static readonly Regex TranslationLineRegex = new(
            @"^\[(?<ts>[^\]]+)\]\s*(?:Chinese:|译文[:：])\s*(?<zh>.*)$", RegexOptions.Compiled);

        /// <summary>
        /// 只整合指定的分段笔记（用户在 Auto Notes 页勾选的那些）。
        /// fileNames 为 null 或空集合时整合全部。
        /// </summary>
        public static async Task ConsolidateSelectedAsync(IEnumerable<string>? fileNames, CancellationToken token = default)
        {
            if (generating)
            {
                Publish("Another note operation is already running.");
                return;
            }
            string[] names = fileNames?
                .Where(n => !string.IsNullOrWhiteSpace(n))
                .Select(n => Path.GetFileName(n))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray() ?? Array.Empty<string>();
            await ConsolidateNotesAsync(ResolveNotesDirectory(), token, names);
        }

        private static async Task ConsolidateNotesAsync(string directory, CancellationToken token,
            IReadOnlyCollection<string>? onlyNames = null)
        {
            Directory.CreateDirectory(directory);
            string consolidatedPath = Path.Combine(directory, Translator.Setting.AutoNotesConsolidatedFileName);
            // 新的笔记排在前面：折叠时最新内容先进入整合稿
            string[] notePaths = Directory.GetFiles(directory, "note-*.md")
                .Where(path => !string.Equals(Path.GetFileName(path),
                    Translator.Setting.AutoNotesConsolidatedFileName, StringComparison.OrdinalIgnoreCase))
                .Where(path => onlyNames == null || onlyNames.Count == 0 ||
                               onlyNames.Contains(Path.GetFileName(path), StringComparer.OrdinalIgnoreCase))
                .OrderByDescending(path => Path.GetFileName(path), StringComparer.OrdinalIgnoreCase)
                .ToArray();

            if (notePaths.Length == 0)
            {
                Publish(onlyNames is { Count: > 0 }
                    ? "所选笔记都不存在（可能在别处已被整合或删除）。"
                    : File.Exists(consolidatedPath) ? "No new note files to consolidate." : "No note files to consolidate.");
                return;
            }

            string toastSummary = "整合未完成";

            try
            {
                Publish($"Consolidating {notePaths.Length} note file(s) with {Translator.Setting.AutoNotesConsolidationModelName}...");
                string existingText = File.Exists(consolidatedPath)
                    ? await File.ReadAllTextAsync(consolidatedPath, token)
                    : string.Empty;
                // 用户自写的「我的笔记」段先取出，整整合过程都不喂模型、最后原样放回
                string existingWithoutCustom = ExtractCustomSection(existingText, out string customNotes);
                string running = StripTranscript(RemoveThinkingTags(existingWithoutCustom)).Trim();

                // 原文要累积：已有整合稿里的「完整原文」+ 本次新笔记的「原始字幕」一起去重，
                // 否则每整合一次就会把历史原文覆盖掉。
                var allCaptions = new List<(string Ts, string En, string Zh)>();
                if (existingText.Length > 0)
                    allCaptions.AddRange(ExtractCaptions(existingText));

                // 先把要喂模型的片段全部切好，才能给出确定的总片数（进度分母）。
                var work = new List<(string File, string Chunk)>();
                foreach (string path in notePaths)
                {
                    string body = await File.ReadAllTextAsync(path, token);
                    allCaptions.AddRange(ExtractCaptions(body));
                    foreach (string chunk in SplitIntoChunks(StripTranscript(body), ConsolidationChunkChars))
                        work.Add((Path.GetFileName(path), chunk));
                }

                if (work.Count == 0)
                    throw new InvalidDataException("No consolidatable content in the selected notes.");

                int total = work.Count;
                int passes = 0;
                var watch = Stopwatch.StartNew();
                ReportProgress(0);
                Publish($"整合中：0/{total} 片（{notePaths.Length} 个笔记，模型 {Translator.Setting.AutoNotesConsolidationModelName}）");

                foreach (var (fileName, chunk) in work)
                {
                    int current = passes + 1;
                    Publish($"整合中：{current}/{total} 片 · 已完成 {passes} 片 · 已用 {watch.Elapsed:mm\\:ss}"
                            + (passes > 0 ? $" · 预计剩余 ~{FormatEta((watch.Elapsed.TotalSeconds / passes) * (total - passes))}" : "")
                            + $"\n当前文件：{fileName}   （本片 {chunk.Length:N0} 字符，正在等待模型返回）");
                    running = await MergeConsolidationAsync(running, chunk, token);
                    passes++;
                    ReportProgress((double)passes / total);
                    double avg = watch.Elapsed.TotalSeconds / passes;
                    Publish($"整合中：{passes}/{total} 片 · 已用 {watch.Elapsed:mm\\:ss}"
                            + (passes < total ? $" · 预计剩余 ~{FormatEta(avg * (total - passes))}" : " · 合并完成，正在写回文件"));
                }
                watch.Stop();

                if (string.IsNullOrWhiteSpace(running))
                    throw new InvalidDataException("Ollama returned an empty consolidated note.");

                // 原文逐条保留：中文原声（直通）只写原文；英语等原声保留原文并附中文译文
                var kept = DedupeCaptions(allCaptions);
                var transcript = new StringBuilder();
                int transcriptCount = 0;
                foreach (var (ts, en, zh) in kept)
                {
                    string src = NormalizeCaption(en);
                    string zhText = NormalizeCaption(zh);
                    bool sourceIsChinese = TextUtil.IsMostlyChinese(src, Translator.Setting.TargetLanguage);

                    if (sourceIsChinese)
                    {
                        // 中文原声：原文即中文，无需译文行
                        if (src.Length == 0 || src.StartsWith("[ERROR]", StringComparison.OrdinalIgnoreCase))
                            continue;
                        transcript.AppendLine($"[{ts}] 原文: {src}");
                        transcriptCount++;
                        continue;
                    }

                    // 非中文原声：保留原文（英语等），能翻译时附上中文译文
                    if (src.Length > 0 && !src.StartsWith("[ERROR]", StringComparison.OrdinalIgnoreCase))
                    {
                        transcript.AppendLine($"[{ts}] 原文: {src}");
                        transcriptCount++;
                    }
                    bool zhUsable = zhText.Length > 0 &&
                                    !string.Equals(zhText, "N/A", StringComparison.OrdinalIgnoreCase) &&
                                    !zhText.StartsWith("[ERROR]", StringComparison.OrdinalIgnoreCase);
                    if (zhUsable)
                        transcript.AppendLine($"[{ts}] 译文: {zhText}");
                }
                Publish($"Transcript: {allCaptions.Count} caption(s) -> {kept.Count} de-duplicated, {transcriptCount} line(s).");

                // 中文整理稿：把中文字幕碎片拼成通顺段落（去重复前缀、按时间间隔分段、补标点），
                // 同样不经模型，保证不改写原文
                string chineseDigest = BuildChineseDigest(kept);
                Publish($"Chinese digest: {chineseDigest.Length} chars.");

                // 「我的笔记（自选）」段：放在标题正下方，内容原样保留，方便你在 Obsidian 里随手写
                string customBlock = CustomSectionHeading + "\n\n" +
                    (string.IsNullOrWhiteSpace(customNotes)
                        ? "<!-- 在这里写你自己的笔记/要点；整合时原样保留，不会被覆盖 -->"
                        : customNotes.Trim());
                int titleLineEnd = running.IndexOf('\n');
                string runningBody = titleLineEnd < 0 ? string.Empty : running[(titleLineEnd + 1)..].TrimStart('\n');
                // 标题正文常见的占位「无」直接丢掉，别挤在自选栏后面
                if (runningBody.StartsWith("无\n", StringComparison.Ordinal))
                    runningBody = runningBody[2..].TrimStart('\n');
                else if (runningBody.Trim() == "无")
                    runningBody = string.Empty;
                string runningWithCustom = titleLineEnd < 0
                    ? running.TrimEnd() + "\n\n" + customBlock + "\n"
                    : running[..titleLineEnd].TrimEnd() + "\n\n" + customBlock + "\n" +
                      (runningBody.Length > 0 ? "\n" + runningBody : string.Empty);

                string finalText = runningWithCustom.TrimEnd() +
                    "\n\n## 中文整理稿\n\n" + chineseDigest.TrimEnd() +
                    "\n\n## 完整原文（已去重）\n\n" + transcript.ToString().TrimEnd() + "\n";

                string tempPath = consolidatedPath + ".tmp";
                await File.WriteAllTextAsync(tempPath, finalText, Encoding.UTF8, token);
                File.Move(tempPath, consolidatedPath, true);

                // 只有整批折叠成功、且整合稿已原子替换后，才删除源笔记
                foreach (string path in notePaths)
                    File.Delete(path);
                Publish($"Consolidated into {consolidatedPath}; removed {notePaths.Length} source note(s) in {passes} pass(es).");
                toastSummary = $"整合完成：合并 {notePaths.Length} 篇分段笔记（{passes} 趟折叠）\n" +
                               $"原文 {kept.Count} 条（去重前 {allCaptions.Count} 条）";
            }
            catch (OperationCanceledException)
            {
                Publish("Consolidation canceled; source notes were kept.");
                toastSummary = "整合已取消：分段笔记已保留";
            }
            catch (Exception ex)
            {
                string tempPath = consolidatedPath + ".tmp";
                if (File.Exists(tempPath))
                    File.Delete(tempPath);
                Publish($"Consolidation failed; source notes were kept: {ex.Message}");
                toastSummary = "整合失败：分段笔记已保留";
            }
            finally
            {
                // 无论成功、取消还是失败，都要收回进度条。
                ReportProgress(null);
                // 整合结束后把显存让回给主模型（若两者不同），并弹出提示。
                await SwitchBackToPrimaryModelAsync(token, toastSummary);
            }
        }

        /// <summary>
        /// 整合结束后：
        ///   - 整合模型与主模型不同 → 卸载整合模型、预热主模型，并在提示里说明已切回；
        ///   - 两者相同 → 直接提示整合完成。
        /// 无论走哪条路都会弹出一次提示。
        /// </summary>
        private static async Task SwitchBackToPrimaryModelAsync(CancellationToken token, string summary)
        {
            string primary = Translator.Setting.AutoNotesModelName;
            string consolidation = Translator.Setting.AutoNotesConsolidationModelName;
            bool sameModel = string.IsNullOrWhiteSpace(primary) || string.IsNullOrWhiteSpace(consolidation) ||
                             string.Equals(primary.Trim(), consolidation.Trim(), StringComparison.OrdinalIgnoreCase);
            if (sameModel)
            {
                ShowToast(summary);
                return;
            }

            string baseUrl = Translator.Setting.AutoNotesApiUrl.TrimEnd('/');
            try
            {
                Publish($"Switching back to {primary} (unloading {consolidation})...");
                // 1) 立即卸载整合模型
                var unload = new { model = consolidation, keep_alive = 0, prompt = string.Empty, stream = false };
                using (var content = new StringContent(JsonSerializer.Serialize(unload), Encoding.UTF8, "application/json"))
                using (var resp = await client.PostAsync($"{baseUrl}/api/generate", content, token))
                {
                    if (!resp.IsSuccessStatusCode)
                        Publish($"Unload {consolidation} returned {(int)resp.StatusCode}.");
                }
                // 2) 预热主模型，避免下一句字幕卡在加载上
                var warm = new
                {
                    model = primary,
                    prompt = "hi",
                    stream = false,
                    keep_alive = "10m",
                    options = new { num_predict = 1 }
                };
                using (var content = new StringContent(JsonSerializer.Serialize(warm), Encoding.UTF8, "application/json"))
                using (var resp = await client.PostAsync($"{baseUrl}/api/generate", content, token))
                {
                    if (resp.IsSuccessStatusCode)
                    {
                        Publish($"Switched back to {primary}.");
                        ShowToast($"{summary}\n已切回 {primary}（{consolidation} 已从显存卸载）");
                    }
                    else
                    {
                        Publish($"Warm-up {primary} returned {(int)resp.StatusCode}.");
                    }
                }
            }
            catch (OperationCanceledException)
            {
                // 用户取消整合时不阻塞
            }
            catch (Exception ex)
            {
                Publish($"Model switch-back failed: {ex.Message}");
            }
        }

        /// <summary>
        /// 右下角弹出一个无边框提示窗，6 秒后自动关闭（点击可立即关闭）。
        /// 任何异常都被吞掉，提示失败不影响整合结果。
        /// </summary>
        private static void ShowToast(string message)
        {
            try
            {
                Application? app = Application.Current;
                if (app == null)
                    return;

                app.Dispatcher.Invoke(() =>
                {
                    var text = new TextBlock
                    {
                        Text = message,
                        TextWrapping = TextWrapping.Wrap,
                        FontSize = 13,
                        Foreground = Brushes.White,
                        MaxWidth = 340
                    };
                    var border = new Border
                    {
                        Background = new SolidColorBrush(Color.FromArgb(0xE6, 0x1F, 0x1F, 0x1F)),
                        BorderBrush = new SolidColorBrush(Color.FromArgb(0x40, 0xFF, 0xFF, 0xFF)),
                        BorderThickness = new Thickness(1),
                        CornerRadius = new CornerRadius(8),
                        Padding = new Thickness(14, 10, 14, 10),
                        Child = text
                    };
                    var toast = new Window
                    {
                        WindowStyle = WindowStyle.None,
                        AllowsTransparency = true,
                        Background = Brushes.Transparent,
                        Topmost = true,
                        ShowInTaskbar = false,
                        ShowActivated = false,
                        SizeToContent = SizeToContent.WidthAndHeight,
                        Content = border,
                        Opacity = 0
                    };
                    toast.Show();
                    var area = SystemParameters.WorkArea;
                    toast.Left = Math.Max(area.Left + 8, area.Right - toast.ActualWidth - 20);
                    toast.Top = Math.Max(area.Top + 8, area.Bottom - toast.ActualHeight - 20);

                    toast.BeginAnimation(UIElement.OpacityProperty,
                        new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(180)));
                    toast.MouseDown += (_, _) => toast.Close();

                    var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(6) };
                    timer.Tick += (_, _) =>
                    {
                        timer.Stop();
                        var fade = new DoubleAnimation(1, 0, TimeSpan.FromMilliseconds(220));
                        fade.Completed += (_, _) => toast.Close();
                        toast.BeginAnimation(UIElement.OpacityProperty, fade);
                    };
                    timer.Start();
                });
            }
            catch
            {
                // 提示只是锦上添花，失败就算了
            }
        }

        /// <summary>
        /// 一次折叠：把「已有整合稿」与一个源笔记片段合并。单次输入受 ConsolidationChunkChars 限制，
        /// 因此无论笔记多大都不会超出 Ollama 上下文。
        /// </summary>
        private static async Task<string> MergeConsolidationAsync(string existing, string chunk, CancellationToken token)
        {
            var source = new StringBuilder();
            if (!string.IsNullOrWhiteSpace(existing))
            {
                source.AppendLine("=== 已有整合稿 ===");
                source.AppendLine(existing);
                source.AppendLine("=== 已有整合稿结束 ===");
            }
            source.AppendLine("=== 新增源笔记片段 ===");
            source.AppendLine(chunk);
            source.AppendLine("=== 片段结束 ===");

            string prompt = "把「已有整合稿」（如果有）与「新增源笔记片段」合并成一份简体中文 Markdown 笔记。要求：" +
                "1) 删除重复内容，但不要删除不同的事实、结论、行动项或术语；" +
                "2) 只能使用原文已有的事实，禁止新增原文没有的信息——时间、地点、人物、机构、数字、待办项一律以原文为准，" +
                "原文没有就写「无」，不要推断、补全或举例；" +
                "3) 如果内容冲突，标注「存在冲突」，不要擅自选择；" +
                "4) 不要添加原文没有的抬头（如活动主题/活动时间/参与人员）或结尾段落，也不要重复源笔记的标题行；" +
                "5) 尽可能详细：保留具体数字、时间、地点、人名、机构名、因果关系和例子；" +
                "「关键知识点」要逐条列出（一条一个要点，不要压成一句概括），重要术语给出简短解释；" +
                "6) 只输出一份完整笔记，逐字使用下列标题、各占一行、顺序不变、不要改名：" +
                "# 整合笔记\n## 摘要\n## 关键知识点\n## 会议结论\n## 待办事项\n## 未解决问题\n## 重要术语\n" +
                "上述每个小节若原文确无内容，写「无」。" +
                "不要输出思考过程、<think> 标签或任何解释。" +
                "不要输出「完整原文」章节，原文由程序另行附加。\n\n" + source;

            string result = await CallOllamaAsync(
                Translator.Setting.AutoNotesConsolidationModelName,
                "You merge local Markdown notes accurately, keep every distinct fact, and never invent facts. Output only the final Markdown note.",
                prompt, 0.1, token);
            return NormalizeConsolidatedNote(RemoveThinkingTags(result));
        }

        /// <summary>按行切分，保证每片不超过 maxChars；超长单行硬切。</summary>
        private static IEnumerable<string> SplitIntoChunks(string text, int maxChars)
        {
            var sb = new StringBuilder();
            foreach (string line in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
            {
                if (line.Length > maxChars)
                {
                    if (sb.Length > 0) { yield return sb.ToString(); sb.Clear(); }
                    for (int i = 0; i < line.Length; i += maxChars)
                        yield return line.Substring(i, Math.Min(maxChars, line.Length - i));
                    continue;
                }
                if (sb.Length > 0 && sb.Length + line.Length + 1 > maxChars)
                {
                    yield return sb.ToString();
                    sb.Clear();
                }
                sb.AppendLine(line);
            }
            if (sb.Length > 0)
                yield return sb.ToString();
        }

        /// <summary>
        /// 取出并移除「我的笔记（自选）」段：这是用户手写内容，整合时整段原样保留，
        /// 既不喂给模型，也不被模型改写。
        /// </summary>
        private static string ExtractCustomSection(string text, out string custom)
        {
            custom = string.Empty;
            if (string.IsNullOrEmpty(text))
                return text;

            int start = text.IndexOf(CustomSectionHeading, StringComparison.Ordinal);
            if (start < 0)
                return text;

            int contentStart = start + CustomSectionHeading.Length;
            // 段尾 = 之后的第一个 Markdown 标题行（# ~ ###### 均可），避免把 "# 整合笔记" 吞进来
            Match nextHeading = Regex.Match(text[contentStart..], @"(?m)^#{1,6}\s");
            int end = nextHeading.Success ? contentStart + nextHeading.Index : text.Length;

            custom = text[contentStart..end].Trim();
            return (text[..start] + text[end..]).Trim();
        }

        /// <summary>
        /// 去掉笔记/整合稿里的原文部分（「原始字幕」「中文整理稿」「完整原文」），
        /// 它们由程序统一附加，不喂给模型（省 token，也避免模型照抄原文）。
        /// </summary>
        private static string StripTranscript(string noteText)
        {
            int cut = -1;
            foreach (string marker in new[] { "## 原始字幕", "## 中文整理稿", "## 完整原文", CustomSectionHeading })
            {
                int idx = noteText.IndexOf(marker, StringComparison.Ordinal);
                if (idx >= 0 && (cut < 0 || idx < cut))
                    cut = idx;
            }
            return cut < 0 ? noteText : noteText[..cut];
        }

        /// <summary>
        /// 把去重后的中文字幕碎片整理成通顺段落：
        ///   - 去掉与已累积文本尾部的重复前缀（LiveCaptions 渐进重复的残留）
        ///   - 结尾无标点时补「，」；遇到。！？等结束符视为一句完结
        ///   - 相邻字幕时间间隔 ≥ 8 秒另起一段；单段超过 220 字也断开
        /// 纯确定性处理，不调用模型，不改写用词。
        /// </summary>
        private static string BuildChineseDigest(IEnumerable<(string Ts, string En, string Zh)> kept)
        {
            var paragraphs = new List<string>();
            var current = new StringBuilder();
            DateTime lastTime = default;

            foreach (var (ts, _, zh) in kept)
            {
                string piece = NormalizeCaption(zh);
                if (piece.Length == 0 ||
                    string.Equals(piece, "N/A", StringComparison.OrdinalIgnoreCase) ||
                    piece.StartsWith("[ERROR]", StringComparison.OrdinalIgnoreCase))
                    continue;

                DateTime time;
                bool hasTime = DateTime.TryParse(ts, out time);

                if (current.Length > 0 && hasTime && lastTime != default && (time - lastTime).TotalSeconds >= 8)
                {
                    paragraphs.Add(current.ToString().Trim());
                    current.Clear();
                }

                // 去掉与当前段落尾部的重复前缀（最长 24 字）
                int maxOverlap = Math.Min(24, Math.Min(piece.Length, current.Length));
                for (int len = maxOverlap; len >= 4; len--)
                {
                    string tail = current.ToString(current.Length - len, len);
                    if (piece.StartsWith(tail, StringComparison.Ordinal))
                    {
                        piece = piece[len..].TrimStart();
                        break;
                    }
                }

                if (piece.Length > 0)
                {
                    current.Append(piece);
                    char lastChar = piece[^1];
                    bool ended = lastChar is '。' or '！' or '？' or '!' or '?';
                    if (!ended && lastChar is not ('，' or ',' or '；' or ';' or '：' or ':'))
                        current.Append('，');
                    else if (ended && current.Length >= 220)
                    {
                        paragraphs.Add(current.ToString().Trim());
                        current.Clear();
                    }
                }

                if (hasTime)
                    lastTime = time;
            }

            if (current.Length > 0)
                paragraphs.Add(current.ToString().Trim());

            return string.Join("\n\n", paragraphs);
        }

        /// <summary>
        /// 从笔记的「原始字幕」段或整合稿的「完整原文」段抽取逐条字幕。
        /// 兼容两种格式：新格式「[ts] 原文: …」+「[ts] 译文: …」（中文原声只有原文行），
        /// 旧格式「[ts] English: …」+「Chinese: …」。
        /// </summary>
        private static List<(string Ts, string En, string Zh)> ExtractCaptions(string noteText)
        {
            var list = new List<(string, string, string)>();
            int idx = noteText.IndexOf("## 原始字幕", StringComparison.Ordinal);
            if (idx < 0)
                idx = noteText.IndexOf("## 完整原文", StringComparison.Ordinal);
            if (idx < 0)
                return list;

            string ts = string.Empty;
            string? en = null;
            string? zh = null;
            foreach (string raw in noteText[idx..].Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
            {
                string line = raw.Trim();
                Match m = CaptionLineRegex.Match(line);
                if (m.Success)
                {
                    if (en != null)
                        list.Add((ts, en, zh ?? string.Empty));
                    ts = m.Groups["ts"].Value.Trim();
                    en = m.Groups["en"].Value.Trim();
                    zh = null;
                    continue;
                }
                Match tr = TranslationLineRegex.Match(line);
                if (tr.Success)
                {
                    zh = tr.Groups["zh"].Value.Trim();
                    continue;
                }
                // 旧格式：中文行没有时间戳前缀
                if (line.StartsWith("Chinese:", StringComparison.OrdinalIgnoreCase))
                    zh = line["Chinese:".Length..].Trim();
            }
            if (en != null)
                list.Add((ts, en, zh ?? string.Empty));
            return list;
        }

        private static string NormalizeCaption(string s) =>
            Regex.Replace(s ?? string.Empty, @"\s+", " ").Trim();

        /// <summary>
        /// 去掉 LiveCaptions 的渐进式重复：完全相同的丢弃；旧句是新句前缀（或包含于新句）时保留更完整的；
        /// 新句是旧句前缀时丢弃新句。
        /// </summary>
        private static List<(string Ts, string En, string Zh)> DedupeCaptions(
            IEnumerable<(string Ts, string En, string Zh)> entries)
        {
            var kept = new List<(string Ts, string En, string Zh)>();
            foreach (var e in entries.OrderBy(x => x.Ts, StringComparer.Ordinal))
            {
                string en = NormalizeCaption(e.En);
                if (en.Length == 0)
                    continue;

                bool skip = false;
                for (int i = 0; i < kept.Count; i++)
                {
                    string prev = NormalizeCaption(kept[i].En);
                    if (string.Equals(prev, en, StringComparison.OrdinalIgnoreCase))
                    {
                        skip = true;
                        break;
                    }
                    // 旧的更短且是新句的前缀/被新句包含 → 用更完整的新句替换旧的
                    bool prevIsPrefix = en.Length > prev.Length && prev.Length >= 12 &&
                                        en.StartsWith(prev, StringComparison.OrdinalIgnoreCase);
                    bool prevContained = en.Length > prev.Length && prev.Length >= 16 &&
                                         en.Length <= prev.Length * 2 &&
                                         en.Contains(prev, StringComparison.OrdinalIgnoreCase);
                    if (prevIsPrefix || prevContained)
                    {
                        kept[i] = (e.Ts, e.En, e.Zh);
                        skip = true;
                        break;
                    }
                    // 新句是旧句的前缀/被旧句包含 → 丢弃新句
                    bool enIsPrefix = prev.Length > en.Length && en.Length >= 12 &&
                                      prev.StartsWith(en, StringComparison.OrdinalIgnoreCase);
                    bool enContained = prev.Length > en.Length && en.Length >= 16 &&
                                       prev.Length <= en.Length * 2 &&
                                       prev.Contains(en, StringComparison.OrdinalIgnoreCase);
                    if (enIsPrefix || enContained)
                    {
                        skip = true;
                        break;
                    }
                }
                if (!skip)
                    kept.Add(e);
            }
            return kept;
        }

        private static async Task<string> CallOllamaAsync(string model, string systemPrompt, string userPrompt,
            double temperature, CancellationToken token)
        {
            var body = new
            {
                model,
                messages = new[]
                {
                    new { role = "system", content = systemPrompt },
                    new { role = "user", content = userPrompt }
                },
                stream = false,
                temperature,
                // Gemma 4 等模型默认开启 thinking，思考 token 会挤占输出预算并拖慢整理；
                // 整理任务只需按原文合并，显式关闭思考（与翻译路径 OllamaRequestData.think 一致）。
                think = false
            };
            string url = Translator.Setting.AutoNotesApiUrl.TrimEnd('/') + "/api/chat";
            using var request = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json")
            };
            using var response = await client.SendAsync(request, token);
            response.EnsureSuccessStatusCode();
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            return json.RootElement.GetProperty("message").GetProperty("content").GetString() ?? "";
        }

        private static string ResolveNotesDirectory()
        {
            string directory = Translator.Setting.AutoNotesDirectory;
            return Path.IsPathRooted(directory) ? directory : Path.Combine(AppContext.BaseDirectory, directory);
        }

        private static readonly string[] ConsolidatedHeadings =
        {
            "整合笔记", "摘要", "关键知识点", "会议结论", "待办事项", "未解决问题", "重要术语"
        };

        private static readonly Dictionary<string, string> ConsolidatedHeadingAliases = new(StringComparer.OrdinalIgnoreCase)
        {
            ["整合笔记"] = "整合笔记", ["综合笔记"] = "整合笔记", ["笔记整合"] = "整合笔记",
            ["整合后的笔记"] = "整合笔记", ["笔记"] = "整合笔记",
            ["摘要"] = "摘要", ["概要"] = "摘要", ["总结"] = "摘要",
            ["内容摘要"] = "摘要", ["本次摘要"] = "摘要",
            ["关键知识点"] = "关键知识点", ["关键要点"] = "关键知识点", ["要点"] = "关键知识点",
            ["关键信息"] = "关键知识点", ["主要知识点"] = "关键知识点", ["核心要点"] = "关键知识点",
            ["会议结论"] = "会议结论", ["结论"] = "会议结论", ["会议总结"] = "会议结论", ["主要结论"] = "会议结论",
            ["待办事项"] = "待办事项", ["待办"] = "待办事项", ["行动项"] = "待办事项",
            ["后续行动"] = "待办事项", ["下一步"] = "待办事项", ["行动计划"] = "待办事项",
            ["未解决问题"] = "未解决问题", ["未解决的问题"] = "未解决问题", ["遗留问题"] = "未解决问题",
            ["待解决问题"] = "未解决问题", ["开放问题"] = "未解决问题",
            ["重要术语"] = "重要术语", ["术语"] = "重要术语", ["术语表"] = "重要术语", ["专有名词"] = "重要术语",
        };

        /// <summary>
        /// 确定性归一化：把模型自由命名的标题映射到规定的 7 个标题，缺失小节补「无」，
        /// 顺序与层级固定。模型改名或漏写标题都不再影响输出格式。
        /// </summary>
        private static string NormalizeConsolidatedNote(string text)
        {
            var bodies = new Dictionary<string, StringBuilder>();
            string? current = null;
            foreach (string raw in text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
            {
                Match m = Regex.Match(raw, @"^\s{0,3}#{1,6}\s*(?<title>.+?)\s*#*\s*$");
                if (m.Success)
                {
                    string title = m.Groups["title"].Value.Trim().Trim('*', '：', ':', ' ');
                    if (ConsolidatedHeadingAliases.TryGetValue(title, out string? canonical))
                    {
                        current = canonical;
                        if (!bodies.ContainsKey(canonical))
                            bodies[canonical] = new StringBuilder();
                        continue;
                    }
                    // 未知标题降级成正文加粗行，不再产生额外标题
                    if (current != null)
                        bodies[current].AppendLine("**" + title + "**");
                    continue;
                }
                if (current != null)
                    bodies[current].AppendLine(raw);
            }

            var sb = new StringBuilder();
            foreach (string heading in ConsolidatedHeadings)
            {
                sb.AppendLine(heading == "整合笔记" ? "# 整合笔记" : "## " + heading);
                string body = bodies.TryGetValue(heading, out StringBuilder? b) ? b.ToString().Trim() : string.Empty;
                sb.AppendLine(body.Length == 0 ? "无" : body);
                sb.AppendLine();
            }
            return sb.ToString().Trim() + "\n";
        }

        private static string RemoveThinkingTags(string text)
        {
            int start;
            while ((start = text.IndexOf("<think>", StringComparison.OrdinalIgnoreCase)) >= 0)
            {
                int end = text.IndexOf("</think>", start, StringComparison.OrdinalIgnoreCase);
                if (end < 0)
                    return text[..start];
                text = text.Remove(start, end + "</think>".Length - start);
            }
            return text;
        }

        private static void Publish(string message)
        {
            LastStatus = message;
            StatusChanged?.Invoke(message);
        }

        /// <summary>报告整合进度；传 null 表示整合结束（前端隐藏进度条）。</summary>
        private static void ReportProgress(double? fraction)
        {
            double? value = fraction;
            if (value.HasValue)
                value = Math.Clamp(value.Value, 0.0, 1.0);
            try
            {
                ProgressChanged?.Invoke(value);
            }
            catch
            {
                // 前端订阅者异常不能让整合本身失败
            }
        }

        /// <summary>把预估秒数格式化成「1m20s」这类短文本，负数或无效值按 0 处理。</summary>
        private static string FormatEta(double seconds)
        {
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 0)
                seconds = 0;
            var span = TimeSpan.FromSeconds(seconds);
            if (span.TotalHours >= 1)
                return $"{(int)span.TotalHours}h{span.Minutes:D2}m";
            if (span.TotalMinutes >= 1)
                return $"{span.Minutes}m{span.Seconds:D2}s";
            return $"{span.Seconds}s";
        }
    }
}
