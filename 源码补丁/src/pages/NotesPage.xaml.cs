using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using LiveCaptionsTranslator.utils;

namespace LiveCaptionsTranslator
{
    public partial class NotesPage : Page
    {
        public NotesPage()
        {
            InitializeComponent();
            DataContext = Translator.Setting;
            StatusText.Text = AutoNotesService.LastStatus;
            AutoNotesService.StatusChanged += OnStatusChanged;
            AutoNotesService.ProgressChanged += OnProgressChanged;
            Unloaded += (_, _) =>
            {
                AutoNotesService.StatusChanged -= OnStatusChanged;
                AutoNotesService.ProgressChanged -= OnProgressChanged;
            };

            // 本页所在的 NavigationView 会把页面按"无限高度"测量（内容宿主不提供有限高度），
            // 于是 ScrollViewer 永远认为内容没超出、滚动条不出现。这里显式按窗口高度给出尺寸。
            Loaded += (_, _) => UpdateScrollHeight();
            SizeChanged += (_, _) => UpdateScrollHeight();

            RefreshNotesList();
        }

        /// <summary>按主窗口高度计算本页可滚动区域的高度，保证滚动条与滚轮都可用。</summary>
        private void UpdateScrollHeight()
        {
            try
            {
                Window? win = Window.GetWindow(this);
                if (win == null || win.ActualHeight <= 0)
                    return;
                // 27px 标题栏 + 页面上下留白
                double available = win.ActualHeight - 62;
                PageScroll.Height = Math.Max(140, available);
            }
            catch
            {
                // 布局阶段失败不影响功能
            }
        }

        private void OnStatusChanged(string status)
        {
            Dispatcher.Invoke(() => StatusText.Text = status);
        }

        /// <summary>整合进度：有值时显示进度条，传 null 时隐藏。</summary>
        private void OnProgressChanged(double? fraction)
        {
            Dispatcher.Invoke(() =>
            {
                if (fraction.HasValue)
                {
                    ConsolidateProgress.Value = fraction.Value;
                    ConsolidateProgressPanel.Visibility = Visibility.Visible;
                }
                else
                {
                    ConsolidateProgressPanel.Visibility = Visibility.Collapsed;
                }
            });
        }

        /// <summary>笔记目录（相对路径按程序目录解析）。</summary>
        private static string ResolveNotesDirectory()
        {
            string directory = Translator.Setting.AutoNotesDirectory;
            if (!Path.IsPathRooted(directory))
                directory = Path.Combine(AppContext.BaseDirectory, directory);
            Directory.CreateDirectory(directory);
            return directory;
        }

        /// <summary>刷新「选择要整合的笔记」列表（按时间倒序）。</summary>
        private void RefreshNotesList()
        {
            try
            {
                string directory = ResolveNotesDirectory();
                string[] files = Directory.GetFiles(directory, "note-*.md")
                    .Select(Path.GetFileName)
                    .Where(name => !string.IsNullOrEmpty(name))
                    .OrderByDescending(name => name, StringComparer.OrdinalIgnoreCase)
                    .ToArray()!;
                NotesList.ItemsSource = files;
                NotesCountText.Text = files.Length == 0
                    ? "目录里还没有分段笔记（攒够一批字幕会自动生成）"
                    : $"共 {files.Length} 篇（Ctrl/Shift 可多选；不选则「立即整合并清理」处理全部）";
            }
            catch (Exception ex)
            {
                StatusText.Text = "刷新列表失败：" + ex.Message;
            }
        }

        private void RefreshNotes_Click(object sender, RoutedEventArgs e) => RefreshNotesList();

        private async void GenerateNow_Click(object sender, RoutedEventArgs e)
        {
            await AutoNotesService.GenerateNowAsync();
            RefreshNotesList();
        }

        private async void ConsolidateNow_Click(object sender, RoutedEventArgs e)
        {
            await AutoNotesService.ConsolidateNowAsync();
            RefreshNotesList();
        }

        /// <summary>只整合列表中勾选的那几篇分段笔记。</summary>
        private async void ConsolidateSelected_Click(object sender, RoutedEventArgs e)
        {
            string[] selected = NotesList.SelectedItems?
                .Cast<string>()
                .ToArray() ?? Array.Empty<string>();

            if (selected.Length == 0)
            {
                StatusText.Text = "请先在上面的列表里选择要整合的笔记（Ctrl/Shift 多选），再点「立即整合所选」。";
                return;
            }

            StatusText.Text = $"整合所选 {selected.Length} 篇分段笔记 ...";
            await AutoNotesService.ConsolidateSelectedAsync(selected);
            RefreshNotesList();
        }

        private void OpenFolder_Click(object sender, RoutedEventArgs e)
        {
            Process.Start(new ProcessStartInfo { FileName = ResolveNotesDirectory(), UseShellExecute = true });
        }

        /// <summary>整页滚轮滚动：内容超出时可上下滚动，滚不动时自动收尾。</summary>
        private void Page_PreviewMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
        {
            if (PageScroll.ScrollableHeight <= 0)
                return;
            PageScroll.ScrollToVerticalOffset(PageScroll.VerticalOffset - e.Delta);
            e.Handled = true;
        }

        /// <summary>
        /// 鼠标停在笔记列表上时：列表还能滚就先滚列表；到顶/到底后把滚动"接力"给整页，
        /// 避免滚轮被列表吞掉、页面卡住不动。
        /// </summary>
        private void NotesList_PreviewMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
        {
            ScrollViewer? inner = FindChildScrollViewer(NotesList);
            bool atTop = inner == null || inner.VerticalOffset <= 0.5;
            bool atBottom = inner == null || inner.VerticalOffset >= inner.ScrollableHeight - 0.5;
            bool wantUp = e.Delta > 0;
            bool wantDown = e.Delta < 0;

            if ((wantUp && atTop) || (wantDown && atBottom))
            {
                if (PageScroll.ScrollableHeight > 0)
                {
                    PageScroll.ScrollToVerticalOffset(PageScroll.VerticalOffset - e.Delta);
                    e.Handled = true;
                }
            }
        }

        private static ScrollViewer? FindChildScrollViewer(DependencyObject root)
        {
            int count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
            for (int i = 0; i < count; i++)
            {
                DependencyObject child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
                if (child is ScrollViewer sv)
                    return sv;
                ScrollViewer? deeper = FindChildScrollViewer(child);
                if (deeper != null)
                    return deeper;
            }
            return null;
        }
    }
}
