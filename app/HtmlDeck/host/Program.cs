// SHINY-HTML-PRODUCTION-PROMOTION-V10: installed host derived from source-locked V8.
// SHINY-HTML-LIVE-BRIDGE-V1
// SHINY-HTML-WINDOW-PARITY-V2 (isolated dev window; no production writes)
// SHINY-HTML-CONTROLS-GLOW-V3: explicit up/down anchor and CSS state; dev only.
// SHINY-HTML-PARITY-V4: framed-close-to-tray, dev-only show request, tucked volume access.
// SHINY-HTML-HEARTBEAT-ICONS-V6: safe dev heartbeat telemetry; opt-in native pulse when native is absent.
// SHINY-HTML-FAILOVER-SUPERVISOR-V8: render-health telemetry and explicit user-exit marker.
// Installed HTML renderer with independently preserved WinForms recovery renderer.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ShinySlack.HtmlDeck.Host;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        // Independent dev-only single-instance gate; never uses native deck mutex.
        using var gate = new Mutex(true, @"Local\ShinySlackHTMLDeckLiveV10", out bool owner);
        if (!owner)
        {
            MessageBox.Show("ShinySlack HTML Deck is already running. Restore it from the tray.",
                "ShinySlack Alert Deck", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new DeckWindow());
    }
}

internal sealed class DeckAlert
{
    public int Id { get; init; }
    public string Channel { get; init; } = "";
    public string Sound { get; init; } = "";
    public string Kind { get; init; } = "";
    public string Accent { get; init; } = "#55d8ff";
    public DateTime Time { get; init; }
    public DateTime AddedAt { get; init; }
    public DateTime ExpireAt { get; set; }
    public bool Sample { get; init; }
}

internal sealed class DeckWindow : Form
{
    private const string Marker = "SHINY-HTML-LIVE-BRIDGE-V1";
    private readonly string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShinySlack");
    private readonly string stateFile;
    private readonly string htmlPath;
    private readonly WebView2 web = new() { Dock = DockStyle.Fill };
    private readonly Label error = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, Padding = new Padding(20), Text = "Starting ShinySlack Alert Deck…" };
    private readonly System.Windows.Forms.Timer tick = new() { Interval = 250 };
    private readonly NotifyIcon tray = new();
    private readonly List<Panel> resizeGrips = new();
    private TableLayoutPanel? chromeSurface;
    private bool framed; // SHINY-HTML-WINDOWS-SNAP-V10.5
    private readonly bool forceFramed = Environment.GetCommandLineArgs().Any(x =>
        string.Equals(x, "--framed", StringComparison.OrdinalIgnoreCase));
    private DateTime logCreationUtc = DateTime.MinValue;
    private int lastNonZeroVolume = 100;
    private readonly List<DeckAlert> alerts = new();
    private readonly byte[] readBuffer = new byte[32768];
    private readonly List<byte> pending = new();
    private static readonly string[] Colors = { "#55d8ff", "#ff5cc8", "#63e6a3", "#ffc857", "#a78bfa", "#5ea1ff", "#ff7b72", "#b5e853", "#ff8fab", "#44d7c4" };
    private static readonly Regex EventPattern = new(@"^(?<stamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) (?<kind>ROUTED|DEFAULT|STACK_EXTRA|STACK_EXTRA_DEFAULT) channel=(?<channel>\S+) sound=(?<sound>.+?) backend=(?<backend>\S+)(?:\s+.*)?$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true, PropertyNameCaseInsensitive = true };
    private readonly string logFile;
    private readonly string settingsFile;
    private readonly string routesFile;
    private readonly string themeFile;
    private readonly string dashboardPortFile;
    // Independent development launcher handshake. Native production still owns its own show request.
    private readonly string devShowRequestFile;
    // Never write the native heartbeat while the native deck's mutex exists.
    // This switch is absent by default; only an explicit cutover test creates it.
    private readonly string heartbeatOptInFile;
    private readonly string heartbeatDevFile;
    private readonly string heartbeatLegacyFile;
    private DateTime lastHeartbeatProbeUtc = DateTime.MinValue;
    private string? lastWrittenLegacyPulse;
    private bool heartbeatNativePresent;
    private bool heartbeatOwnershipActive;
    private long logOffset;
    private bool logInitialized;
    private int nextId = 1;
    private int lastAccent = -1;
    private DateTime lastReadSettings = DateTime.MinValue;
    private DateTime lastReadTheme = DateTime.MinValue;
    private DateTime lastReadVolume = DateTime.MinValue;
    private bool ready;
    private bool webScriptReady;
    private bool hidden;
    private bool exitRequested;
    private bool volumePanelOpen;
    private bool tucked;
    private DateTime? pausedAt;
    private bool autoDismiss = true;
    private int seconds = 15;
    private int volumePercent = 100;
    private bool volumeEnabled = true;
    private string theme = "shiny";
    private string? themeOverride;
    private string growth = "auto";
    private string direction = "down";
    private int growthArmedId;
    private int? manualHeight;
    private bool duringLayout;
    private bool initializedPosition;
    private DateTime lastPush = DateTime.MinValue;
    private bool changed = true;

    private const int WM_NCLBUTTONDOWN = 0x00A1;
    private const int HTCAPTION = 2;
    private const int HTLEFT = 10, HTRIGHT = 11, HTTOP = 12,
        HTTOPLEFT = 13, HTTOPRIGHT = 14, HTBOTTOM = 15,
        HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;
    [DllImport("user32.dll")] private static extern bool ReleaseCapture();
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr hwnd, int msg, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr param);
    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr hwnd, StringBuilder buffer, int max);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr hwnd, int command);
    [DllImport("user32.dll")] private static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hwnd);

    public DeckWindow()
    {
        Text = "ShinySlack Alert Deck";
        Name = "ShinySlackHTMLDeckProd";
        StartPosition = FormStartPosition.Manual;
        Size = new Size(520, 300);
        MinimumSize = new Size(300, 64);
        MaximumSize = Size.Empty; // Do not cap Windows Snap target rectangles.
        // Development default: production-like borderless chrome. Tray menu and
        // --framed are recovery paths if a machine dislikes custom resizing.
        framed = true; // Windows-frame default; frameless remains a tray choice for the session.
        FormBorderStyle = framed ? FormBorderStyle.Sizable : FormBorderStyle.None;
        TopMost = true;
        ShowInTaskbar = true;
        Icon = SystemIcons.Application;
        htmlPath = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "deck-live.html"));
        stateFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ShinySlack", "HtmlDeck-window.json");
        logFile = Path.Combine(root, "channel-router.log");
        settingsFile = Path.Combine(root, "persistent-alerts.json");
        routesFile = Path.Combine(root, "channel-routes.json");
        themeFile = Path.Combine(root, "visual-theme.json");
        dashboardPortFile = Path.Combine(root, "web.port");
        devShowRequestFile = Path.Combine(root, "HtmlDeck-show.request");
        heartbeatDevFile = Path.Combine(root, "HtmlDeck-visible.heartbeat.json");
        heartbeatOptInFile = Path.Combine(root, "HtmlDeck-heartbeat-ownership.flag");
        heartbeatLegacyFile = Path.Combine(root, "deck-visible.heartbeat");
        chromeSurface = BuildChromeSurface();
        Controls.Add(chromeSurface);
        var menu = new ContextMenuStrip();
        menu.Items.Add("Show ShinySlack Alert Deck", null, (_, _) => RestoreFromTray());
        menu.Items.Add("Use standard Windows frame (recovery)", null, (_, _) => SetFrame(true));
        menu.Items.Add("Use frameless deck", null, (_, _) => SetFrame(false));
        menu.Items.Add("Exit ShinySlack Alert Deck", null, (_, _) => { exitRequested = true; Close(); });
        tray.Icon = SystemIcons.Application;
        tray.Text = "ShinySlack Alert Deck";
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => RestoreFromTray();
        tray.Visible = true;
        PositionInitial();
        FormBorderStyle = framed ? FormBorderStyle.Sizable : FormBorderStyle.None;
        ApplyFrameColor();
        Shown += async (_, _) => await InitializeAsync();
        HandleCreated += (_, _) => ApplyWindowsCaptionColor();
        Activated += (_, _) => ApplyWindowsCaptionColor();
        Deactivate += (_, _) => ApplyWindowsCaptionColor();
        Move += (_, _) => { if (initializedPosition && !duringLayout && WindowState == FormWindowState.Normal) SaveWindow(); };
        ResizeEnd += (_, _) =>
        {
            if (initializedPosition && !duringLayout && !tucked) { manualHeight = Height; growth = "auto"; growthArmedId = nextId; }
            SaveWindow(); changed = true;
        };
        // A Windows title-bar X in recovery/frame mode must behave like native X:
        // hide the deck and retain notifications. Tray Exit is the explicit exit.
        FormClosing += (_, e) =>
        {
            if (!exitRequested && e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                HideToTray();
            }
        };
        FormClosed += (_, _) =>
        {
            tick.Stop();
            ReleaseOwnedHeartbeat();
            WriteDevHeartbeat(false, exitRequested ? "user-exit" : "exited");
            tray.Visible = false; tray.Dispose(); web.Dispose();
        };
    }


    // Eight real WinForms hit targets ring the WebView2 child surface. This
    // avoids depending on WebView2 forwarding non-client mouse messages.
    private TableLayoutPanel BuildChromeSurface()
    {
        var grid = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, Margin = new Padding(0), Padding = new Padding(0),
            ColumnCount = 3, RowCount = 3
        };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 6));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 6));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 6));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        grid.RowStyles.Add(new RowStyle(SizeType.Absolute, 6));
        var hits = new[,] {
            { HTTOPLEFT, HTTOP, HTTOPRIGHT },
            { HTLEFT, 0, HTRIGHT },
            { HTBOTTOMLEFT, HTBOTTOM, HTBOTTOMRIGHT }
        };
        for (int y = 0; y < 3; y++)
        for (int x = 0; x < 3; x++)
        {
            if (x == 1 && y == 1)
            {
                var center = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), Padding = new Padding(0) };
                center.Controls.Add(web);
                center.Controls.Add(error);
                grid.Controls.Add(center, x, y);
                continue;
            }
            int hit = hits[y,x];
            var grip = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), Padding = new Padding(0) };
            grip.Cursor = hit switch {
                HTLEFT or HTRIGHT => Cursors.SizeWE,
                HTTOP or HTBOTTOM => Cursors.SizeNS,
                HTTOPLEFT or HTBOTTOMRIGHT => Cursors.SizeNWSE,
                _ => Cursors.SizeNESW
            };
            grip.MouseDown += (_, e) => { if (e.Button == MouseButtons.Left && !framed) StartResize(hit); };
            resizeGrips.Add(grip);
            grid.Controls.Add(grip, x, y);
        }
        return grid;
    }
    private void StartResize(int hit)
    {
        if (framed || WindowState != FormWindowState.Normal) return;
        ReleaseCapture();
        SendMessage(Handle, WM_NCLBUTTONDOWN, (IntPtr)hit, IntPtr.Zero);
        ClampPosition();
        SaveWindow();
    }
    private void SetFrame(bool value)
    {
        if (framed == value) return;
        framed = value;
        FormBorderStyle = framed ? FormBorderStyle.Sizable : FormBorderStyle.None;
        ApplyWindowsCaptionColor();
        ClampPosition();
        SaveWindow();
        changed = true;
        Push();
    }
    private void ApplyFrameColor()
    {
        var color = ColorTranslator.FromHtml((themeOverride ?? theme) switch
        {
            "retro" => "#cbd9ae", "arcade" => "#0a1029", "ghost" => "#110e1b", _ => "#101322"
        });
        BackColor = color;
        if (chromeSurface is not null) chromeSurface.BackColor = color;

        foreach (var grip in resizeGrips) grip.BackColor = color;
        ApplyWindowsCaptionColor();
    }
    // Windows 11 DWM caption colors. The same caption is requested for both
    // focused and unfocused states. Unsupported Windows versions keep OS defaults.
    [DllImport("dwmapi.dll", PreserveSig = true)]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    private void ApplyWindowsCaptionColor()
    {
        if (!framed || !IsHandleCreated) return;
        string activeTheme = themeOverride ?? theme;
        string captionHex = activeTheme switch
        {
            "retro" => "#adbf8d", "arcade" => "#15214b",
            "ghost" => "#251b37", _ => "#242038"
        };
        string textHex = activeTheme == "retro" ? "#233727" : "#f4ecff";
        int caption = ColorTranslator.FromHtml(captionHex).ToArgb() & 0x00ffffff;
        int text = ColorTranslator.FromHtml(textHex).ToArgb() & 0x00ffffff;
        // DWM COLORREF encodes R in the least significant byte.
        caption = (caption & 0x0000ff00) | ((caption & 0x00ff0000) >> 16) | ((caption & 0x000000ff) << 16);
        text = (text & 0x0000ff00) | ((text & 0x00ff0000) >> 16) | ((text & 0x000000ff) << 16);
        try {
            DwmSetWindowAttribute(Handle, 35, ref caption, sizeof(int)); // DWMWA_CAPTION_COLOR
            DwmSetWindowAttribute(Handle, 36, ref text, sizeof(int)); // DWMWA_TEXT_COLOR
        } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { }
    }

    private void PositionInitial()
    {
        var wa = Screen.PrimaryScreen?.WorkingArea ?? new Rectangle(0, 0, 1600, 900);
        Location = new Point(wa.Left + 12, wa.Bottom - Height - 12);
        try
        {
            if (!File.Exists(stateFile)) { initializedPosition = true; return; }
            using var doc = JsonDocument.Parse(File.ReadAllText(stateFile));
            var obj = doc.RootElement;
            int x = ReadInt(obj, "x", Location.X), y = ReadInt(obj, "y", Location.Y);
            int w = Math.Max(300, ReadInt(obj, "width", Width));
            int h = Math.Max(90, ReadInt(obj, "height", Height));
            Size = new Size(w, h); Location = new Point(x, y);
            var dir = ReadString(obj, "direction", "down"); if (dir is "up" or "down") direction = dir;
            var mode = ReadString(obj, "growth", "auto"); if (mode is "auto" or "once" or "locked") growth = mode;
            if (ReadInt(obj, "manualHeight", 0) > 0) manualHeight = ReadInt(obj, "manualHeight", h);
            framed = true; // Migrate old frameless preference to the new framed default.
            ClampPosition();
        }
        catch { /* Corrupt dev-only window state does not interrupt the deck. */ }
        initializedPosition = true;
    }
    private static int ReadInt(JsonElement item, string name, int fallback)
        => item.TryGetProperty(name, out var p) && p.TryGetInt32(out int v) ? v : fallback;
    private static string ReadString(JsonElement item, string name, string fallback)
        => item.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() ?? fallback : fallback;
    private static bool ReadBool(JsonElement item, string name, bool fallback)
        => item.TryGetProperty(name, out var p) && p.ValueKind is JsonValueKind.True or JsonValueKind.False ? p.GetBoolean() : fallback;
    private void ClampPosition()
    {
        var work = Screen.FromRectangle(Bounds).WorkingArea;
        Left = Math.Clamp(Left, work.Left + 8, Math.Max(work.Left + 8, work.Right - Width - 8));
        Top = Math.Clamp(Top, work.Top + 8, Math.Max(work.Top + 8, work.Bottom - Height - 8));
    }
    private void SaveWindow()
    {
        if (!initializedPosition || !IsHandleCreated) return;
        try
        {
            var obj = new { x = Left, y = Top, width = Width, height = Height, direction, growth, manualHeight, framed, savedAt = DateTime.Now };
            Directory.CreateDirectory(root);
            File.WriteAllText(stateFile, JsonSerializer.Serialize(obj, JsonOptions));
        }
        catch { }
    }

    private async System.Threading.Tasks.Task InitializeAsync()
    {
        if (!File.Exists(htmlPath)) { Fail("Missing deck-live.html next to executable.\n" + htmlPath); return; }
        try
        {
            // Separate WebView2 profile and process identity; never share native mutex.
            var profile = Path.Combine(root, "HtmlDeckLiveDev-WebView2");
            var environment = await CoreWebView2Environment.CreateAsync(null, profile);
            await web.EnsureCoreWebView2Async(environment);
            var core = web.CoreWebView2;
            core.Settings.AreDevToolsEnabled = true;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsWebMessageEnabled = true;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsScriptEnabled = true;
            core.NavigationStarting += (_, e) =>
            {
                if (!string.Equals(e.Uri, new Uri(htmlPath).AbsoluteUri, StringComparison.OrdinalIgnoreCase)) e.Cancel = true;
                else webScriptReady = false;
            };
            core.NewWindowRequested += (_, e) => { e.Handled = true; };
            core.WebMessageReceived += OnWebMessage;
            core.NavigationCompleted += (_, e) => { if (e.IsSuccess) { ready = true; changed = true; Push(); } else { ready = false; Fail("Navigation failed: " + e.WebErrorStatus); WriteDevHeartbeat(false, "renderer-failed"); } };
            // DEV failover supervisor must distinguish a failed renderer from a hidden deck.
            core.ProcessFailed += (_, _) => { ready = false; webScriptReady = false; Fail("WebView2 rendering process failed."); WriteDevHeartbeat(false, "renderer-failed"); };
            ReadSettings(); ReadTheme(); ReadVolume();
            InitializeLogTail();
            core.Navigate(new Uri(htmlPath).AbsoluteUri);
            error.Visible = false;
            web.BringToFront();
            tick.Tick += (_, _) => Tick();
            tick.Start();
        }
        catch (Exception ex) { Fail("WebView2 initialization failed:\n" + ex); }
    }
    private void Fail(string message)
    {
        tick.Stop(); web.Visible = false; error.Text = message; error.Visible = true; error.BringToFront();
    }

    private void InitializeLogTail()
    {
        if (logInitialized) return;
        if (!File.Exists(logFile)) return;
        try
        {
            using var fs = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            // Match native deck behavior: start at end, don't re-show older log entries.
            // Scan up to 4MB of historic events to continue its color rotation.
            int tailSize = (int)Math.Min(fs.Length, 4 * 1024 * 1024L);
            if (tailSize > 0)
            {
                fs.Seek(-tailSize, SeekOrigin.End);
                var bytes = new byte[tailSize];
                int n = 0, got;
                while (n < bytes.Length && (got = fs.Read(bytes, n, bytes.Length - n)) > 0) n += got;
                var text = Encoding.UTF8.GetString(bytes, 0, n);
                var lines = text.Split('\n');
                foreach (var line in lines.TakeLast(8002))
                    if (EventPattern.IsMatch(line.Trim())) lastAccent = AccentIndex(line.Trim(), lastAccent);
            }
            logOffset = fs.Length;
            logCreationUtc = File.GetCreationTimeUtc(logFile);
            logInitialized = true;
            pending.Clear();
        }
        catch { }
    }

    private static int AccentIndex(string line, int previous)
    {
        ulong hash = 0;
        foreach (char c in line) hash = (hash * 31UL + c) % 4294967296UL;
        int next = (int)(hash % (ulong)Colors.Length);
        return next == previous ? (next + 1) % Colors.Length : next;
    }

    private void ReadLog()
    {
        if (!logInitialized) { InitializeLogTail(); return; }
        if (!File.Exists(logFile)) return;
        try
        {
            using var fs = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            // Re-read new log files after rotation/truncation. V1 skipped the
            // beginning of a truncated file and could silently lose alerts.
            var created = File.GetCreationTimeUtc(logFile);
            if (created != logCreationUtc || fs.Length < logOffset)
            {
                logOffset = 0;
                pending.Clear();
                logCreationUtc = created;
            }
            fs.Seek(logOffset, SeekOrigin.Begin);
            int total = 0;
            int n;
            while (total < 256 * 1024 && (n = fs.Read(readBuffer, 0, readBuffer.Length)) > 0)
            {
                total += n; logOffset += n;
                for (int i=0; i<n; i++)
                {
                    byte b = readBuffer[i];
                    if (b == 10)
                    {
                        var line = Encoding.UTF8.GetString(pending.ToArray()).Trim();
                        pending.Clear();
                        if (line.Length > 0) AddLogEvent(line);
                    }
                    else if (pending.Count < 65536) pending.Add(b);
                    else pending.Clear();
                }
            }
        }
        catch { /* Log is independent of audio/router; retry next tick. */ }
    }
    private void AddLogEvent(string line)
    {
        var m = EventPattern.Match(line);
        if (!m.Success) return;
        if (!DateTime.TryParseExact(m.Groups["stamp"].Value, "yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture, DateTimeStyles.None, out var time)) time = DateTime.Now;
        var now = DateTime.Now;
        lastAccent = AccentIndex(line, lastAccent);
        alerts.Add(new DeckAlert { Id=nextId++, Channel=m.Groups["channel"].Value, Sound=m.Groups["sound"].Value,
            Kind=m.Groups["kind"].Value, Time=time, AddedAt=now, ExpireAt=now.AddSeconds(seconds), Accent=Colors[lastAccent] });
        if (alerts.Count > 30) alerts.RemoveRange(0, alerts.Count - 30);
        if (growth == "once" && nextId > growthArmedId) { growth="auto"; manualHeight=null; }
        else if (growth == "auto" && manualHeight.HasValue) manualHeight=null;
        changed = true;
    }
    private void SampleAlert()
    {
        var now = DateTime.Now;
        lastAccent = AccentIndex("sample-" + nextId, lastAccent);
        alerts.Add(new DeckAlert {Id=nextId++, Channel="#html-deck-test", Kind="SAMPLE", Sound="none", Sample=true,
            Time=now, AddedAt=now, ExpireAt=now.AddSeconds(seconds), Accent=Colors[lastAccent]});
        if (alerts.Count > 30) alerts.RemoveAt(0);
        if (growth == "once" && nextId > growthArmedId) { growth="auto"; manualHeight=null; }
        changed=true;
    }
    private void Tick()
    {
        try
        {
            // DEV ONLY: accept a distinct restore request. Do not consume the
            // production deck's persistent-alerts-show.request while both run.
            try
            {
                if (File.Exists(devShowRequestFile))
                {
                    File.Delete(devShowRequestFile);
                    RestoreFromTray();
                }
            }
            catch (IOException) { /* Retry next tick if the file is locked. */ }
            ReadLog();
            PulseHeartbeat();
            if ((DateTime.Now - lastReadSettings).TotalMilliseconds >= 1500) ReadSettings();
            if ((DateTime.Now - lastReadTheme).TotalMilliseconds >= 1200) ReadTheme();
            if ((DateTime.Now - lastReadVolume).TotalMilliseconds >= 1500) ReadVolume();
            if (!pausedAt.HasValue && autoDismiss)
            {
                int before=alerts.Count;
                alerts.RemoveAll(a => a.ExpireAt <= DateTime.Now);
                if (before != alerts.Count) changed=true;
            }
            if (changed || (DateTime.Now-lastPush).TotalSeconds > 4) Push();
        }
        catch { /* UI loop must not crash audio/router or itself on partial writes. */ }
    }
    private void ReadSettings()
    {
        lastReadSettings=DateTime.Now;
        if (!File.Exists(settingsFile)) return;
        try
        {
            var obj=JsonNode.Parse(File.ReadAllText(settingsFile)) as JsonObject;
            if (obj is null) return;
            bool a = obj["autoDismiss"]?.GetValue<bool>() ?? true;
            int s = Math.Clamp(obj["autoDismissSeconds"]?.GetValue<int>() ?? 15, 1, 3600);
            if (a != autoDismiss || s != seconds) {autoDismiss=a; seconds=s; changed=true;}
        }
        catch { }
    }
    private void ReadTheme()
    {
        lastReadTheme=DateTime.Now;
        if (!File.Exists(themeFile)) return;
        try
        {
            var obj=JsonNode.Parse(File.ReadAllText(themeFile)) as JsonObject;
            var candidate=obj?["theme"]?.GetValue<string>() ?? "shiny";
            if (candidate is not ("shiny" or "retro" or "arcade" or "ghost")) candidate="shiny";
            if (candidate != theme) { theme=candidate; changed=true; }
        }
        catch { }
    }
    private void ReadVolume()
    {
        lastReadVolume=DateTime.Now;
        if (!File.Exists(routesFile)) return;
        try
        {
            var obj=JsonNode.Parse(File.ReadAllText(routesFile)) as JsonObject;
            if (obj is null) return;
            var enabled=obj["enabled"]?.GetValue<bool>() ?? true;
            var volume=Math.Clamp(obj["volume"]?.GetValue<double>() ?? 1.0,0.0,1.0);
            int percent=(int)Math.Round(volume*100);
            if (enabled && percent > 0) lastNonZeroVolume = percent;
            if (enabled != volumeEnabled || percent != volumePercent) { volumeEnabled=enabled; volumePercent=percent; changed=true; }
        }
        catch { }
    }
    private static void AtomicJsonUpdate(string file, Action<JsonObject> update)
    {
        if (!File.Exists(file)) throw new IOException("Shared configuration file is missing; refusing to create a replacement.");
        var config=JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? throw new IOException("Invalid configuration object.");
        update(config);
        var temp=file + ".html-dev-" + Guid.NewGuid().ToString("N") + ".tmp";
        var backup=file + ".html-dev.backup";
        try
        {
            File.WriteAllText(temp,config.ToJsonString(JsonOptions), new UTF8Encoding(false));
            IOException? lastError = null;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                try { File.Replace(temp, file, backup); lastError=null; break; }
                catch (IOException ex)
                {
                    lastError=ex;
                    if (attempt < 2) Thread.Sleep(80);
                }
            }
            if (lastError is not null) throw lastError;
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    private void SetVolume(int pct)
    {
        pct=Math.Clamp(pct,0,100);
        AtomicJsonUpdate(routesFile, obj => {obj["volume"] = pct/100.0; obj["enabled"]=pct>0;});
        ReadVolume();
        if (volumePercent != pct || volumeEnabled != (pct>0)) throw new IOException("Router volume verification failed.");
        changed=true;
    }
    private void SetAutoDismiss(bool value)
    {
        AtomicJsonUpdate(settingsFile, obj => {obj["autoDismiss"] = value; });
        ReadSettings();
        if (autoDismiss != value) throw new IOException("Auto-dismiss verification failed.");
        changed=true;
    }

    private void Pause()
    {
        if (!pausedAt.HasValue) pausedAt=DateTime.Now;
    }
    private void ResumePause()
    {
        if (!pausedAt.HasValue) return;
        var from=pausedAt.Value;
        var now=DateTime.Now;
        foreach (var a in alerts) { var start=a.AddedAt > from ? a.AddedAt : from; a.ExpireAt=a.ExpireAt.Add(now-start); }
        pausedAt=null;
    }
    private void RestoreFromTray()
    {
        ResumePause(); hidden=false; tucked=false;
        lastHeartbeatProbeUtc = DateTime.MinValue;
        if (!Visible) Show();
        if (WindowState == FormWindowState.Minimized) WindowState=FormWindowState.Normal;
        ShowInTaskbar=true; BringToFront(); Activate();
        changed=true; Push();
    }
    private void HideToTray()
    {
        volumePanelOpen = false;
        Pause(); hidden=true; Hide(); ShowInTaskbar=false;
        lastHeartbeatProbeUtc = DateTime.MinValue;
        PulseHeartbeat();
    }
    private void SetTucked(bool value)
    {
        if (value == tucked) return;
        if (value) Pause(); else ResumePause();
        tucked=value;
        lastHeartbeatProbeUtc = DateTime.MinValue;
        if (!value && growth == "once") {growth="auto";manualHeight=null;}
        changed=true; Push();
    }
    private void CycleGrowth()
    {
        switch (growth)
        {
            case "auto": growth="once";growthArmedId=nextId;manualHeight=200;break;
            case "once": growth="locked";manualHeight=200;break;
            default: growth="auto";manualHeight=null;break;
        }
        changed=true;SaveWindow();Push();
    }
    private void ToggleDirection()
    {
        // Keep the header in its screen position when flipping: like native,
        // upward growth puts the header at the bottom of the window.
        int headerHeight = (int)Math.Ceiling(48.0 * DeviceDpi / 96.0);
        int headerTop = direction == "up" ? Bottom - headerHeight : Top;
        direction = direction == "up" ? "down" : "up";
        changed = true;
        Push(); // pushes the new direction and performs any automatic resize
        Top = direction == "up" ? headerTop - (Height - headerHeight) : headerTop;
        ClampPosition();
        SaveWindow();
    }

    private void OnWebMessage(object? _, CoreWebView2WebMessageReceivedEventArgs e)
    {
        // Only the exact local dev document may issue a small allow-listed command set.
        if (!string.Equals(e.Source,new Uri(htmlPath).AbsoluteUri,StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            using var document=JsonDocument.Parse(e.WebMessageAsJson);
            var obj=document.RootElement;
            if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty("action",out var actionNode) || actionNode.ValueKind!=JsonValueKind.String) return;
            var action=actionNode.GetString();
            switch (action)
            {
                case "ready": webScriptReady=true;changed=true;Push();break;
                case "drag":
                    ReleaseCapture(); SendMessage(Handle,WM_NCLBUTTONDOWN,(IntPtr)HTCAPTION,IntPtr.Zero);
                    ClampPosition();SaveWindow(); break;
                case "show-dashboard": OpenDashboard();break;
                case "open-slack":
                    if (obj.TryGetProperty("id",out var openId) && openId.TryGetInt32(out var aid))
                    {
                        var a=alerts.FirstOrDefault(x=>x.Id==aid);
                        if (a is not null && !a.Sample) OpenSlack(a.Channel);
                    }
                    break;
                case "dismiss-one":
                    if (obj.TryGetProperty("id",out var idNode) && idNode.TryGetInt32(out var id))
                    {alerts.RemoveAll(a=>a.Id==id);changed=true;Push();}break;
                case "dismiss-all":alerts.Clear();changed=true;Push();break;
                case "sample":SampleAlert();Push();break;
                case "toggle-tuck":SetTucked(!tucked);break;
                case "hide-deck":HideToTray();break;
                case "close-dev-window":Close();break;
                case "toggle-growth":CycleGrowth();break;
                case "toggle-direction":ToggleDirection();break;
                case "set-volume":
                    if (obj.TryGetProperty("value",out var val) && val.TryGetInt32(out var volume) && volume>=0 && volume<=100) SetVolume(volume);
                    break;
                case "toggle-volume":SetVolume(volumeEnabled && volumePercent>0 ? 0 : Math.Max(1,lastNonZeroVolume));break;
                case "toggle-volume-panel":
                    volumePanelOpen = !volumePanelOpen;
                    changed = true; Push(); break;
                case "close-volume-panel":
                    if (volumePanelOpen) {volumePanelOpen=false; changed=true; Push();}
                    break;
                case "set-auto-dismiss":
                    if (obj.TryGetProperty("value",out var auto) && (auto.ValueKind is JsonValueKind.True or JsonValueKind.False)) SetAutoDismiss(auto.GetBoolean());
                    break;
                case "select-theme":
                    if (obj.TryGetProperty("value",out var themeValue) && themeValue.ValueKind == JsonValueKind.String)
                    {
                        var selected=themeValue.GetString();
                        if (selected is "shiny" or "retro" or "arcade" or "ghost") {themeOverride=selected;changed=true;Push();}
                    }
                    break;
                case "follow-theme":themeOverride=null;changed=true;Push();break;
            }
        }
        catch (Exception ex) { SendError("Control failed: " + ex.Message); }
    }
    private void SendError(string text)
    {
        if (!ready) return;
        try {web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new {type="error",message=text}));} catch {}
    }
    private void Push()
    {
        if (!ready || web.CoreWebView2 is null || hidden) return;
        changed=false;
        lastPush=DateTime.Now;
        ApplyFrameColor();
        var data=new
        {
            type="state", marker=Marker,
            theme=themeOverride ?? theme, followingTheme=themeOverride is null,
            direction, growth, tucked, hidden,
            autoDismiss, seconds,
            volumeEnabled, volumePercent, volumePanelOpen,
            count=alerts.Count,
            events=alerts.AsEnumerable().Reverse().Select(a=>new
            {
                id=a.Id,channel=a.Channel,time=a.Time.ToString("h:mm tt",CultureInfo.InvariantCulture),
                kind=a.Kind,color=a.Accent,sample=a.Sample
            }).ToArray(),
            status=File.Exists(logFile)?"Watching live router events":"Waiting for channel-router.log"
        };
        try
        {
            web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(data));
            ResizeForContent();
        }
        catch { }
    }
    private void ResizeForContent()
    {
        if (!initializedPosition || WindowState != FormWindowState.Normal || framed) return;
        // Native sizing: header 130px, 78px cards with 9px gaps, 24px foot; capped by screen.
        // Locked/once/manual heights use their own viewport; all alerts remain scrollable.
        // Compact deck chrome. Card geometry is still owned entirely by the
        // approved Activity CSS; height estimate only controls the window.
        double dpi = DeviceDpi / 96.0;
        int autoHeight=(int)Math.Ceiling((146 + (volumePanelOpen ? 108 : 0) + (Math.Max(1,alerts.Count)*86)) * dpi) + (framed ? 30 : 0);
        int compactHeight=(int)Math.Ceiling((volumePanelOpen ? 190 : 62) * dpi) + (framed ? 30 : 0);
        int target=tucked ? compactHeight : manualHeight ?? Math.Min(700,autoHeight);
        target=Math.Clamp(target,MinimumSize.Height,Math.Max(MinimumSize.Height,Math.Min(850,Screen.FromControl(this).WorkingArea.Height-24)));
        if (Height == target) return;
        duringLayout=true;
        try
        {
            int bottom=Bottom;
            Height=target;
            if (direction=="up") Top=bottom-Height;
            ClampPosition();
        }
        finally {duringLayout=false;}
        SaveWindow();
    }


    // Native ownership is detected through the exact WinForms mutex from
    // PersistentAlerts.ps1. Failure to inspect it is treated as 'present'.
    private static bool IsNativeDeckPresent()
    {
        try
        {
            if (Mutex.TryOpenExisting(@"Local\ShinySlackPersistentAlertsV6", out var native))
            {
                native.Dispose();
                return true;
            }
            return false;
        }
        catch { return true; }
    }

    private void ReleaseOwnedHeartbeat()
    {
        if (lastWrittenLegacyPulse is null) return;
        try
        {
            // A native writer may have appeared after the last poll. Never
            // delete its heartbeat, even when the native payload is identical.
            if (!IsNativeDeckPresent() && File.Exists(heartbeatLegacyFile))
            {
                string current = File.ReadAllText(heartbeatLegacyFile).Trim();
                if (string.Equals(current, lastWrittenLegacyPulse, StringComparison.Ordinal))
                    File.Delete(heartbeatLegacyFile);
            }
        }
        catch { /* Presentation telemetry must never interrupt router/audio. */ }
        lastWrittenLegacyPulse = null;
        heartbeatOwnershipActive = false;
    }

    private void WriteDevHeartbeat(bool visible, string mode)
    {
        try
        {
            Directory.CreateDirectory(root);
            var info = new
            {
                schema = "html-deck-prod-heartbeat-v10",
                rendererReady = ready && webScriptReady,
                pid = Environment.ProcessId,
                timestampUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture),
                visible,
                tucked,
                hidden,
                nativePresent = heartbeatNativePresent,
                ownershipRequested = File.Exists(heartbeatOptInFile),
                ownershipActive = heartbeatOwnershipActive,
                mode
            };
            // Separate dev-only observation; no native code reads this file.
            File.WriteAllText(heartbeatDevFile, JsonSerializer.Serialize(info, JsonOptions), new UTF8Encoding(false));
        }
        catch { }
    }

    private void PulseHeartbeat()
    {
        var nowUtc = DateTime.UtcNow;
        if ((nowUtc - lastHeartbeatProbeUtc).TotalSeconds < 4) return;
        lastHeartbeatProbeUtc = nowUtc;
        heartbeatNativePresent = IsNativeDeckPresent();
        bool optIn = File.Exists(heartbeatOptInFile);
        bool isVisible = Visible && !hidden;
        // Native uses Form.Visible even when tucked. Tucked remains 'visible'.
        // Keep ownership disabled by default, and never compete with native.
        if (!optIn || heartbeatNativePresent || !isVisible)
        {
            if (!heartbeatNativePresent) ReleaseOwnedHeartbeat();
            else
            {
                // Native might own the file now; abandon previous ownership
                // without deleting or rewriting its heartbeat.
                lastWrittenLegacyPulse = null;
                heartbeatOwnershipActive = false;
            }
            WriteDevHeartbeat(isVisible,
                !optIn ? "observer" : heartbeatNativePresent ? "blocked-native" : "owner-hidden");
            return;
        }
        try
        {
            string stamp = DateTime.Now.ToString("o", CultureInfo.InvariantCulture);
            // Legacy format intentionally remains an ISO local timestamp.
            // Only enabled during an explicit native-off ownership trial.
            File.WriteAllText(heartbeatLegacyFile, stamp, new UTF8Encoding(false));
            lastWrittenLegacyPulse = stamp;
            heartbeatOwnershipActive = true;
            WriteDevHeartbeat(true, "owner-active");
        }
        catch
        {
            heartbeatOwnershipActive = false;
            WriteDevHeartbeat(isVisible, "owner-error");
        }
    }

    private void OpenDashboard()
    {
        try
        {
            if (File.Exists(dashboardPortFile))
            {
                string raw=File.ReadAllText(dashboardPortFile).Trim();
                if (int.TryParse(raw,out int port) && port>=1 && port<=65535)
                {Process.Start(new ProcessStartInfo("http://127.0.0.1:"+port+"/") {UseShellExecute=true});return;}
            }
            SendError("Dashboard port not found. Open ShinySlack from its normal launcher.");
        }
        catch (Exception ex) {SendError("Dashboard failed: "+ex.Message);}
    }
    private void OpenSlack(string channel)
    {
        try
        {
            if (File.Exists(routesFile))
            {
                var obj=JsonNode.Parse(File.ReadAllText(routesFile)) as JsonObject;
                string key=channel.TrimStart('#');
                var deep=obj?["deepLinks"] as JsonObject;
                var info=deep?[key] as JsonObject;
                var team=info?["team"]?.GetValue<string>();
                var id=info?["channel"]?.GetValue<string>();
                if (!string.IsNullOrWhiteSpace(team) && !string.IsNullOrWhiteSpace(id))
                {
                    var uri="slack://channel?team="+Uri.EscapeDataString(team)+"&id="+Uri.EscapeDataString(id);
                    Process.Start(new ProcessStartInfo(uri){UseShellExecute=true});
                    return;
                }
            }
        }
        catch { /* Deep link failed: fall through to window restore. */ }
        var found=FindSlackWindow();
        if (found==IntPtr.Zero) {SendError("Slack window not found.");return;}
        if (IsIconic(found)) ShowWindowAsync(found,9); else ShowWindowAsync(found,5);
        BringWindowToTop(found);SetForegroundWindow(found);
    }
    private static IntPtr FindSlackWindow()
    {
        IntPtr best=IntPtr.Zero;int high=int.MinValue;
        EnumWindows((hwnd,_)=>
        {
            if (!IsWindowVisible(hwnd)) return true;
            GetWindowThreadProcessId(hwnd,out uint pid);
            if (pid==0) return true;
            try
            {
                using var process=Process.GetProcessById((int)pid);
                if (!process.ProcessName.Equals("slack",StringComparison.OrdinalIgnoreCase)) return true;
                int len=GetWindowTextLength(hwnd);
                if (len<=0) return true;
                var text=new StringBuilder(len+1);GetWindowText(hwnd,text,text.Capacity);
                string title=text.ToString();
                if (string.IsNullOrWhiteSpace(title) || title.Contains("app://resources/notifications.html",StringComparison.OrdinalIgnoreCase)) return true;
                int score=10 + (title.Contains("Slack",StringComparison.OrdinalIgnoreCase)?100:0) +
                    (title.Contains("Channel",StringComparison.OrdinalIgnoreCase)?40:0) +
                    (title.Contains("Direct message",StringComparison.OrdinalIgnoreCase)?40:0);
                if (score>high) {high=score;best=hwnd;}
            }
            catch { }
            return true;
        },IntPtr.Zero);
        return best;
    }
}
