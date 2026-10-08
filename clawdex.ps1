#requires -Version 5.1
# clawdex for Windows - floating Codex-pet overlay driven by Claude Code hooks.
# Usage: clawdex.ps1 [-Command wake|tuck|list|select|size|icon] [-Arg <pet id>]
param(
    [string]$Command = 'wake',
    [string]$Arg = ''
)
$ErrorActionPreference = 'Stop'

$Root    = Join-Path $env:USERPROFILE '.clawdex'
$CfgPath = Join-Path $Root 'config.json'
$EvPath  = Join-Path $Root 'events.log'
$LogPath = Join-Path $Root 'daemon.log'
$PetDirs = @((Join-Path $Root 'pets'), (Join-Path $env:USERPROFILE '.codex\pets'))
$CellW = 192
$CellH = 208
$null = New-Item -ItemType Directory -Force $Root

function Write-Log($msg) {
    try { Add-Content -Path $LogPath -Value ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $msg) } catch {}
}

function Get-Pets {
    $list = @{}
    foreach ($d in $PetDirs) {
        if (-not (Test-Path $d)) { continue }
        foreach ($p in Get-ChildItem $d -Directory) {
            $j = Join-Path $p.FullName 'pet.json'
            if (-not (Test-Path $j)) { continue }
            try { $m = Get-Content $j -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $sheet = if ($m.spritesheetPath) { [string]$m.spritesheetPath } else { 'spritesheet.webp' }
            $sp = Join-Path $p.FullName $sheet
            if (-not (Test-Path $sp)) { continue }
            $id = if ($m.id) { [string]$m.id } else { $p.Name }
            if ($list.ContainsKey($id)) { continue }
            $name = if ($m.displayName) { [string]$m.displayName } else { $id }
            $list[$id] = [pscustomobject]@{ Id = $id; Name = $name; Sheet = $sp }
        }
    }
    return @($list.Values | Sort-Object Id)
}

# The two pill buttons press the real "new session" / microphone buttons in the Claude window (UI Automation).
# newChatHotkey / voiceHotkey are only a fallback if those buttons can't be found (e.g. "ctrl+shift+o"); empty = off.
function Get-Config {
    $c = [ordered]@{ pet = ''; scale = 0.8; left = $null; top = $null; newChatHotkey = ''; voiceHotkey = '' }
    if (Test-Path $CfgPath) {
        try {
            $j = Get-Content $CfgPath -Raw | ConvertFrom-Json
            foreach ($k in @($c.Keys)) { if ($null -ne $j.$k) { $c[$k] = $j.$k } }
        } catch {}
    }
    # earlier builds saved guessed hotkeys as defaults; drop them
    if ($c.newChatHotkey -eq 'ctrl+shift+o') { $c.newChatHotkey = '' }
    if ($c.voiceHotkey -eq 'win+h') { $c.voiceHotkey = '' }
    return $c
}

function Save-Config($c) {
    try { [IO.File]::WriteAllText($CfgPath, ($c | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) } catch {}
}

function Send-Event($name, $tool = '') {
    $ts = [long]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalMilliseconds
    $line = '{"event":"' + $name + '","tool":"' + $tool + '","ts":' + $ts + "}`n"
    $fs = [IO.File]::Open($EvPath, 'Append', 'Write', 'ReadWrite')
    try { $b = [Text.Encoding]::UTF8.GetBytes($line); $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
}

function Test-DaemonRunning {
    try { [Threading.Mutex]::OpenExisting('Local\ClawdexPetDaemon').Close(); return $true } catch { return $false }
}

# ---- non-GUI commands -------------------------------------------------------------------------
switch ($Command) {
    'list' {
        $cfg = Get-Config
        Get-Pets | ForEach-Object { '{0}{1}  {2}' -f $(if ($_.Id -eq $cfg.pet) { '* ' } else { '  ' }), $_.Id, $_.Name }
        return
    }
    'select' {
        $sel = Get-Pets | Where-Object { $_.Id -eq $Arg -or $_.Name -eq $Arg } | Select-Object -First 1
        if (-not $sel) { Write-Error "No such pet: $Arg (try: clawdex.ps1 -Command list)"; return }
        $cfg = Get-Config; $cfg.pet = $sel.Id; Save-Config $cfg
        if (Test-DaemonRunning) { Send-Event 'Reload' }
        "Selected $($sel.Id)"
        return
    }
    'size' {
        if (Test-DaemonRunning) { Send-Event 'ShowSize'; 'Opened the size slider.' } else { 'Pet is not running.' }
        return
    }
    'new' {      # same as the pill's "new chat" button
        if (Test-DaemonRunning) { Send-Event 'ActionNew'; 'Asked Claude for a new session.' } else { 'Pet is not running.' }
        return
    }
    'voice' {    # same as the pill's "voice" button
        if (Test-DaemonRunning) { Send-Event 'ActionVoice'; 'Pressed the Claude mic button.' } else { 'Pet is not running.' }
        return
    }
    'tuck' {
        if (Test-DaemonRunning) { Send-Event 'Quit'; 'Pet tucked away.' } else { 'Pet is not running.' }
        return
    }
}

# ---- GUI daemon -------------------------------------------------------------------------------
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\ClawdexPetDaemon', [ref]$created)
if (-not $created -and $Command -ne 'icon') { exit 0 }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class ClawdexNative {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);

    // Per-monitor-v2 DPI awareness: must run before any WPF type is touched, otherwise Windows bitmap-stretches the pet.
    public static void EnableDpiAwareness() { try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { } }
    public static double SystemDpiScale() { try { return GetDpiForSystem() / 96.0; } catch { return 1.0; } }

    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // Re-assert "always on top" without activating: other topmost overlays (e.g. Codex's own pet) can end up above us.
    public static void KeepOnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200); }

    // WS_EX_TOOLWINDOW (hidden from Alt-Tab) | WS_EX_NOACTIVATE (never steals focus from Claude)
    public static void MakeOverlay(IntPtr h) { int s = GetWindowLong(h, -20); SetWindowLong(h, -20, s | 0x80 | 0x08000000); }

    public static int CountAlpha(byte[] px, int stride, int x0, int y0, int w, int h) {
        int n = 0;
        for (int y = y0; y < y0 + h; y += 2)
            for (int x = x0; x < x0 + w; x += 2)
                if (px[y * stride + x * 4 + 3] > 16) n++;
        return n;
    }

    // ---- crisp resampling: Lanczos-3 on premultiplied alpha, straight BGRA in -> premultiplied BGRA out ----
    static double Sinc(double x) { if (x == 0) return 1; x *= Math.PI; return Math.Sin(x) / x; }
    static double Lanczos(double x) { x = Math.Abs(x); return x < 3 ? Sinc(x) * Sinc(x / 3) : 0; }
    static void Weights(int srcN, int dstN, out int[][] idx, out float[][] wt) {
        double scale = (double)srcN / dstN, fs = Math.Max(1.0, scale), sup = 3 * fs;
        idx = new int[dstN][]; wt = new float[dstN][];
        for (int o = 0; o < dstN; o++) {
            double c = (o + 0.5) * scale - 0.5;
            int lo = (int)Math.Floor(c - sup), hi = (int)Math.Ceiling(c + sup);
            List<int> ii = new List<int>(); List<float> ww = new List<float>(); double sum = 0;
            for (int k = lo; k <= hi; k++) {
                double w = Lanczos((k - c) / fs);
                if (w == 0) continue;
                ii.Add(Math.Min(srcN - 1, Math.Max(0, k))); ww.Add((float)w); sum += w;
            }
            for (int i = 0; i < ww.Count; i++) ww[i] = (float)(ww[i] / sum);
            idx[o] = ii.ToArray(); wt[o] = ww.ToArray();
        }
    }
    public static byte[] Resize(byte[] src, int srcStride, int x0, int y0, int sw, int sh, int tw, int th) {
        float[] pm = new float[sw * sh * 4];
        for (int y = 0; y < sh; y++)
            for (int x = 0; x < sw; x++) {
                int s = (y0 + y) * srcStride + (x0 + x) * 4, d = (y * sw + x) * 4;
                float a = src[s + 3] / 255f;
                pm[d] = src[s] * a; pm[d + 1] = src[s + 1] * a; pm[d + 2] = src[s + 2] * a; pm[d + 3] = src[s + 3];
            }
        int[][] xi, yi; float[][] xw, yw;
        Weights(sw, tw, out xi, out xw); Weights(sh, th, out yi, out yw);
        float[] tmp = new float[tw * sh * 4];
        for (int y = 0; y < sh; y++)
            for (int ox = 0; ox < tw; ox++) {
                float c0 = 0, c1 = 0, c2 = 0, c3 = 0; int[] ii = xi[ox]; float[] ww = xw[ox];
                for (int k = 0; k < ii.Length; k++) {
                    int s = (y * sw + ii[k]) * 4; float w = ww[k];
                    c0 += pm[s] * w; c1 += pm[s + 1] * w; c2 += pm[s + 2] * w; c3 += pm[s + 3] * w;
                }
                int d = (y * tw + ox) * 4; tmp[d] = c0; tmp[d + 1] = c1; tmp[d + 2] = c2; tmp[d + 3] = c3;
            }
        byte[] outp = new byte[tw * th * 4];
        for (int oy = 0; oy < th; oy++)
            for (int x = 0; x < tw; x++) {
                float c0 = 0, c1 = 0, c2 = 0, c3 = 0; int[] ii = yi[oy]; float[] ww = yw[oy];
                for (int k = 0; k < ii.Length; k++) {
                    int s = (ii[k] * tw + x) * 4; float w = ww[k];
                    c0 += tmp[s] * w; c1 += tmp[s + 1] * w; c2 += tmp[s + 2] * w; c3 += tmp[s + 3] * w;
                }
                float a = Math.Min(255f, Math.Max(0f, c3));
                int d = (oy * tw + x) * 4;
                outp[d]     = (byte)Math.Min(a, Math.Max(0f, c0) + 0.5f);
                outp[d + 1] = (byte)Math.Min(a, Math.Max(0f, c1) + 0.5f);
                outp[d + 2] = (byte)Math.Min(a, Math.Max(0f, c2) + 0.5f);
                outp[d + 3] = (byte)(a + 0.5f);
            }
        return outp;
    }

    // ---- real mouse click at screen pixel (x,y), then put the cursor back where it was ----
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, uint dx, uint dy, int d, UIntPtr e);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    public static void ClickAt(int x, int y) {
        POINT o; GetCursorPos(out o);
        SetCursorPos(x, y); System.Threading.Thread.Sleep(120);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(70); mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(150);
        SetCursorPos(o.X, o.Y);
    }

    // ---- bring the Claude desktop window forward / press a hotkey in it ----
    public static bool FocusProcessWindow(string procName) {
        IntPtr best = IntPtr.Zero;
        foreach (Process p in Process.GetProcessesByName(procName)) {
            try { if (p.MainWindowHandle != IntPtr.Zero) best = p.MainWindowHandle; } catch { }
        }
        if (best == IntPtr.Zero) return false;
        if (IsIconic(best)) ShowWindow(best, 9);
        keybd_event(0x12, 0, 0, UIntPtr.Zero);            // tap ALT so Windows allows the focus change
        SetForegroundWindow(best);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
        return true;
    }
    static byte Vk(string k) {
        k = k.Trim().ToLowerInvariant();
        switch (k) {
            case "ctrl": case "control": return 0x11;
            case "shift": return 0x10;
            case "alt": return 0x12;
            case "win": case "windows": return 0x5B;
            case "enter": return 0x0D; case "space": return 0x20; case "tab": return 0x09; case "esc": return 0x1B;
        }
        if (k.Length >= 2 && k[0] == 'f') { int n; if (int.TryParse(k.Substring(1), out n) && n >= 1 && n <= 12) return (byte)(0x6F + n); }
        if (k.Length == 1) return (byte)char.ToUpperInvariant(k[0]);
        return 0;
    }
    public static void SendHotkey(string combo) {
        if (string.IsNullOrEmpty(combo)) return;
        List<byte> keys = new List<byte>();
        foreach (string part in combo.Split('+')) { byte v = Vk(part); if (v != 0) keys.Add(v); }
        foreach (byte v in keys) { keybd_event(v, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(15); }
        for (int i = keys.Count - 1; i >= 0; i--) { keybd_event(keys[i], 0, 2, UIntPtr.Zero); System.Threading.Thread.Sleep(15); }
    }
}
'@
[ClawdexNative]::EnableDpiAwareness()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, $type) {
    $task = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $null = $task.Wait(-1)
    return $task.Result
}

# Decode an image keeping the alpha channel (WPF's built-in WebP decoder drops it; WinRT keeps it).
function Read-Pixels($path) {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $st = Await ($file.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($st)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $pd = Await ($dec.GetPixelDataAsync(
            [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
            [Windows.Graphics.Imaging.BitmapAlphaMode]::Straight,
            (New-Object Windows.Graphics.Imaging.BitmapTransform),
            [Windows.Graphics.Imaging.ExifOrientationMode]::IgnoreExifOrientation,
            [Windows.Graphics.Imaging.ColorManagementMode]::DoNotColorManage)) ([Windows.Graphics.Imaging.PixelDataProvider])
    return @{ W = [int]$dec.PixelWidth; H = [int]$dec.PixelHeight; Px = $pd.DetachPixelData() }
}

# Frame timings (ms) from the Codex 8x9 atlas spec; rows 9+ (spec v2 extras) use a default.
function Get-Durations($row, $n) {
    if ($row -eq 0 -and $n -ge 4) {
        $d = @(280, 110, 110) + @(140) * ($n - 4) + @(320)
        return $d
    }
    $bl = @{ 1 = @(120, 220); 2 = @(120, 220); 3 = @(140, 280); 4 = @(140, 280); 5 = @(140, 240); 6 = @(150, 260); 7 = @(120, 220); 8 = @(150, 280) }
    $p = if ($bl.ContainsKey($row)) { $bl[$row] } else { @(140, 240) }
    $d = @($p[0]) * [Math]::Max(0, $n - 1) + @($p[1])
    return $d
}

# A pet = the decoded sheet + per-row frame counts/timings. Frames are rendered on demand at the
# exact on-screen pixel size (see Get-Frame), so the lines stay sharp at any scale / DPI.
function Build-Pet($sheetPath) {
    $img = Read-Pixels $sheetPath
    $stride = $img.W * 4
    $bmp = [Windows.Media.Imaging.BitmapSource]::Create($img.W, $img.H, 96, 96, [Windows.Media.PixelFormats]::Bgra32, $null, $img.Px, $stride)
    $bmp.Freeze()
    $cols = [int][Math]::Floor($img.W / $CellW)
    $rows = [int][Math]::Floor($img.H / $CellH)
    $counts = New-Object 'int[]' $rows
    $durs = New-Object 'object[]' $rows
    for ($r = 0; $r -lt $rows; $r++) {
        $n = 0
        for ($c = 0; $c -lt $cols; $c++) {
            if ([ClawdexNative]::CountAlpha($img.Px, $stride, $c * $CellW, $r * $CellH, $CellW, $CellH) -lt 20) { break }
            $n++
        }
        $counts[$r] = $n
        $durs[$r] = @(Get-Durations $r $n)
    }
    return @{ Px = $img.Px; W = $img.W; H = $img.H; Sheet = $bmp; Rows = $rows; Counts = $counts; Durs = $durs }
}

function Get-CellBitmap($model, $r, $c) {
    $cb = New-Object Windows.Media.Imaging.CroppedBitmap($model.Sheet, (New-Object Windows.Int32Rect(($c * $CellW), ($r * $CellH), $CellW, $CellH)))
    $cb.Freeze()
    return $cb
}

# Square 256px .ico (PNG-compressed) from the pet's idle frame - used for the desktop shortcut.
if ($Command -eq 'icon') {
    $cfg = Get-Config; $pets = Get-Pets
    $sel = $pets | Where-Object { $_.Id -eq $cfg.pet } | Select-Object -First 1
    if (-not $sel) { $sel = $pets | Select-Object -First 1 }
    if (-not $sel) { return }
    $model = Build-Pet $sel.Sheet
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage((Get-CellBitmap $model 0 0), (New-Object Windows.Rect(32, 0, 192, 208)))
    $dc.Close()
    $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap(256, 256, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rt.Render($dv)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $png = $ms.ToArray()
    $out = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($out)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]1)
    $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$png.Length); $bw.Write([uint32]22)
    $bw.Write($png); $bw.Flush()
    [IO.File]::WriteAllBytes((Join-Path $Root 'clawdex.ico'), $out.ToArray())
    return
}

Remove-Item $LogPath -ErrorAction SilentlyContinue
try { if ((Test-Path $EvPath) -and (Get-Item $EvPath).Length -gt 262144) { Remove-Item $EvPath -Force } } catch {}

$script:Cfg = Get-Config
$pets = Get-Pets
if ($pets.Count -eq 0) {
    [void][Windows.MessageBox]::Show("No pets found.`nPut a pet folder (pet.json + spritesheet.webp) in:`n$($PetDirs -join "`n")", 'clawdex')
    exit 1
}
$sel = $pets | Where-Object { $_.Id -eq $script:Cfg.pet } | Select-Object -First 1
if (-not $sel) { $sel = $pets[0] }
$script:Cfg.pet = $sel.Id
$script:Pet = Build-Pet $sel.Sheet
Write-Log "pet=$($sel.Id) rows=$($script:Pet.Rows)"

# ---- window -----------------------------------------------------------------------------------
# Layout: sprite on top, a 38px strip below it that holds the hover-only "new chat | voice" pill.
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ResizeMode="NoResize" SizeToContent="WidthAndHeight" Title="clawdex"
        SnapsToDevicePixels="True" UseLayoutRounding="True">
  <Grid x:Name="Root" Background="#01000000" MinWidth="96">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="38"/>
    </Grid.RowDefinitions>
    <Image x:Name="Sprite" Grid.Row="0" Stretch="None" HorizontalAlignment="Center" VerticalAlignment="Top"
           RenderOptions.BitmapScalingMode="NearestNeighbor"/>
    <Border x:Name="CloseBtn" Grid.Row="0" Width="22" Height="22" CornerRadius="11" Background="#D0202020"
            HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,2,2,0" Cursor="Hand" Visibility="Collapsed">
      <TextBlock Text="&#x2715;" Foreground="White" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <!-- collapsed: a small dark capsule under the pet's feet; on hover it grows into the two buttons -->
    <Grid x:Name="Pill" Grid.Row="1" Width="24" Height="6" ClipToBounds="True"
          HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,4,0,0">
      <Rectangle x:Name="PillBg" Fill="#F01C1C1C" RadiusX="3" RadiusY="3"/>
      <StackPanel x:Name="PillBtns" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center"
                  Opacity="0" IsHitTestVisible="False">
        <Border x:Name="BtnNew" Width="39" Height="34" CornerRadius="17,0,0,17" Background="#01FFFFFF" Cursor="Hand">
          <TextBlock Text="&#xE70F;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#E6E6E6"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <Rectangle Width="1" Margin="0,9,0,9" Fill="#40FFFFFF"/>
        <Border x:Name="BtnVoice" Width="40" Height="34" CornerRadius="0,17,17,0" Background="#01FFFFFF" Cursor="Hand">
          <StackPanel x:Name="VoiceBars" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <Rectangle Width="2" Height="6"  Fill="#E6E6E6" Margin="0,0,2,0" RadiusX="1" RadiusY="1"/>
            <Rectangle Width="2" Height="12" Fill="#E6E6E6" Margin="0,0,2,0" RadiusX="1" RadiusY="1"/>
            <Rectangle Width="2" Height="16" Fill="#E6E6E6" Margin="0,0,2,0" RadiusX="1" RadiusY="1"/>
            <Rectangle Width="2" Height="10" Fill="#E6E6E6" Margin="0,0,2,0" RadiusX="1" RadiusY="1"/>
            <Rectangle Width="2" Height="5"  Fill="#E6E6E6" RadiusX="1" RadiusY="1"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$rootGrid = $window.FindName('Root')
$sprite = $window.FindName('Sprite')
$closeBtn = $window.FindName('CloseBtn')
$pill = $window.FindName('Pill')
$btnNew = $window.FindName('BtnNew')
$btnVoice = $window.FindName('BtnVoice')
$pillBtns = $window.FindName('PillBtns')
$pillBg = $window.FindName('PillBg')
$voiceBars = $window.FindName('VoiceBars')
$closeBtn.ToolTip = '펫 닫기 (다시 켜기: 바탕화면의 Clawdex Pet 바로가기)'
$btnNew.ToolTip = '새 대화 시작'
$btnVoice.ToolTip = '음성'

$MinScale = 0.3
$MaxScale = 2.0
$MinWinW = 96
$StripH = 38
$script:Dpi = [ClawdexNative]::SystemDpiScale()
$script:TW = 0; $script:TH = 0
$script:FrameCache = @{}

# Render a cell at the exact device-pixel size with Lanczos-3 (cached per scale/DPI).
function Get-Frame($r, $c) {
    $k = "$r,$c"
    $f = $script:FrameCache[$k]
    if ($f) { return $f }
    $dpi96 = 96.0 * $script:Dpi
    $bytes = [ClawdexNative]::Resize($script:Pet.Px, $script:Pet.W * 4, $c * $CellW, $r * $CellH, $CellW, $CellH, $script:TW, $script:TH)
    $f = [Windows.Media.Imaging.BitmapSource]::Create($script:TW, $script:TH, $dpi96, $dpi96, [Windows.Media.PixelFormats]::Pbgra32, $null, $bytes, $script:TW * 4)
    $f.Freeze()
    $script:FrameCache[$k] = $f
    return $f
}

function Update-Metrics {
    $script:TW = [Math]::Max(8, [int][Math]::Round($CellW * $script:Cfg.scale * $script:Dpi))
    $script:TH = [Math]::Max(8, [int][Math]::Round($CellH * $script:Cfg.scale * $script:Dpi))
    $script:FrameCache = @{}
    $sprite.Width = $script:TW / $script:Dpi
    $sprite.Height = $script:TH / $script:Dpi
}

function Get-WinSize { return @([Math]::Max($sprite.Width, $MinWinW), ($sprite.Height + $StripH)) }

function Set-Scale($s) {
    $s = [Math]::Round([Math]::Max($MinScale, [Math]::Min($MaxScale, [double]$s)), 2)
    $loaded = $window.IsLoaded -and $sprite.Width -gt 0
    if ($loaded) { $old = Get-WinSize }
    $script:Cfg.scale = $s
    Update-Metrics
    if ($loaded) {
        # keep the pet's bottom-right corner fixed so resizing never pushes it off screen
        $new = Get-WinSize
        $window.Left += $old[0] - $new[0]
        $window.Top += $old[1] - $new[1]
        Show-Frame
    }
}
Update-Metrics

# ---- animation state --------------------------------------------------------------------------
# Row priority (when no one-shot "transient" is playing): drag > Claude activity > hover > idle.
$script:Row = 0; $script:Frame = 0; $script:Transient = $false
$script:StickyRow = -1; $script:StickyUntil = [DateTime]::MinValue
$script:Hover = $false; $script:DragRow = -1
$animTimer = New-Object Windows.Threading.DispatcherTimer

function Resolve-Row($r) {
    if ($r -ge 0 -and $r -lt $script:Pet.Rows -and $script:Pet.Counts[$r] -gt 0) { return $r }
    return 0
}
function Show-Frame {
    $n = $script:Pet.Counts[$script:Row]
    if ($script:Frame -ge $n) { $script:Frame = 0 }
    $sprite.Source = Get-Frame $script:Row $script:Frame
    $animTimer.Interval = [TimeSpan]::FromMilliseconds($script:Pet.Durs[$script:Row][$script:Frame])
}
function Set-Row($r) {
    $script:Row = Resolve-Row $r
    $script:Frame = 0
    Show-Frame
}
function Get-BaseRow {
    if ($script:DragRow -ge 0) { return $script:DragRow }
    if ($script:StickyRow -ge 0) {
        if ([DateTime]::UtcNow -le $script:StickyUntil) { return $script:StickyRow }
        $script:StickyRow = -1
    }
    if ($script:Hover) { return 3 }       # hovering an idle pet: wave
    return 0
}
function Update-Base {
    if ($script:Transient) { return }
    $r = Resolve-Row (Get-BaseRow)
    if ($r -ne $script:Row) { Set-Row $r }
}

# Claude Code hook event -> pet animation. Rows: 0 idle, 3 waving, 4 jumping, 5 failed, 6 waiting, 7 running, 8 review.
function Map-Event($ev, $tool) {
    switch ($ev) {
        'SessionStart'     { return @{ Mode = 'transient'; Row = 3; Clear = $true } }
        'UserPromptSubmit' { return @{ Mode = 'sticky'; Row = 8; Ttl = 180 } }
        'PreToolUse' {
            if ($tool -in 'Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'LS') { return @{ Mode = 'sticky'; Row = 8; Ttl = 180 } }
            return @{ Mode = 'sticky'; Row = 7; Ttl = 180 }
        }
        'PostToolUse'      { return @{ Mode = 'sticky'; Row = 8; Ttl = 180 } }
        'PreCompact'       { return @{ Mode = 'sticky'; Row = 8; Ttl = 180 } }
        'SubagentStop'     { return @{ Mode = 'sticky'; Row = 8; Ttl = 180 } }
        'Notification'     { return @{ Mode = 'sticky'; Row = 6; Ttl = 900 } }
        'Stop'             { return @{ Mode = 'transient'; Row = 3; Clear = $true } }
        'SessionEnd'       { return @{ Mode = 'idle' } }
    }
    return $null
}

function Apply-Event($ev, $tool) {
    if ($ev -eq 'Quit')     { $window.Close(); return }
    if ($ev -eq 'Reload')   { Switch-Pet ''; return }
    if ($ev -eq 'ShowSize') { Show-SizePopup; return }
    if ($ev -eq 'ActionNew')   { Invoke-ClaudeAction 'new' $script:Cfg.newChatHotkey; return }
    if ($ev -eq 'ActionVoice') { Invoke-ClaudeAction 'voice' $script:Cfg.voiceHotkey; return }
    $m = Map-Event $ev $tool
    if (-not $m) { return }
    Write-Log "$ev $tool -> $($m.Mode) row $($m.Row)"
    switch ($m.Mode) {
        'sticky' {
            $script:StickyRow = Resolve-Row $m.Row
            $script:StickyUntil = [DateTime]::UtcNow.AddSeconds($m.Ttl)
            Update-Base
        }
        'transient' {
            if ($m.Clear) { $script:StickyRow = -1 }
            $script:Transient = $true
            Set-Row $m.Row
        }
        'idle' {
            $script:StickyRow = -1
            Update-Base
        }
    }
}

$animTimer.add_Tick({
    if (-not $script:Transient) {
        $base = Resolve-Row (Get-BaseRow)
        if ($base -ne $script:Row) { Set-Row $base; return }
    }
    $n = $script:Pet.Counts[$script:Row]
    $script:Frame++
    if ($script:Frame -ge $n) {
        $script:Frame = 0
        if ($script:Transient) {
            $script:Transient = $false
            $script:Row = Resolve-Row (Get-BaseRow)
        }
    }
    Show-Frame
})

function Switch-Pet($id) {
    $all = Get-Pets
    if (-not $id) { $id = (Get-Config).pet }
    $p = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if (-not $p) { return }
    try { $model = Build-Pet $p.Sheet } catch { Write-Log "switch failed: $_"; return }
    $script:Pet = $model
    $script:FrameCache = @{}
    $script:Cfg.pet = $p.Id
    Save-Config $script:Cfg
    $script:Transient = $false; $script:StickyRow = -1
    Set-Row 0
    Update-Tray
}

# ---- event inbox (written by clawdex-hook.exe) ------------------------------------------------
$script:Offset = 0
if (Test-Path $EvPath) { $script:Offset = (Get-Item $EvPath).Length }
$evTimer = New-Object Windows.Threading.DispatcherTimer
$evTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$evTimer.add_Tick({
    if (-not (Test-Path $EvPath)) { $script:Offset = 0; return }
    $text = ''
    try {
        $fs = [IO.File]::Open($EvPath, 'Open', 'Read', 'ReadWrite,Delete')
        try {
            if ($fs.Length -lt $script:Offset) { $script:Offset = 0 }
            if ($fs.Length -eq $script:Offset) { return }
            $fs.Position = $script:Offset
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $script:Offset = $fs.Length
        } finally { $fs.Close() }
    } catch { return }
    foreach ($line in $text -split "`n") {
        if ($line -match '"event":"([^"]*)"') {
            $e = $Matches[1]; $t = ''
            if ($line -match '"tool":"([^"]*)"') { $t = $Matches[1] }
            Apply-Event $e $t
        }
    }
})

# ---- Claude window / buttons ------------------------------------------------------------------
function Open-Claude {
    if ([ClawdexNative]::FocusProcessWindow('claude')) { return $true }
    try {   # not running / hidden in tray: launch the packaged app
        $app = Get-StartApps | Where-Object { $_.Name -eq 'Claude' } | Select-Object -First 1
        if ($app) { Start-Process explorer.exe ('shell:AppsFolder\' + $app.AppID); return $false }
    } catch {}
    return $false
}
# The pill buttons drive the real Claude UI through UI Automation (Chromium builds its accessibility tree
# lazily, so the first lookup can take a second or two -> poll with a timer instead of blocking the pet).
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$UiaNewNames   = @('새로 생성', '새 세션', '새 채팅', '새 대화', 'New session', 'New chat', 'New conversation')
$UiaVoiceNames = @('길게 눌러 녹음', 'Hold to record', 'Hold to dictate', 'Dictate', '받아쓰기', '음성 입력')

function Get-ClaudeRoot {
    $p = Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    if ($p) { return [Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle) }
    return $null
}
function Find-UiaButton($root, $names) {
    $AE = [Windows.Automation.AutomationElement]
    $isButton = New-Object Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [Windows.Automation.ControlType]::Button)
    foreach ($n in $names) {
        $cond = New-Object Windows.Automation.AndCondition($isButton, (New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $n)))
        $e = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
        if ($e) { return $e }
    }
    return $null
}

$script:UiaTask = $null
$uiaTimer = New-Object Windows.Threading.DispatcherTimer
$uiaTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$uiaTimer.add_Tick({
    $t = $script:UiaTask
    if (-not $t) { $uiaTimer.Stop(); return }
    $t.Tries++
    $done = $false
    try {
        $root = Get-ClaudeRoot
        if ($root) {
            $e = Find-UiaButton $root $(if ($t.Kind -eq 'new') { $UiaNewNames } else { $UiaVoiceNames })
            if ($e) {
                $ip = $null
                $rc = $e.Current.BoundingRectangle
                if ($t.Kind -eq 'voice' -and $rc.Width -gt 0 -and $rc.Height -gt 0) {
                    # the mic is a press-style button: UIA Toggle() doesn't reach its pointer handlers, so click it for real
                    [ClawdexNative]::ClickAt([int]($rc.X + $rc.Width / 2), [int]($rc.Y + $rc.Height / 2))
                    Write-Log "voice: clicked '$($e.Current.Name)'"
                    $done = $true
                } elseif ($e.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) {
                    $ip.Invoke(); Write-Log "$($t.Kind): invoked '$($e.Current.Name)'"
                    $done = $true
                }
            }
        }
    } catch { Write-Log "uia error: $_" }
    if ($done) { $uiaTimer.Stop(); $script:UiaTask = $null; return }
    if ($t.Tries -ge 14) {                         # ~5s: give up on UIA, use the optional hotkey fallback
        $uiaTimer.Stop(); $script:UiaTask = $null
        Write-Log "uia: button not found for $($t.Kind)"
        if ($t.Hotkey) { try { [ClawdexNative]::SendHotkey($t.Hotkey) } catch {} }
    }
})
function Invoke-ClaudeAction($kind, $fallbackHotkey) {
    $focused = Open-Claude
    Write-Log "action $kind focused=$focused"
    $script:UiaTask = @{ Kind = $kind; Tries = 0; Hotkey = [string]$fallbackHotkey }
    $uiaTimer.Stop(); $uiaTimer.Start()
}

# the pill: collapsed capsule <-> two buttons
function Animate-Pill($open) {
    $dur = [TimeSpan]::FromMilliseconds(150)
    $ease = New-Object Windows.Media.Animation.QuadraticEase
    $ease.EasingMode = 'EaseOut'
    # sizes measured from Codex's own pet: capsule ~24x6, open pill ~80x34 (corner radius = half the height)
    $targets = @(
        @($pill, [Windows.FrameworkElement]::WidthProperty, $(if ($open) { 80.0 } else { 24.0 }), 0),
        @($pill, [Windows.FrameworkElement]::HeightProperty, $(if ($open) { 34.0 } else { 6.0 }), 0),
        @($pillBg, [Windows.Shapes.Rectangle]::RadiusXProperty, $(if ($open) { 17.0 } else { 3.0 }), 0),
        @($pillBg, [Windows.Shapes.Rectangle]::RadiusYProperty, $(if ($open) { 17.0 } else { 3.0 }), 0),
        @($pillBtns, [Windows.UIElement]::OpacityProperty, $(if ($open) { 1.0 } else { 0.0 }), $(if ($open) { 70 } else { 0 }))
    )
    foreach ($t in $targets) {
        $a = New-Object Windows.Media.Animation.DoubleAnimation
        $a.To = $t[2]; $a.Duration = $dur; $a.EasingFunction = $ease
        $a.BeginTime = [TimeSpan]::FromMilliseconds($t[3])
        $t[0].BeginAnimation($t[1], $a)
    }
    $pillBtns.IsHitTestVisible = $open
}

# ---- interaction ------------------------------------------------------------------------------
# hover: wave + show "new chat | voice" pill and the X
$rootGrid.add_MouseEnter({
    $script:Hover = $true
    $closeBtn.Visibility = 'Visible'; Animate-Pill $true
    Update-Base
})
$rootGrid.add_MouseLeave({
    $script:Hover = $false
    $closeBtn.Visibility = 'Collapsed'; Animate-Pill $false
    Update-Base
})

$closeBtn.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
$closeBtn.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; $window.Close() })

$hoverOn = { param($s, $e) $s.Background = '#40FFFFFF' }
$hoverOff = { param($s, $e) $s.Background = '#01FFFFFF' }
foreach ($b in @($btnNew, $btnVoice)) {
    $b.add_MouseEnter($hoverOn); $b.add_MouseLeave($hoverOff)
    $b.add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
}
$btnNew.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ClaudeAction 'new' $script:Cfg.newChatHotkey })
$btnVoice.add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Invoke-ClaudeAction 'voice' $script:Cfg.voiceHotkey })

# drag: our own loop so we know the direction (right -> running-right row, left -> running-left row)
$script:Dragging = $false; $script:Moved = $false
$script:DragStartMouse = $null; $script:DragStartWin = $null; $script:LastMouseX = 0
$rootGrid.add_MouseLeftButtonDown({
    $script:Dragging = $true; $script:Moved = $false
    $script:DragStartMouse = [Windows.Forms.Cursor]::Position
    $script:LastMouseX = $script:DragStartMouse.X
    $script:DragStartWin = @($window.Left, $window.Top)
    [void]$rootGrid.CaptureMouse()
})
$rootGrid.add_MouseMove({
    if (-not $script:Dragging) { return }
    $cur = [Windows.Forms.Cursor]::Position
    $dx = $cur.X - $script:DragStartMouse.X; $dy = $cur.Y - $script:DragStartMouse.Y
    if (-not $script:Moved -and ([Math]::Abs($dx) -ge 4 -or [Math]::Abs($dy) -ge 4)) { $script:Moved = $true }
    if (-not $script:Moved) { return }
    $window.Left = $script:DragStartWin[0] + $dx / $script:Dpi
    $window.Top = $script:DragStartWin[1] + $dy / $script:Dpi
    if ([Math]::Abs($cur.X - $script:LastMouseX) -ge 2) {
        $script:DragRow = if ($cur.X -gt $script:LastMouseX) { 1 } else { 2 }
        $script:LastMouseX = $cur.X
        $script:Transient = $false
        Update-Base
    } elseif ($script:DragRow -lt 0) {
        $script:DragRow = 7                       # moving purely vertically
        $script:Transient = $false
        Update-Base
    }
})
$rootGrid.add_MouseLeftButtonUp({
    if (-not $script:Dragging) { return }
    $script:Dragging = $false
    $rootGrid.ReleaseMouseCapture()
    $script:DragRow = -1
    if ($script:Moved) {
        $script:Cfg.left = $window.Left; $script:Cfg.top = $window.Top
        Save-Config $script:Cfg
        Update-Base
    } else {
        Open-Claude | Out-Null              # plain click: bring Claude to the front, with a little hop
        $script:Transient = $true
        Set-Row 4
    }
})

$menu = New-Object Windows.Controls.ContextMenu
$menu.StaysOpen = $false
$miClose = New-Object Windows.Controls.MenuItem; $miClose.Header = '펫 닫기'
$miClose.add_Click({ $window.Close() })
$miSize = New-Object Windows.Controls.MenuItem; $miSize.Header = '크기'
$sizeHandler = { param($s, $e) Set-Scale ([double]$s.Tag); Save-Config $script:Cfg }
foreach ($opt in @(@('작게', 0.5), @('보통', 0.8), @('크게', 1.2), @('아주 크게', 1.6))) {
    $mi = New-Object Windows.Controls.MenuItem; $mi.Header = $opt[0]; $mi.Tag = $opt[1]
    $mi.add_Click($sizeHandler); [void]$miSize.Items.Add($mi)
}
$miPets = New-Object Windows.Controls.MenuItem; $miPets.Header = '펫 변경'
$petHandler = { param($s, $e) Switch-Pet ([string]$s.Tag) }
$miPets.add_SubmenuOpened({
    $miPets.Items.Clear()
    foreach ($p in Get-Pets) {
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $p.Name; $mi.Tag = $p.Id; $mi.IsChecked = ($p.Id -eq $script:Cfg.pet)
        $mi.add_Click($petHandler); [void]$miPets.Items.Add($mi)
    }
})
[void]$miPets.Items.Add((New-Object Windows.Controls.MenuItem))
[void]$menu.Items.Add($miPets); [void]$menu.Items.Add($miSize)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator)); [void]$menu.Items.Add($miClose)
$rootGrid.ContextMenu = $menu

# mouse wheel over the pet = resize
$rootGrid.add_MouseWheel({
    param($s, $e)
    Set-Scale ($script:Cfg.scale + $(if ($e.Delta -gt 0) { 0.05 } else { -0.05 }))
    Save-Config $script:Cfg
})

# ---- system tray icon: left-click = size slider, right-click = menu --------------------------
$script:PopClosedAt = [DateTime]::MinValue
function Show-SizePopup {
    if ($script:Pop -and $script:Pop.IsVisible) { $script:Pop.Close(); return }
    if (([DateTime]::UtcNow - $script:PopClosedAt).TotalMilliseconds -lt 300) { return }   # the tray click that just dismissed it
    $px = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" Topmost="True" ShowInTaskbar="False"
        SizeToContent="Height" Width="280" Background="#FAFAFA" BorderBrush="#B0B0B0" BorderThickness="1">
  <StackPanel Margin="16,14,16,14">
    <Grid>
      <TextBlock x:Name="Title" FontSize="13" FontWeight="SemiBold" Foreground="#222"/>
      <TextBlock x:Name="Pct" FontSize="13" HorizontalAlignment="Right" Foreground="#222"/>
    </Grid>
    <Slider x:Name="Sl" Margin="0,12,0,12" IsMoveToPointEnabled="True" TickFrequency="0.1" SmallChange="0.05" LargeChange="0.1"/>
    <UniformGrid x:Name="Btns" Rows="1"/>
  </StackPanel>
</Window>
'@
    $pop = [Windows.Markup.XamlReader]::Parse($px)
    $script:Pop = $pop
    $script:PopSl = $pop.FindName('Sl'); $script:PopPct = $pop.FindName('Pct')
    $pop.FindName('Title').Text = '펫 크기'
    $script:PopSl.Minimum = $MinScale; $script:PopSl.Maximum = $MaxScale
    $script:PopSl.Value = [double]$script:Cfg.scale
    $script:PopPct.Text = '{0}%' -f [int][Math]::Round($script:Cfg.scale * 100)
    $script:PopSl.add_ValueChanged({
        Set-Scale $script:PopSl.Value
        $script:PopPct.Text = '{0}%' -f [int][Math]::Round($script:Cfg.scale * 100)
    })
    $presetClick = {
        param($s, $e)
        Set-Scale ([double]$s.Tag)
        $script:PopSl.Value = [double]$script:Cfg.scale
    }
    foreach ($opt in @(@('작게', 0.5), @('보통', 0.8), @('크게', 1.2), @('최대', 2.0))) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $opt[0]; $b.Tag = $opt[1]; $b.Margin = '2,0,2,0'; $b.Padding = '4,3,4,3'
        $b.add_Click($presetClick)
        [void]$pop.FindName('Btns').Children.Add($b)
    }
    $pop.add_Deactivated({ if ($script:Pop) { $script:Pop.Close() } })
    $pop.add_Closed({ $script:Pop = $null; $script:PopClosedAt = [DateTime]::UtcNow; Save-Config $script:Cfg })
    $wa = [Windows.SystemParameters]::WorkArea
    $pop.Left = $wa.Right - 280 - 12
    $pop.Top = $wa.Bottom - 130
    $pop.Show(); [void]$pop.Activate()
}

function New-TrayIcon {
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawImage((Get-CellBitmap $script:Pet 0 0), (New-Object Windows.Rect(2.5, 0, 59, 64)))
    $dc.Close()
    $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rt.Render($dv)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
    $ms = New-Object IO.MemoryStream; $enc.Save($ms); $ms.Position = 0
    return [Drawing.Icon]::FromHandle(([Drawing.Bitmap]::new($ms)).GetHicon())
}
function Update-Tray { try { $script:Tray.Icon = New-TrayIcon } catch {} }

$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.Icon = New-TrayIcon
$script:Tray.Text = 'Clawdex Pet - 클릭: 크기 조절'
$cms = New-Object Windows.Forms.ContextMenuStrip
$tSlider = New-Object Windows.Forms.ToolStripMenuItem('크기 조절창 열기...')
$tSlider.add_Click({ Show-SizePopup })
$tSize = New-Object Windows.Forms.ToolStripMenuItem('크기')
$tSizeClick = { param($s, $e) Set-Scale ([double]$s.Tag); Save-Config $script:Cfg }
foreach ($opt in @(@('작게 (50%)', 0.5), @('보통 (80%)', 0.8), @('크게 (120%)', 1.2), @('아주 크게 (160%)', 1.6))) {
    $ti = New-Object Windows.Forms.ToolStripMenuItem($opt[0]); $ti.Tag = $opt[1]
    $ti.add_Click($tSizeClick); [void]$tSize.DropDownItems.Add($ti)
}
$script:TPets = New-Object Windows.Forms.ToolStripMenuItem('펫 변경')
$script:TToggle = New-Object Windows.Forms.ToolStripMenuItem('펫 숨기기')
$script:TToggle.add_Click({ if ($window.IsVisible) { $window.Hide() } else { $window.Show() } })
$tQuit = New-Object Windows.Forms.ToolStripMenuItem('종료')
$tQuit.add_Click({ $window.Close() })
[void]$cms.Items.Add($tSlider); [void]$cms.Items.Add($tSize); [void]$cms.Items.Add($script:TPets)
[void]$cms.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
[void]$cms.Items.Add($script:TToggle); [void]$cms.Items.Add($tQuit)
$tPetClick = { param($s, $e) Switch-Pet ([string]$s.Tag) }
$cms.add_Opening({
    $script:TToggle.Text = if ($window.IsVisible) { '펫 숨기기' } else { '펫 보이기' }
    $script:TPets.DropDownItems.Clear()
    foreach ($p in Get-Pets) {
        $ti = New-Object Windows.Forms.ToolStripMenuItem($p.Name)
        $ti.Tag = $p.Id; $ti.Checked = ($p.Id -eq $script:Cfg.pet)
        $ti.add_Click($tPetClick); [void]$script:TPets.DropDownItems.Add($ti)
    }
})
$script:Tray.ContextMenuStrip = $cms
$script:Tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-SizePopup }
})
$script:Tray.Visible = $true

# ---- startup ----------------------------------------------------------------------------------
$window.add_SourceInitialized({
    [ClawdexNative]::MakeOverlay((New-Object Windows.Interop.WindowInteropHelper($window)).Handle)
})
$topTimer = New-Object Windows.Threading.DispatcherTimer
$topTimer.Interval = [TimeSpan]::FromSeconds(2)
$topTimer.add_Tick({
    if ($window.IsVisible -and -not $script:Dragging) {
        try { [ClawdexNative]::KeepOnTop((New-Object Windows.Interop.WindowInteropHelper($window)).Handle) } catch {}
    }
})
try {
    $window.add_DpiChanged({
        param($s, $e)
        $script:Dpi = $e.NewDpi.DpiScaleX
        Update-Metrics
        Show-Frame
    })
} catch {}
$window.add_Loaded({
    try { $script:Dpi = [Windows.Media.VisualTreeHelper]::GetDpi($window).DpiScaleX } catch {}
    Update-Metrics
    $ws = Get-WinSize; $w = $ws[0]; $h = $ws[1]
    $vl = [Windows.SystemParameters]::VirtualScreenLeft; $vt = [Windows.SystemParameters]::VirtualScreenTop
    $vr = $vl + [Windows.SystemParameters]::VirtualScreenWidth; $vb = $vt + [Windows.SystemParameters]::VirtualScreenHeight
    $l = $script:Cfg.left; $t = $script:Cfg.top
    if ($null -eq $l -or $null -eq $t -or $l -lt $vl - $w / 2 -or $l -gt $vr - $w / 2 -or $t -lt $vt -or $t -gt $vb - $h / 2) {
        $wa = [Windows.SystemParameters]::WorkArea
        $l = $wa.Right - $w - 24; $t = $wa.Bottom - $h - 8
    }
    # keep the whole window (incl. the pill strip) inside the monitor's work area, i.e. above the taskbar
    try {
        $scr = [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point([int]($l * $script:Dpi), [int]($t * $script:Dpi))))
        $wr = $scr.WorkingArea
        $l = [Math]::Max($wr.Left / $script:Dpi, [Math]::Min($l, $wr.Right / $script:Dpi - $w))
        $t = [Math]::Max($wr.Top / $script:Dpi, [Math]::Min($t, $wr.Bottom / $script:Dpi - $h - 2))
    } catch {}
    $window.Left = $l; $window.Top = $t
    $script:Transient = $true
    Set-Row 3                  # wave hello on launch
    $animTimer.Start(); $evTimer.Start()
    $topTimer.Start()
})
$window.add_Closing({
    $evTimer.Stop(); $animTimer.Stop(); $uiaTimer.Stop(); $topTimer.Stop()
    try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch {}
    if ($null -ne $window.Left) { $script:Cfg.left = $window.Left; $script:Cfg.top = $window.Top }
    Save-Config $script:Cfg
    try { $mutex.ReleaseMutex() } catch {}
})

[void]$window.ShowDialog()
