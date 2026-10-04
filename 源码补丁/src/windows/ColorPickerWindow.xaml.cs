using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace LiveCaptionsTranslator
{
    /// <summary>
    /// 自定义字体颜色取色器：R/G/B 滑块 + 十六进制输入 + 实时预览。
    /// 关闭时通过 <see cref="SelectedHex"/> 返回 #RRGGBB；用户点「恢复预设」则返回空串。
    /// </summary>
    public partial class ColorPickerWindow : Window
    {
        /// <summary>确定选中的颜色（#RRGGBB）。取消时保持进入时的值。</summary>
        public string SelectedHex { get; private set; } = "";

        /// <summary>用户是否点了「恢复预设」（清空自定义颜色，回退到预设色板）。</summary>
        public bool ResetRequested { get; private set; }

        /// <summary>把当前值写入控件的过程中，抑制事件回环。</summary>
        private bool suppressEvents;

        public ColorPickerWindow(Color initial, string currentHex)
        {
            InitializeComponent();
            SelectedHex = currentHex ?? "";
            suppressEvents = true;
            SliderR.Value = initial.R;
            SliderG.Value = initial.G;
            SliderB.Value = initial.B;
            suppressEvents = false;
            SyncFromSliders();
        }

        private Color CurrentColor =>
            Color.FromRgb((byte)SliderR.Value, (byte)SliderG.Value, (byte)SliderB.Value);

        private static string ToHex(Color c) => $"#{c.R:X2}{c.G:X2}{c.B:X2}";

        /// <summary>由滑块推导全部显示控件（数值、色号、预览）。</summary>
        private void SyncFromSliders()
        {
            suppressEvents = true;
            Color c = CurrentColor;
            TextR.Text = c.R.ToString();
            TextG.Text = c.G.ToString();
            TextB.Text = c.B.ToString();
            HexBox.Text = ToHex(c);
            PreviewBorder.Background = new SolidColorBrush(c);
            suppressEvents = false;
        }

        private void Slider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
        {
            if (suppressEvents) return;
            SyncFromSliders();
        }

        /// <summary>手动输入色号：合法则同步滑块，非法则标红但不覆盖用户输入。</summary>
        private void HexBox_TextChanged(object sender, TextChangedEventArgs e)
        {
            if (suppressEvents) return;
            string text = HexBox.Text.Trim();
            if (!text.StartsWith("#")) text = "#" + text;
            if (text.Length != 7) { HexBox.BorderBrush = Brushes.Red; return; }

            try
            {
                Color parsed = (Color)ColorConverter.ConvertFromString(text);
                HexBox.BorderBrush = SystemColors.ControlDarkBrush;
                suppressEvents = true;
                SliderR.Value = parsed.R;
                SliderG.Value = parsed.G;
                SliderB.Value = parsed.B;
                TextR.Text = parsed.R.ToString();
                TextG.Text = parsed.G.ToString();
                TextB.Text = parsed.B.ToString();
                PreviewBorder.Background = new SolidColorBrush(parsed);
                suppressEvents = false;
            }
            catch
            {
                // 输入过程中（例如只敲了一半）解析失败是正常的，不打断用户。
                HexBox.BorderBrush = Brushes.Red;
            }
        }

        private void Ok_Click(object sender, RoutedEventArgs e)
        {
            SelectedHex = ToHex(CurrentColor);
            ResetRequested = false;
            DialogResult = true;
        }

        private void Cancel_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
        }

        private void Reset_Click(object sender, RoutedEventArgs e)
        {
            ResetRequested = true;
            SelectedHex = "";
            DialogResult = true;
        }
    }
}
