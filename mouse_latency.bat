<# :
@echo off
setlocal
chcp 65001 >nul
title Mouse test
set "SRC=%~f0"
set "PS1=%TEMP%\mouse_test_%RANDOM%.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:SRC,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($env:PS1,$t,(New-Object Text.UTF8Encoding $true))"
if not exist "%PS1%" (
  echo [ERROR] Could not create temp script in %TEMP%
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
del "%PS1%" >nul 2>&1
echo.
pause
exit /b
#>

# ============================================================
#  Тест мыши: частота опроса, задержки, перемещение, процессор.
#  Результат — 4 файла на рабочем столе для mouse_analyzer.html:
#    1_info.txt — характеристики мыши и условия замера
#    2_latency.csv — время каждого отчёта мыши
#    3_movement.csv — смещение X/Y в каждом отчёте
#    4_cpu.json — процессор: загрузка, потоки, программы
# ============================================================

[Console]::OutputEncoding = [Text.Encoding]::UTF8
trap {
    Write-Host "`nОШИБКА: $_" -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    break
}

$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

// Окно на весь экран: замер идёт, пока оно АКТИВНО.
// Windows 11 ограничивает Raw Input для фоновых окон до ~125 Гц,
// поэтому фоновый замер занижает частоту опроса.
public class MouseRec {
    public List<long> T = new List<long>(200000);
    public List<int> X = new List<int>(200000);
    public List<int> Y = new List<int>(200000);
}

public class RawMouse : Form {
    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")]
    static extern uint GetRawInputData(IntPtr h, uint cmd, byte[] data, ref uint size, uint hdrSize);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetRawInputDeviceInfo(IntPtr h, uint cmd, System.Text.StringBuilder data, ref uint size);
    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    const int  WM_INPUT        = 0x00FF;
    const uint RID_INPUT       = 0x10000003;
    const uint RIDEV_INPUTSINK = 0x00000100;

    public static Dictionary<IntPtr, MouseRec> Data = new Dictionary<IntPtr, MouseRec>();
    public static int BgEvents = 0;
    public static bool Cancelled = false;
    static bool measuring = false;
    static Stopwatch sw = Stopwatch.StartNew();
    static int hdr = 8 + 2 * IntPtr.Size;
    byte[] buf = new byte[256];
    Label lbl;

    RawMouse() {
        Text = "Mouse latency test";
        FormBorderStyle = FormBorderStyle.None;
        WindowState = FormWindowState.Maximized;
        TopMost = true;
        BackColor = Color.FromArgb(18, 18, 18);
        KeyPreview = true;
        lbl = new Label();
        lbl.Dock = DockStyle.Fill;
        lbl.TextAlign = ContentAlignment.MiddleCenter;
        lbl.ForeColor = Color.White;
        lbl.Font = new Font("Segoe UI", 32, FontStyle.Bold);
        Controls.Add(lbl);
        KeyDown += (s, e) => { if (e.KeyCode == Keys.Escape) { Cancelled = true; measuring = false; Active = false; Close(); } };
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
        d[0].UsagePage = 1; d[0].Usage = 2; d[0].Flags = RIDEV_INPUTSINK; d[0].Target = Handle;
        if (!RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
            throw new Exception("RegisterRawInputDevices error " + Marshal.GetLastWin32Error());
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_INPUT && measuring) {
            long t = sw.ElapsedTicks;
            uint size = (uint)buf.Length;
            uint r = GetRawInputData(m.LParam, RID_INPUT, buf, ref size, (uint)hdr);
            if (r != 0xFFFFFFFF && r >= hdr + 24 && BitConverter.ToUInt32(buf, 0) == 0) {
                int dx = BitConverter.ToInt32(buf, hdr + 12);
                int dy = BitConverter.ToInt32(buf, hdr + 16);
                if (dx != 0 || dy != 0) {
                    if (GetForegroundWindow() != Handle) BgEvents++;
                    IntPtr dev = IntPtr.Size == 8 ? new IntPtr(BitConverter.ToInt64(buf, 8))
                                                  : new IntPtr(BitConverter.ToInt32(buf, 8));
                    MouseRec rc;
                    if (!Data.TryGetValue(dev, out rc)) { rc = new MouseRec(); Data[dev] = rc; }
                    rc.T.Add(t); rc.X.Add(dx); rc.Y.Add(dy);
                }
            }
        }
        base.WndProc(ref m);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll")] static extern bool HidD_GetProductString(IntPtr h, byte[] b, int len);
    [DllImport("hid.dll")] static extern bool HidD_GetManufacturerString(IntPtr h, byte[] b, int len);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll", EntryPoint = "GetRawInputDeviceInfoW")]
    static extern uint GetRawInputDeviceInfoBuf(IntPtr h, uint cmd, byte[] data, ref uint size);

    static string HidStr(byte[] b) {
        string s = System.Text.Encoding.Unicode.GetString(b);
        int i = s.IndexOf('\0');
        return (i >= 0 ? s.Substring(0, i) : s).Trim();
    }

    // [0] продукт, [1] производитель, [2] версия, [3] кнопок, [4] гориз. колесо, [5] частота драйвера, [6] id
    public static string[] HidInfo(IntPtr dev, string path) {
        string[] r = new string[7];
        try {
            byte[] di = new byte[32];
            BitConverter.GetBytes((uint)32).CopyTo(di, 0);
            uint sz = 32;
            if (GetRawInputDeviceInfoBuf(dev, 0x2000000b, di, ref sz) != 0xFFFFFFFF && BitConverter.ToUInt32(di, 4) == 0) {
                r[6] = BitConverter.ToUInt32(di, 8).ToString();
                r[3] = BitConverter.ToUInt32(di, 12).ToString();
                r[5] = BitConverter.ToUInt32(di, 16).ToString();
                r[4] = BitConverter.ToInt32(di, 20) != 0 ? "есть" : "нет";
            }
        } catch { }
        IntPtr h = CreateFile(path, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h != IntPtr.Zero && h != new IntPtr(-1)) {
            try {
                byte[] b = new byte[512];
                if (HidD_GetProductString(h, b, b.Length)) r[0] = HidStr(b);
                b = new byte[512];
                if (HidD_GetManufacturerString(h, b, b.Length)) r[1] = HidStr(b);
                HIDD_ATTRIBUTES a = new HIDD_ATTRIBUTES();
                a.Size = Marshal.SizeOf(typeof(HIDD_ATTRIBUTES));
                if (HidD_GetAttributes(h, ref a)) r[2] = (a.VersionNumber >> 8).ToString("X") + "." + (a.VersionNumber & 0xFF).ToString("X2");
            } catch { }
            finally { CloseHandle(h); }
        }
        return r;
    }

    public static string DeviceName(IntPtr h) {
        uint size = 0;
        GetRawInputDeviceInfo(h, 0x20000007, null, ref size);
        if (size == 0) return "?";
        System.Text.StringBuilder sb = new System.Text.StringBuilder((int)size + 1);
        GetRawInputDeviceInfo(h, 0x20000007, sb, ref size);
        return sb.ToString();
    }

    public static double TickMs { get { return 1000.0 / Stopwatch.Frequency; } }
    public static long QpcOffset { get { return Stopwatch.GetTimestamp() - sw.ElapsedTicks; } }

    // ---- счётчики процессора через PDH: все потоки одним запросом ----
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhOpenQuery(string src, IntPtr user, out IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhAddEnglishCounter(IntPtr q, string path, IntPtr user, out IntPtr c);
    [DllImport("pdh.dll")] static extern uint PdhCollectQueryData(IntPtr q);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] static extern uint PdhGetFormattedCounterArray(IntPtr c, uint fmt, ref uint size, out uint count, IntPtr buf);
    const uint PDH_FMT_DOUBLE = 0x00000200, PDH_FMT_NOCAP100 = 0x00008000, PDH_MORE_DATA = 0x800007D2;

    public static int Cpu = 10;
    public static int NCpu = Environment.ProcessorCount;
    public static int SampleMs = 50;
    public static long StartTick, EndTick;
    public static string SamplerError;
    public static volatile bool Active;            // идёт замер (для процессов и активного окна)
    static List<double[]> samples = new List<double[]>();
    static volatile bool sampling;
    static volatile int snapReq;
    static System.Threading.Thread sampler;
    static IntPtr pdhQ = IntPtr.Zero;
    static IntPtr[] pdhC;
    // Загрузка потоков: короткие окна 50 мс Windows считает неточно (простой ядра обновляется рывками),
    // поэтому среднее берём за весь замер, а пики — по окнам 1 с.
    static IntPtr qAvg = IntPtr.Zero, cAvg, qSec = IntPtr.Zero, cSec;
    public static double[] AvgLoads, MaxLoads;
    public static bool UseEtw;
    // ---- быстрое / медленное движение и простои мыши (по окнам 0,1 с) ----
    public static int FpsPid;
    public static string[] MotionSummary(MouseRec rc, long[] lat) {
        List<string> res = new List<string>();
        if (rc == null || EndTick <= StartTick) return res.ToArray();
        System.Globalization.CultureInfo ru = new System.Globalization.CultureInfo("ru-RU");
        double k = TickMs, total = (EndTick - StartTick) * k;
        double rate = 0;
        if (lat != null && lat.Length > 10) {
            double[] d = new double[lat.Length - 1];
            for (int i = 1; i < lat.Length; i++) d[i - 1] = (lat[i] - lat[i - 1]) * k;
            Array.Sort(d);
            double med = d[d.Length / 2];
            if (med > 0) rate = 1000.0 / med;
        }
        double thr = rate > 0 ? rate * 1.5 : 3000;
        int nb = Math.Max(1, (int)Math.Ceiling(total / 100.0));
        double[] b = new double[nb];
        double longestGap = 0, prev = 0;
        for (int i = 0; i < rc.T.Count; i++) {
            double tm = (rc.T[i] - StartTick) * k;
            if (tm < 0 || tm >= total) continue;
            b[Math.Min(nb - 1, (int)(tm / 100))] += Math.Abs(rc.X[i]) + Math.Abs(rc.Y[i]);
            if (tm - prev > longestGap) longestGap = tm - prev;
            prev = tm;
        }
        if (total - prev > longestGap) longestGap = total - prev;
        int fast = 0, slow = 0, idle = 0, run = 0, longStops = 0;
        for (int i = 0; i < nb; i++) {
            if (b[i] == 0) { idle++; run++; continue; }
            if (run >= 5) longStops++;
            run = 0;
            if (b[i] * 10 < thr) slow++; else fast++;
        }
        if (run >= 5) longStops++;
        Func<int, string> sec = (c) => (c * 0.1).ToString("F1", ru) + " с (" + (c * 100.0 / nb).ToString("F0", ru) + "%)";
        res.Add("Движение · Быстрое: " + sec(fast));
        res.Add("Движение · Медленное: " + sec(slow));
        res.Add("Движение · Простой (мышь стояла): " + sec(idle));
        res.Add("Движение · Самая долгая остановка: " + longestGap.ToString("F0", ru) + " мс");
        res.Add("Движение · Остановок дольше 0,5 с: " + longStops);
        res.Add("Движение · Порог медленного: " + thr.ToString("F0", ru) + " отсчётов/с");
        return res.ToArray();
    }

    public static List<string[]> ThreadProcs = new List<string[]>();
    public static List<string[]> PreciseProcs = new List<string[]>();
    public static List<string[]> DriverStats = new List<string[]>();
    static double[] lastSec;
    static long lastSecTick;

    public static string InitCounters() {
        if (pdhQ != IntPtr.Zero) return null;
        try {
            IntPtr q;
            uint r = PdhOpenQuery(null, IntPtr.Zero, out q);
            if (r != 0) return "PdhOpenQuery 0x" + r.ToString("X");
            string[] names = { "% Processor Time", "% Interrupt Time", "% DPC Time", "Interrupts/sec", "DPCs Queued/sec" };
            pdhC = new IntPtr[names.Length];
            for (int i = 0; i < names.Length; i++) {
                r = PdhAddEnglishCounter(q, "\\Processor(*)\\" + names[i], IntPtr.Zero, out pdhC[i]);
                if (r != 0) return "PdhAddEnglishCounter " + names[i] + " 0x" + r.ToString("X");
            }
            PdhCollectQueryData(q);
            IntPtr qa, qs;
            if (PdhOpenQuery(null, IntPtr.Zero, out qa) == 0 && PdhAddEnglishCounter(qa, "\\Processor(*)\\% Processor Time", IntPtr.Zero, out cAvg) == 0) qAvg = qa;
            if (PdhOpenQuery(null, IntPtr.Zero, out qs) == 0 && PdhAddEnglishCounter(qs, "\\Processor(*)\\% Processor Time", IntPtr.Zero, out cSec) == 0) qSec = qs;
            pdhQ = q;
            return null;
        } catch (Exception ex) { return ex.Message; }
    }

    // значения по потокам: [0..NCpu-1] — потоки, [NCpu] — _Total
    static double[] ReadArray(IntPtr c) {
        uint size = 0, count;
        uint r = PdhGetFormattedCounterArray(c, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, IntPtr.Zero);
        if (r != PDH_MORE_DATA || size == 0) return null;
        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try {
            r = PdhGetFormattedCounterArray(c, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, ref size, out count, buf);
            if (r != 0) return null;
            double[] res = new double[NCpu + 1];
            for (int i = 0; i < res.Length; i++) res[i] = double.NaN;
            for (uint i = 0; i < count; i++) {
                IntPtr it = new IntPtr(buf.ToInt64() + i * 24);          // PDH_FMT_COUNTERVALUE_ITEM_W
                string name = Marshal.PtrToStringUni(Marshal.ReadIntPtr(it));
                uint st = (uint)Marshal.ReadInt32(it, 8);
                double v = BitConverter.Int64BitsToDouble(Marshal.ReadInt64(it, 16));
                int idx;
                if (name == "_Total") idx = NCpu;
                else if (!int.TryParse(name, out idx) || idx < 0 || idx >= NCpu) continue;
                res[idx] = (st == 0 || st == 1) ? v : double.NaN;
            }
            return res;
        } finally { Marshal.FreeHGlobal(buf); }
    }

    // строка: [ticks, load, intr, dpc, ints/s, dpcs/s (наблюдаемый поток), весь CPU, CPU0 ... CPUn]
    static void Sample() {
        PdhCollectQueryData(pdhQ);
        double[][] a = new double[5][];
        for (int k = 0; k < 5; k++) { a[k] = ReadArray(pdhC[k]); if (a[k] == null) return; }
        double[] r = new double[7 + NCpu];
        r[0] = sw.ElapsedTicks;
        for (int k = 0; k < 5; k++) r[1 + k] = a[k][Cpu];
        double[] ls = lastSec;
        r[6] = ls != null ? ls[NCpu] : double.NaN;
        for (int c = 0; c < NCpu; c++) r[7 + c] = ls != null ? ls[c] : double.NaN;
        lock (samples) samples.Add(r);
    }

    // ---- какие программы нагружают процессор ----
    public static List<string[]> TopProcs = new List<string[]>();
    static Dictionary<int, KeyValuePair<string, double>> procStart;
    static long procStartTick;
    static Dictionary<int, KeyValuePair<string, double>> SnapProcs() {
        Dictionary<int, KeyValuePair<string, double>> d = new Dictionary<int, KeyValuePair<string, double>>();
        foreach (Process p in Process.GetProcesses()) {
            try { if (p.Id != 0) d[p.Id] = new KeyValuePair<string, double>(p.ProcessName, p.TotalProcessorTime.TotalMilliseconds); }
            catch { }
            finally { p.Dispose(); }
        }
        return d;
    }
    static void EndProcs() {
        TopProcs.Clear();
        if (procStart == null) return;
        Dictionary<int, KeyValuePair<string, double>> end = SnapProcs();
        double wall = (sw.ElapsedTicks - procStartTick) * TickMs;
        if (wall <= 0) return;
        List<KeyValuePair<double, string[]>> list = new List<KeyValuePair<double, string[]>>();
        foreach (KeyValuePair<int, KeyValuePair<string, double>> e in end) {
            KeyValuePair<string, double> s0;
            if (!procStart.TryGetValue(e.Key, out s0)) continue;
            double d = e.Value.Value - s0.Value;
            if (d <= 0 || e.Value.Key == "Idle") continue;
            double core = d / wall * 100.0, tot = core / NCpu;
            list.Add(new KeyValuePair<double, string[]>(d, new string[] { e.Value.Key, e.Key.ToString(), tot.ToString("F1", System.Globalization.CultureInfo.InvariantCulture), core.ToString("F1", System.Globalization.CultureInfo.InvariantCulture) }));
        }
        list.Sort((x, y) => y.Key.CompareTo(x.Key));
        for (int i = 0; i < list.Count && i < 12; i++) TopProcs.Add(list[i].Value);
        procStart = null;
    }

    // ---- какое окно было активным ----
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static Dictionary<string, int> FgCounts = new Dictionary<string, int>();
    static Dictionary<uint, string> pidNames = new Dictionary<uint, string>();
    static void TrackForeground() {
        try {
            uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            string n;
            if (!pidNames.TryGetValue(pid, out n)) {
                try { using (Process p = Process.GetProcessById((int)pid)) n = p.ProcessName; } catch { n = "?"; }
                pidNames[pid] = n;
            }
            int c; FgCounts.TryGetValue(n, out c); FgCounts[n] = c + 1;
        } catch { }
    }

    static void StartSampler() {
        lock (samples) samples.Clear();
        TopProcs.Clear(); FgCounts.Clear(); pidNames.Clear(); procStart = null; snapReq = 0;
        AvgLoads = null; lastSec = null; ThreadProcs.Clear(); PreciseProcs.Clear(); DriverStats.Clear(); EtwCpu.Error = null;
        MaxLoads = new double[NCpu + 1];
        for (int i = 0; i <= NCpu; i++) MaxLoads[i] = double.NaN;
        SamplerError = InitCounters();
        if (SamplerError != null) return;
        sampling = true;
        sampler = new System.Threading.Thread(() => {
            int n = 0;
            try {
                PdhCollectQueryData(pdhQ);
                while (sampling) {
                    System.Threading.Thread.Sleep(SampleMs);
                    Sample();
                    if (snapReq == 1) {
                        snapReq = 0;
                        if (qAvg != IntPtr.Zero) PdhCollectQueryData(qAvg);
                        if (qSec != IntPtr.Zero) PdhCollectQueryData(qSec);
                        lastSecTick = sw.ElapsedTicks;
                        procStartTick = sw.ElapsedTicks; procStart = SnapProcs();
                        if (UseEtw) { try { EtwCpu.Start(); } catch (Exception ex) { EtwCpu.Error = ex.Message; } }
                        if (UseEtw && FpsPid > 0) { try { EtwFps.Start(FpsPid); } catch (Exception ex) { EtwFps.Error = ex.Message; } }
                    }
                    if (Active && qSec != IntPtr.Zero && (sw.ElapsedTicks - lastSecTick) * TickMs >= 1000) {
                        lastSecTick = sw.ElapsedTicks;
                        PdhCollectQueryData(qSec);
                        double[] v = ReadArray(cSec);
                        if (v != null) {
                            lastSec = v;
                            for (int c = 0; c <= NCpu; c++) if (!double.IsNaN(v[c]) && (double.IsNaN(MaxLoads[c]) || v[c] > MaxLoads[c])) MaxLoads[c] = v[c];
                        }
                    }
                    if (Active && (++n % 10) == 0) TrackForeground();
                }
            } catch (Exception ex) {
                SamplerError = ex.Message;
            }
        });
        sampler.IsBackground = true;
        sampler.Priority = System.Threading.ThreadPriority.AboveNormal;
        sampler.Start();
    }

    static void StopSampler() {
        sampling = false;
        if (sampler != null) sampler.Join(3000);
        try {
            if (qAvg != IntPtr.Zero && procStart != null) { PdhCollectQueryData(qAvg); AvgLoads = ReadArray(cAvg); }
        } catch { }
        try { if (EtwFps.Running) EtwFps.Stop(); } catch { }
        try {
            if (EtwCpu.Running) {
                EtwCpu.Stop();
                ThreadProcs = EtwCpu.ThreadSummary(6);
                PreciseProcs = EtwCpu.ProcessSummary(15);
                DriverStats = EtwCpu.Drivers(20);
            }
        } catch (Exception ex) { EtwCpu.Error = ex.Message; }
        try { EndProcs(); } catch { }
    }

    public static double[][] GetSamples() { lock (samples) return samples.ToArray(); }

    // ---- режим «во время игры»: низкоуровневый перехватчик мыши ----
    // Windows 11 урезает Raw Input фоновых программ до ~125 Гц, а перехватчик видит каждое событие.
    delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, LowLevelMouseProc fn, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    static LowLevelMouseProc hookProc;
    static IntPtr hook = IntPtr.Zero;
    public static long[] HookTicks = new long[0];
    public static int HookCount, HookInjected;
    public static string HookError;

    static IntPtr HookCb(int n, IntPtr w, IntPtr l) {
        if (n >= 0 && measuring && w.ToInt64() == 0x0200) {
            long t = sw.ElapsedTicks;
            int flags = Marshal.ReadInt32(l, 12);                      // MSLLHOOKSTRUCT.flags
            if ((flags & 3) == 0) { if (HookCount < HookTicks.Length) HookTicks[HookCount++] = t; }
            else HookInjected++;                                       // программные (не от мыши) события
        }
        return CallNextHookEx(hook, n, w, l);
    }

    public static void RunGame(int seconds) {
        Data.Clear(); BgEvents = 0; Cancelled = false; measuring = false; Active = false;
        StartTick = 0; EndTick = 0; HookError = null;
        HookTicks = new long[Math.Max(100000, seconds * 9000)]; HookCount = 0; HookInjected = 0;
        RawMouse f = new RawMouse();
        IntPtr unused = f.Handle;                                      // скрытое окно: только чтобы узнать, какая мышь
        hookProc = HookCb;
        hook = SetWindowsHookEx(14, hookProc, GetModuleHandle(null), 0);   // WH_MOUSE_LL
        if (hook == IntPtr.Zero) { HookError = "SetWindowsHookEx: ошибка " + Marshal.GetLastWin32Error(); f.Dispose(); return; }
        System.Threading.ThreadPriority prio = System.Threading.Thread.CurrentThread.Priority;
        System.Threading.Thread.CurrentThread.Priority = System.Threading.ThreadPriority.Highest;
        StartSampler();
        Timer t = new Timer();
        t.Interval = seconds * 1000;
        t.Tick += (s, e) => { measuring = false; Active = false; EndTick = sw.ElapsedTicks; t.Stop(); Application.ExitThread(); };
        StartTick = sw.ElapsedTicks; measuring = true; Active = true; snapReq = 1;
        t.Start();
        Application.Run();
        UnhookWindowsHookEx(hook); hook = IntPtr.Zero;
        System.Threading.Thread.CurrentThread.Priority = prio;
        StopSampler();
        t.Dispose(); f.Dispose();
    }

    public static void Run(int seconds) {
        Data.Clear(); BgEvents = 0; Cancelled = false; measuring = false;
        StartTick = 0; EndTick = 0;
        RawMouse f = new RawMouse();
        int count = 3;
        string prep = "Кликните по этому окну и приготовьтесь\n\n";
        f.lbl.Text = prep + count;
        Timer t = new Timer();
        t.Interval = 1000;
        t.Tick += (s, e) => {
            // ВАЖНО: во время замера окно не перерисовывается.
            // Перерисовка полноэкранной надписи занимает ~7 мс и задерживает
            // обработку событий мыши — это давало ложные паузы раз в секунду.
            count--;
            if (count > 1) {
                f.lbl.Text = prep + count;
            } else if (count == 1) {
                f.lbl.ForeColor = Color.LimeGreen;
                f.lbl.Text = "НАЧИНАЙТЕ ВОДИТЬ МЫШЬЮ БЫСТРЫМИ КРУГАМИ!\n\n" +
                             "Не останавливайтесь " + (seconds + 1) + " с.\nОкно закроется само.";
            } else if (count == 0) {
                Data.Clear(); BgEvents = 0;
                StartTick = sw.ElapsedTicks;
                measuring = true; Active = true; snapReq = 1;
            } else if (count > -seconds) {
                // идёт замер — ничего не трогаем
            } else {
                measuring = false; Active = false;
                EndTick = sw.ElapsedTicks;
                t.Stop();
                f.Close();
            }
        };
        f.Shown += (s, e) => { StartSampler(); f.Activate(); t.Start(); };
        Application.Run(f);
        StopSampler();
        t.Dispose();
    }
}
// Точный разбор процессора (нужны права администратора), как в LatencyMon / Windows Performance Analyzer:
// трассировка ядра ETW — переключения потоков (какая программа на каком ядре) и DPC/ISR драйверов.
public static class EtwCpu {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern uint StartTraceW(out ulong handle, string name, IntPtr props);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern uint ControlTraceW(ulong handle, string name, IntPtr props, uint code);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern ulong OpenTraceW(IntPtr logfile);
    [DllImport("advapi32.dll")] static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);
    [DllImport("advapi32.dll")] static extern uint CloseTrace(ulong handle);
    [DllImport("psapi.dll", SetLastError = true)] static extern bool EnumDeviceDrivers([Out] IntPtr[] bases, uint cb, out uint needed);
    [DllImport("psapi.dll", CharSet = CharSet.Unicode)] static extern uint GetDeviceDriverBaseNameW(IntPtr imageBase, System.Text.StringBuilder name, uint size);
    delegate void EventRecordCb(IntPtr rec);

    const string SessionName = "MouseLatencyCpuTrace";
    const uint ThreadProv = 0x3d6fa8d1, PerfInfoProv = 0xce1dbfb4;
    static EventRecordCb cb;
    static IntPtr props = IntPtr.Zero, logfile = IntPtr.Zero, namePtr = IntPtr.Zero;
    static ulong sess, trace;
    static System.Threading.Thread th;
    static long[] lastTs; static uint[] lastTid;
    static Dictionary<uint, long>[] use; static long[] span, dpcCpu, isrCpu;
    static Dictionary<ulong, long[]> dpc, isr;                // routine -> [count, total, max]
    static Dictionary<uint, string> startMap;
    static long freq = Stopwatch.Frequency;
    public static string Error;
    public static bool Running;
    public static long Events;

    static IntPtr MakeProps() {
        int size = 120 + 2048;
        IntPtr p = Marshal.AllocHGlobal(size);
        Marshal.Copy(new byte[size], 0, p, size);
        Marshal.WriteInt32(p, 0, size);                                   // Wnode.BufferSize
        Marshal.Copy(Guid.NewGuid().ToByteArray(), 0, new IntPtr(p.ToInt64() + 24), 16);
        Marshal.WriteInt32(p, 40, 1);                                     // ClientContext: QPC
        Marshal.WriteInt32(p, 44, 0x00020000);                            // WNODE_FLAG_TRACED_GUID
        Marshal.WriteInt32(p, 48, 64);                                    // BufferSize, КБ
        Marshal.WriteInt32(p, 52, 64);                                    // MinimumBuffers
        Marshal.WriteInt32(p, 56, 1024);                                  // MaximumBuffers
        Marshal.WriteInt32(p, 64, 0x00000100 | 0x02000000);               // REAL_TIME | SYSTEM_LOGGER_MODE
        Marshal.WriteInt32(p, 68, 1);                                     // FlushTimer, с
        Marshal.WriteInt32(p, 72, 0x00000010 | 0x00000020 | 0x00000040);  // CSWITCH | DPC | INTERRUPT
        Marshal.WriteInt32(p, 116, 120);                                  // LoggerNameOffset
        return p;
    }

    public static Dictionary<uint, string> ThreadMap() {
        Dictionary<uint, string> m = new Dictionary<uint, string>();
        foreach (Process p in Process.GetProcesses()) {
            try {
                string nm = p.Id == 4 ? "System" : p.ProcessName;
                foreach (ProcessThread t in p.Threads) m[(uint)t.Id] = nm;
            } catch { }
            finally { p.Dispose(); }
        }
        return m;
    }

    public static bool Start() {
        Error = null; Running = false; Events = 0;
        if (IntPtr.Size != 8) { Error = "нужна 64-битная PowerShell"; return false; }
        int n = Environment.ProcessorCount;
        lastTs = new long[n]; lastTid = new uint[n]; use = new Dictionary<uint, long>[n];
        span = new long[n]; dpcCpu = new long[n]; isrCpu = new long[n];
        dpc = new Dictionary<ulong, long[]>(); isr = new Dictionary<ulong, long[]>();
        for (int i = 0; i < n; i++) { use[i] = new Dictionary<uint, long>(); lastTs[i] = -1; }
        try { startMap = ThreadMap(); } catch { startMap = new Dictionary<uint, string>(); }
        props = MakeProps();
        uint r = StartTraceW(out sess, SessionName, props);
        if (r == 183) {
            ControlTraceW(0, SessionName, props, 1);
            Marshal.FreeHGlobal(props); props = MakeProps();
            r = StartTraceW(out sess, SessionName, props);
        }
        if (r != 0) {
            Error = r == 5 ? "нужны права администратора" : "StartTrace: ошибка " + r;
            Marshal.FreeHGlobal(props); props = IntPtr.Zero; return false;
        }
        cb = OnEvent;
        logfile = Marshal.AllocHGlobal(448);
        Marshal.Copy(new byte[448], 0, logfile, 448);
        namePtr = Marshal.StringToHGlobalUni(SessionName);
        Marshal.WriteIntPtr(logfile, 8, namePtr);
        Marshal.WriteInt32(logfile, 28, 0x00000100 | 0x00001000 | 0x10000000);   // REAL_TIME | RAW_TIMESTAMP | EVENT_RECORD
        Marshal.WriteIntPtr(logfile, 424, Marshal.GetFunctionPointerForDelegate(cb));
        trace = OpenTraceW(logfile);
        if (trace == ulong.MaxValue) { Error = "OpenTrace: ошибка " + Marshal.GetLastWin32Error(); Stop(); return false; }
        ulong tr = trace;
        th = new System.Threading.Thread(() => { try { ProcessTrace(new ulong[] { tr }, 1, IntPtr.Zero, IntPtr.Zero); } catch { } });
        th.IsBackground = true;
        th.Priority = System.Threading.ThreadPriority.AboveNormal;
        th.Start();
        Running = true;
        return true;
    }

    static void OnEvent(IntPtr rec) {
        try {
            uint prov = (uint)Marshal.ReadInt32(rec, 24);
            byte op = Marshal.ReadByte(rec, 45);
            int flags = Marshal.ReadInt16(rec, 4);
            int cpu = (flags & 0x0200) != 0 ? (ushort)Marshal.ReadInt16(rec, 80) : Marshal.ReadByte(rec, 80);
            if (cpu < 0 || cpu >= lastTs.Length) return;
            long ts = Marshal.ReadInt64(rec, 16);
            IntPtr ud = Marshal.ReadIntPtr(rec, 96);
            if (ud == IntPtr.Zero) return;
            if (prov == ThreadProv && op == 36) {                          // CSwitch
                uint newTid = (uint)Marshal.ReadInt32(ud, 0);
                if (lastTs[cpu] >= 0) {
                    long d = ts - lastTs[cpu];
                    if (d > 0) {
                        long v; use[cpu].TryGetValue(lastTid[cpu], out v);
                        use[cpu][lastTid[cpu]] = v + d;
                        span[cpu] += d;
                    }
                }
                lastTs[cpu] = ts; lastTid[cpu] = newTid;
                Events++;
            } else if (prov == PerfInfoProv && op >= 66 && op <= 69) {     // 66 ThreadedDPC, 67 ISR, 68 DPC, 69 TimerDPC
                long init = Marshal.ReadInt64(ud, 0);
                ulong routine = (ulong)Marshal.ReadInt64(ud, 8);
                long d = ts - init;
                if (d < 0 || d > freq) return;
                Dictionary<ulong, long[]> dict = op == 67 ? isr : dpc;
                long[] s;
                if (!dict.TryGetValue(routine, out s)) { s = new long[3]; dict[routine] = s; }
                s[0]++; s[1] += d; if (d > s[2]) s[2] = d;
                if (op == 67) isrCpu[cpu] += d; else dpcCpu[cpu] += d;
                Events++;
            }
        } catch { }
    }

    public static void Stop() {
        if (props != IntPtr.Zero) { try { ControlTraceW(sess, null, props, 1); } catch { } }
        if (th != null) { th.Join(8000); th = null; }
        if (trace != 0 && trace != ulong.MaxValue) { try { CloseTrace(trace); } catch { } }
        trace = 0;
        if (props != IntPtr.Zero) { Marshal.FreeHGlobal(props); props = IntPtr.Zero; }
        if (logfile != IntPtr.Zero) { Marshal.FreeHGlobal(logfile); logfile = IntPtr.Zero; }
        if (namePtr != IntPtr.Zero) { Marshal.FreeHGlobal(namePtr); namePtr = IntPtr.Zero; }
        Running = false;
    }

    static string F(double v) { return v.ToString("F2", System.Globalization.CultureInfo.InvariantCulture); }

    static Dictionary<uint, string> FullMap() {
        Dictionary<uint, string> map = new Dictionary<uint, string>(startMap ?? new Dictionary<uint, string>());
        try { foreach (KeyValuePair<uint, string> kv in ThreadMap()) map[kv.Key] = kv.Value; } catch { }
        return map;
    }

    // [cpu, занят %, DPC %, ISR %, "имя|%;имя|%"] — доля времени потока
    public static List<string[]> ThreadSummary(int top) {
        List<string[]> res = new List<string[]>();
        if (use == null) return res;
        Dictionary<uint, string> map = FullMap();
        for (int c = 0; c < use.Length; c++) {
            if (span[c] <= 0) continue;
            Dictionary<string, long> byName = new Dictionary<string, long>();
            long idle = 0;
            foreach (KeyValuePair<uint, long> kv in use[c]) {
                if (kv.Key == 0) { idle += kv.Value; continue; }
                string nm; if (!map.TryGetValue(kv.Key, out nm)) nm = "(завершившийся поток)";
                long v; byName.TryGetValue(nm, out v); byName[nm] = v + kv.Value;
            }
            List<KeyValuePair<string, long>> l = new List<KeyValuePair<string, long>>(byName);
            l.Sort((a, b) => b.Value.CompareTo(a.Value));
            List<string> parts = new List<string>();
            for (int i = 0; i < l.Count && i < top; i++) {
                double pct = l[i].Value * 100.0 / span[c];
                if (pct < 0.05) break;
                parts.Add(l[i].Key.Replace("|", "/").Replace(";", ",") + "|" + F(pct));
            }
            res.Add(new string[] { c.ToString(), F((span[c] - idle) * 100.0 / span[c]),
                F(dpcCpu[c] * 100.0 / span[c]), F(isrCpu[c] * 100.0 / span[c]), string.Join(";", parts.ToArray()) });
        }
        return res;
    }

    // [имя, % всего процессора, % одного потока] — точное время по переключениям потоков
    public static List<string[]> ProcessSummary(int top) {
        List<string[]> res = new List<string[]>();
        if (use == null) return res;
        Dictionary<uint, string> map = FullMap();
        Dictionary<string, long> byName = new Dictionary<string, long>();
        long total = 0, maxSpan = 0;
        for (int c = 0; c < use.Length; c++) {
            total += span[c]; if (span[c] > maxSpan) maxSpan = span[c];
            foreach (KeyValuePair<uint, long> kv in use[c]) {
                if (kv.Key == 0) continue;
                string nm; if (!map.TryGetValue(kv.Key, out nm)) nm = "(завершившийся поток)";
                long v; byName.TryGetValue(nm, out v); byName[nm] = v + kv.Value;
            }
        }
        if (total <= 0) return res;
        List<KeyValuePair<string, long>> l = new List<KeyValuePair<string, long>>(byName);
        l.Sort((a, b) => b.Value.CompareTo(a.Value));
        for (int i = 0; i < l.Count && i < top; i++)
            res.Add(new string[] { l[i].Key, F(l[i].Value * 100.0 / total), F(l[i].Value * 100.0 / Math.Max(1, maxSpan)) });
        return res;
    }

    // [драйвер, DPC шт, DPC мс всего, DPC макс мкс, ISR шт, ISR мс всего, ISR макс мкс]
    public static List<string[]> Drivers(int top) {
        List<string[]> res = new List<string[]>();
        if (dpc == null) return res;
        List<KeyValuePair<ulong, string>> mods = new List<KeyValuePair<ulong, string>>();
        try {
            IntPtr[] bases = new IntPtr[2048]; uint needed;
            if (EnumDeviceDrivers(bases, (uint)(bases.Length * IntPtr.Size), out needed)) {
                int cnt = Math.Min(bases.Length, (int)(needed / IntPtr.Size));
                for (int i = 0; i < cnt; i++) {
                    if (bases[i] == IntPtr.Zero) continue;
                    System.Text.StringBuilder sb = new System.Text.StringBuilder(260);
                    if (GetDeviceDriverBaseNameW(bases[i], sb, 260) > 0) mods.Add(new KeyValuePair<ulong, string>((ulong)bases[i].ToInt64(), sb.ToString()));
                }
            }
        } catch { }
        mods.Sort((a, b) => a.Key.CompareTo(b.Key));
        Func<ulong, string> modOf = (addr) => {
            string best = "(неизвестно)";
            foreach (KeyValuePair<ulong, string> m in mods) { if (m.Key <= addr) best = m.Value; else break; }
            return best;
        };
        Dictionary<string, long[]> agg = new Dictionary<string, long[]>();   // dpcN, dpcT, dpcMax, isrN, isrT, isrMax
        foreach (KeyValuePair<ulong, long[]> kv in dpc) {
            string m = modOf(kv.Key); long[] a; if (!agg.TryGetValue(m, out a)) { a = new long[6]; agg[m] = a; }
            a[0] += kv.Value[0]; a[1] += kv.Value[1]; if (kv.Value[2] > a[2]) a[2] = kv.Value[2];
        }
        foreach (KeyValuePair<ulong, long[]> kv in isr) {
            string m = modOf(kv.Key); long[] a; if (!agg.TryGetValue(m, out a)) { a = new long[6]; agg[m] = a; }
            a[3] += kv.Value[0]; a[4] += kv.Value[1]; if (kv.Value[2] > a[5]) a[5] = kv.Value[2];
        }
        List<KeyValuePair<string, long[]>> l = new List<KeyValuePair<string, long[]>>(agg);
        l.Sort((x, y) => (y.Value[1] + y.Value[4]).CompareTo(x.Value[1] + x.Value[4]));
        for (int i = 0; i < l.Count && i < top; i++) {
            long[] a = l[i].Value;
            res.Add(new string[] { l[i].Key, a[0].ToString(), F(a[1] * 1000.0 / freq), F(a[2] * 1e6 / freq),
                a[3].ToString(), F(a[4] * 1000.0 / freq), F(a[5] * 1e6 / freq) });
        }
        return res;
    }
}
// Кадры CS2 без вмешательства в игру: событие Present провайдера Microsoft-Windows-DXGI (как PresentMon / CapFrameX).
// Нужны права администратора. Работает для DirectX 11/12; при запуске игры через Vulkan событий не будет.
public static class EtwFps {
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern uint StartTraceW(out ulong handle, string name, IntPtr props);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern uint ControlTraceW(ulong handle, string name, IntPtr props, uint code);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)] static extern ulong OpenTraceW(IntPtr logfile);
    [DllImport("advapi32.dll")] static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);
    [DllImport("advapi32.dll")] static extern uint CloseTrace(ulong handle);
    [DllImport("advapi32.dll")] static extern uint EnableTraceEx2(ulong handle, ref Guid provider, uint control, byte level, ulong anyKw, ulong allKw, uint timeout, IntPtr prms);
    delegate void EventRecordCb(IntPtr rec);

    const string SessionName = "MouseLatencyFpsTrace";
    static Guid Dxgi = new Guid("CA11C036-0102-4A2D-A6AD-F03CFED5D3C9");
    static EventRecordCb cb;
    static IntPtr props = IntPtr.Zero, logfile = IntPtr.Zero, namePtr = IntPtr.Zero;
    static ulong sess, trace;
    static System.Threading.Thread th;
    static int pid;
    public static List<long> Presents = new List<long>(100000);
    public static string Error;
    public static bool Running;

    static IntPtr MakeProps() {
        int size = 120 + 2048;
        IntPtr p = Marshal.AllocHGlobal(size);
        Marshal.Copy(new byte[size], 0, p, size);
        Marshal.WriteInt32(p, 0, size);
        Marshal.Copy(Guid.NewGuid().ToByteArray(), 0, new IntPtr(p.ToInt64() + 24), 16);
        Marshal.WriteInt32(p, 40, 1);                                     // QPC
        Marshal.WriteInt32(p, 44, 0x00020000);
        Marshal.WriteInt32(p, 48, 64);
        Marshal.WriteInt32(p, 52, 16);
        Marshal.WriteInt32(p, 56, 256);
        Marshal.WriteInt32(p, 64, 0x00000100);                            // REAL_TIME
        Marshal.WriteInt32(p, 68, 1);
        Marshal.WriteInt32(p, 116, 120);
        return p;
    }

    public static bool Start(int processId) {
        Error = null; Running = false; Presents.Clear(); pid = processId;
        if (IntPtr.Size != 8) { Error = "нужна 64-битная PowerShell"; return false; }
        props = MakeProps();
        uint r = StartTraceW(out sess, SessionName, props);
        if (r == 183) { ControlTraceW(0, SessionName, props, 1); Marshal.FreeHGlobal(props); props = MakeProps(); r = StartTraceW(out sess, SessionName, props); }
        if (r != 0) { Error = r == 5 ? "нужны права администратора" : "StartTrace: ошибка " + r; Marshal.FreeHGlobal(props); props = IntPtr.Zero; return false; }
        r = EnableTraceEx2(sess, ref Dxgi, 1, 4, ulong.MaxValue, 0, 0, IntPtr.Zero);
        if (r != 0) { Error = "EnableTrace DXGI: ошибка " + r; Stop(); return false; }
        cb = OnEvent;
        logfile = Marshal.AllocHGlobal(448);
        Marshal.Copy(new byte[448], 0, logfile, 448);
        namePtr = Marshal.StringToHGlobalUni(SessionName);
        Marshal.WriteIntPtr(logfile, 8, namePtr);
        Marshal.WriteInt32(logfile, 28, 0x00000100 | 0x00001000 | 0x10000000);
        Marshal.WriteIntPtr(logfile, 424, Marshal.GetFunctionPointerForDelegate(cb));
        trace = OpenTraceW(logfile);
        if (trace == ulong.MaxValue) { Error = "OpenTrace: ошибка"; Stop(); return false; }
        ulong tr = trace;
        th = new System.Threading.Thread(() => { try { ProcessTrace(new ulong[] { tr }, 1, IntPtr.Zero, IntPtr.Zero); } catch { } });
        th.IsBackground = true;
        th.Start();
        Running = true;
        return true;
    }

    static void OnEvent(IntPtr rec) {
        try {
            if ((uint)Marshal.ReadInt32(rec, 24) != 0xCA11C036) return;   // DXGI
            if ((ushort)Marshal.ReadInt16(rec, 40) != 42) return;          // Present_Start
            if (Marshal.ReadInt32(rec, 12) != pid) return;                 // только CS2
            Presents.Add(Marshal.ReadInt64(rec, 16));
        } catch { }
    }

    public static void Stop() {
        if (props != IntPtr.Zero) { try { ControlTraceW(sess, null, props, 1); } catch { } }
        if (th != null) { th.Join(8000); th = null; }
        if (trace != 0 && trace != ulong.MaxValue) { try { CloseTrace(trace); } catch { } }
        trace = 0;
        if (props != IntPtr.Zero) { Marshal.FreeHGlobal(props); props = IntPtr.Zero; }
        if (logfile != IntPtr.Zero) { Marshal.FreeHGlobal(logfile); logfile = IntPtr.Zero; }
        if (namePtr != IntPtr.Zero) { Marshal.FreeHGlobal(namePtr); namePtr = IntPtr.Zero; }
        Running = false;
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
} catch {
    Write-Host "Ошибка компиляции: $_" -ForegroundColor Red
    return
}

$Inv = [Globalization.CultureInfo]::InvariantCulture
function F($v, [int]$d = 3) { if ($null -eq $v -or [double]::IsNaN([double]$v)) { '' } else { ([double]$v).ToString("F$d", $Inv) } }
function JN($v, [int]$d = 3) { if ($null -eq $v -or [double]::IsNaN([double]$v) -or [double]::IsInfinity([double]$v)) { 'null' } else { ([double]$v).ToString("F$d", $Inv) } }
function JS([string]$s) { '"' + (($s -replace '\\', '\\' -replace '"', '\"') -replace "[\r\n\t]", ' ') + '"' }
function Ask-Number([string]$prompt, [int]$def, [int]$min, [int]$max) {
    $a = Read-Host "$prompt (Enter = $def)"
    if ($a -match '^\s*\d+\s*$') { return [Math]::Max($min, [Math]::Min($max, [int]$a)) }
    return $def
}

$MouseInfoCache = @{}
function Get-Prop([string]$id, [string]$key) {
    try {
        $v = (Get-PnpDeviceProperty -InstanceId $id -KeyName $key -ErrorAction Stop).Data
        if ($v -is [array]) { return ($v -join '; ') }
        return $v
    } catch { return $null }
}
function Get-Ctrl([string]$id, [ref]$usbDev) {
    $cur = $id
    for ($i = 0; $i -lt 10 -and $cur; $i++) {
        $par = Get-Prop $cur 'DEVPKEY_Device_Parent'
        if (-not $par) { return $null }
        if ($par -like 'PCI\*') { return $par }
        if ($usbDev -and -not $usbDev.Value -and $par -like 'USB\VID_*' -and $par -notlike '*&MI_*') { $usbDev.Value = $par }
        $cur = $par
    }
    return $null
}
function Get-MouseInfo([IntPtr]$handle, [string]$path) {
    if ($MouseInfoCache.ContainsKey($path)) { return $MouseInfoCache[$path] }
    Write-Host "Собираю сведения о мыши и USB-контроллере..." -ForegroundColor DarkGray
    $L = New-Object System.Collections.Generic.List[string]
    function A([string]$k, $v) { if ($null -ne $v -and "$v".Trim() -ne '') { $L.Add("${k}: $v") } }

    $h = [RawMouse]::HidInfo($handle, $path)
    $hidId = (($path -replace '^\\\\\?\\', '') -replace '#\{[^}]+\}$', '') -replace '#', '\'
    $usbDev = $null
    $ctrl = Get-Ctrl $hidId ([ref]$usbDev)
    $busName = if ($usbDev) { Get-Prop $usbDev 'DEVPKEY_Device_BusReportedDeviceDesc' } else { $null }

    $name = if ($h[0]) { $h[0] } elseif ($busName) { $busName } else { Get-Prop $hidId 'DEVPKEY_Device_FriendlyName' }
    A 'Мышь · Название' $name
    A 'Мышь · Производитель' $(if ($h[1]) { $h[1] } elseif ($usbDev) { Get-Prop $usbDev 'DEVPKEY_Device_Manufacturer' })
    if ($busName -and $busName -ne $name) { A 'Мышь · Имя USB-устройства' $busName }
    if ($path -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { A 'Мышь · VID / PID' ("{0} / {1}" -f $Matches[1].ToUpper(), $Matches[2].ToUpper()) }
    if ($path -match '&(MI_[0-9A-Fa-f]{2})') { A 'Мышь · Интерфейс' $Matches[1].ToUpper() }
    A 'Мышь · Версия прошивки' $h[2]
    A 'Мышь · Кнопок' $h[3]
    A 'Мышь · Горизонтальное колесо' $h[4]
    if ($h[5] -and $h[5] -ne '0') { A 'Мышь · Частота по данным драйвера' "$($h[5]) Гц" }
    $svc = Get-Prop $hidId 'DEVPKEY_Device_Service'
    $ver = Get-Prop $hidId 'DEVPKEY_Device_DriverVersion'
    A 'Мышь · Драйвер' $(if ($svc) { ("{0} {1}" -f $svc, $ver).Trim() })
    A 'Мышь · Устройство в Windows' (Get-Prop $hidId 'DEVPKEY_Device_DeviceDesc')

    if ($usbDev) {
        A 'USB · Порт' (Get-Prop $usbDev 'DEVPKEY_Device_LocationInfo')
    }
    if ($ctrl) {
        $cn = Get-Prop $ctrl 'DEVPKEY_Device_FriendlyName'; if (-not $cn) { $cn = Get-Prop $ctrl 'DEVPKEY_Device_DeviceDesc' }
        A 'USB · Контроллер' $cn
        A 'USB · Расположение контроллера' (Get-Prop $ctrl 'DEVPKEY_Device_LocationInfo')
        if ($ctrl -match '^(PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4})') { A 'USB · ID контроллера' $Matches[1] }

        # другие устройства на этом контроллере
        $others = New-Object System.Collections.Generic.List[string]
        try {
            $devs = Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -like 'USB\VID_*' -and $_.InstanceId -notlike '*&MI_*' -and $_.InstanceId -ne $usbDev }
            foreach ($d in $devs) {
                $c = Get-Ctrl $d.InstanceId ([ref]$null)
                if ($c -eq $ctrl) {
                    $nm = Get-Prop $d.InstanceId 'DEVPKEY_Device_BusReportedDeviceDesc'
                    if (-not $nm) { $nm = $d.FriendlyName }
                    if ($nm) { $others.Add($nm) }
                }
            }
        } catch {}
        A 'USB · Других устройств на контроллере' $others.Count
        if ($others.Count) { A 'USB · Другие устройства' ($others -join '; ') }

        # настройки прерываний контроллера (то, что меняет GoInterruptPolicy)
        $base = "HKLM:\SYSTEM\CurrentControlSet\Enum\$ctrl\Device Parameters\Interrupt Management"
        try {
            $msi = Get-ItemProperty -LiteralPath "$base\MessageSignaledInterruptProperties" -ErrorAction Stop
            $lim = if ($msi.MessageNumberLimit) { ", лимит $($msi.MessageNumberLimit)" } else { "" }
            A 'Прерывания · MSI' ($(if ($msi.MSISupported -eq 1) { "включено" } else { "выключено" }) + $lim)
        } catch { A 'Прерывания · MSI' 'не настроено' }
        try {
            $ap = Get-ItemProperty -LiteralPath "$base\Affinity Policy" -ErrorAction Stop
            $pol = @{ 0 = 'IrqPolicyMachineDefault'; 1 = 'IrqPolicyAllCloseProcessors'; 2 = 'IrqPolicyOneCloseProcessor'; 3 = 'IrqPolicyAllProcessorsInMachine'; 4 = 'IrqPolicySpecifiedProcessors'; 5 = 'IrqPolicySpreadMessagesAcrossAllProcessors' }
            $pri = @{ 0 = 'Undefined'; 1 = 'Low'; 2 = 'Normal'; 3 = 'High' }
            A 'Прерывания · Политика' $(if ($null -ne $ap.DevicePolicy) { $pol[[int]$ap.DevicePolicy] } else { 'IrqPolicyMachineDefault' })
            if ($ap.AssignmentSetOverride) {
                $raw = $ap.AssignmentSetOverride
                $bytes = if ($raw -is [byte[]]) { $raw } else { [BitConverter]::GetBytes([int64]$raw) }
                $cpus = @()
                for ($b = 0; $b -lt $bytes.Length; $b++) { for ($j = 0; $j -lt 8; $j++) { if ($bytes[$b] -band (1 -shl $j)) { $cpus += ($b * 8 + $j) } } }
                if ($cpus.Count) { A 'Прерывания · Потоки' ("CPU " + ($cpus -join ', CPU ')) }
            }
            if ($null -ne $ap.DevicePriority) { A 'Прерывания · Приоритет' $pri[[int]$ap.DevicePriority] }
        } catch { A 'Прерывания · Политика' 'по умолчанию (не настроено)' }
    }

    # настройки мыши в Windows
    try {
        $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
        A 'Windows · Скорость указателя' "$($m.MouseSensitivity) из 20"
        A 'Windows · Повышенная точность указателя' $(if ($m.MouseSpeed -eq '0') { 'выключена' } else { 'ВКЛЮЧЕНА' })
        A 'Windows · Кнопки поменяны местами' $(if ($m.SwapMouseButtons -eq '1') { 'да' } else { 'нет' })
        A 'Windows · Двойной щелчок' "$($m.DoubleClickSpeed) мс"
    } catch {}
    try { A 'Windows · Прокрутка колесом' "$((Get-ItemProperty 'HKCU:\Control Panel\Desktop').WheelScrollLines) строк" } catch {}
    try {
        $q = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' -ErrorAction Stop).MouseDataQueueSize
        A 'Windows · Буфер mouclass (MouseDataQueueSize)' $(if ($q) { $q } else { 'по умолчанию (100)' })
    } catch { A 'Windows · Буфер mouclass (MouseDataQueueSize)' 'по умолчанию (100)' }

    $MouseInfoCache[$path] = $L
    return $L
}
$Desktop = [Environment]::GetFolderPath('Desktop')
if (-not $Desktop -or -not (Test-Path $Desktop)) { $Desktop = Join-Path $env:USERPROFILE 'Desktop' }
$Seconds = 20
$GameSeconds = 60
$Mode = 1

# Сведения о системе (для анализа)
$sys = New-Object System.Collections.Generic.List[string]
try { $os = Get-CimInstance Win32_OperatingSystem; $sys.Add("ОС: $($os.Caption) $($os.Version)") } catch {}
try { $sys.Add("CPU: " + ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()) } catch {}
try { $sys.Add("GPU: " + ((Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join '; ')) } catch {}
try { $sys.Add("Схема питания: " + ((powercfg /getactivescheme) -join ' ').Trim()) } catch {}
try {
    $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse'
    $acc = if ($m.MouseSpeed -eq '0') { 'выкл' } else { 'ВКЛ' }
    $sys.Add("Ускорение указателя (Enhance pointer precision): $acc; скорость: $($m.MouseSensitivity)/20")
} catch {}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$AdminMode = $false
if ($AdminMode -and -not $isAdmin) {
    Write-Host "Нет прав администратора — точный разбор процессора будет недоступен." -ForegroundColor Yellow
    Write-Host "Запустите этот батник через ПКМ -> «Запуск от имени администратора»."
}
[RawMouse]::UseEtw = ($AdminMode -and $isAdmin)

$nCpu = [Environment]::ProcessorCount
Write-Host ("=== ТЕСТ МЫШИ{0} ===" -f $(if ([RawMouse]::UseEtw) { " (с правами администратора: точный разбор процессора)" } else { "" })) -ForegroundColor Cyan
Write-Host "Потоков CPU: $nCpu (CPU 0 ... CPU $($nCpu - 1))."
$Cpu = Ask-Number "Поток CPU, к которому привязана мышь" 10 0 ($nCpu - 1)
[RawMouse]::Cpu = $Cpu
$initErr = [RawMouse]::InitCounters()
if ($initErr) { Write-Host "Счётчики процессора недоступны: $initErr" -ForegroundColor Yellow }

while ($true) {
    Write-Host ""
    Write-Host "Режим: 1 — обычный (окно теста, самые точные данные), 2 — во время игры (замер в фоне)"
    $Mode = Ask-Number "Режим" $Mode 1 2

    if ($Mode -eq 2) {
        Write-Host ""
        Write-Host "ВНИМАНИЕ — замер во время игры" -ForegroundColor Red
        Write-Host " CS2: запускайте игру с параметром -insecure (VAC отключён) и тестируйте на ботах" -ForegroundColor Red
        Write-Host " или на своём локальном сервере. НЕ делайте замер в онлайн-матчах, Premier, FACEIT, ESEA." -ForegroundColor Red
        Write-Host " Скрипт ставит глобальный перехватчик мыши (как AutoHotkey). В игру он не внедряется и память"
        Write-Host " не читает, но гарантий от ложного бана нет. Во время замера возможна небольшая задержка ввода."
        $ok = Read-Host "Продолжить? Введите «да»"
        if ($ok -notmatch '^\s*(да|д|yes|y)\s*$') { $Mode = 1; continue }
        $GameSeconds = Ask-Number "Длительность, секунд (10–600)" $GameSeconds 10 600
        $Delay = Ask-Number "Старт через, секунд (время перейти в игру)" 10 3 120
        $dur = $GameSeconds
        Write-Host "Переходите в игру. Три коротких сигнала — старт, один длинный — конец." -ForegroundColor Cyan
        for ($i = $Delay; $i -gt 0; $i--) { Write-Host "`r  Старт через $i с...   " -NoNewline; Start-Sleep -Seconds 1 }
        Write-Host ""
        foreach ($b in 1..3) { try { [Console]::Beep(1200, 120) } catch {}; Start-Sleep -Milliseconds 80 }
        $cs2p = Get-Process -Name cs2 -ErrorAction SilentlyContinue | Select-Object -First 1
        [RawMouse]::FpsPid = if ($cs2p -and [RawMouse]::UseEtw) { $cs2p.Id } else { 0 }
        Write-Host "Идёт замер $dur с..."
        [RawMouse]::RunGame($dur)
        try { [Console]::Beep(700, 500) } catch {}
    } else {
        $Seconds = Ask-Number "Длительность, секунд (5–300)" $Seconds 5 300
        $dur = $Seconds
        Write-Host "Откроется окно на весь экран: кликните по нему и, когда надпись станет зелёной, водите мышью кругами $dur с. Esc — отмена."
        Read-Host "Enter — начать" | Out-Null
        [RawMouse]::FpsPid = 0
        [RawMouse]::Run($dur)
    }
    Write-Host "Сохраняю результаты..."

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $k = [RawMouse]::TickMs
    $data = [RawMouse]::Data
    $main = $null; $devName = $null
    if ($data.Count -gt 0) {
        $main = $data.GetEnumerator() | Sort-Object { $_.Value.T.Count } -Descending | Select-Object -First 1
        $devName = [RawMouse]::DeviceName($main.Key)
    }
    if ($Mode -eq 2) {
        $n = [RawMouse]::HookCount
        $ticks = New-Object 'long[]' $n
        [Array]::Copy([RawMouse]::HookTicks, $ticks, $n)
    } elseif ($main) { $ticks = $main.Value.T.ToArray() } else { $ticks = @() }

    if ($Mode -eq 2 -and [RawMouse]::HookError) { Write-Host "Не удалось поставить перехватчик: $([RawMouse]::HookError)" -ForegroundColor Red; continue }
    if ([RawMouse]::Cancelled) { Write-Host "Замер отменён." -ForegroundColor Yellow; continue }
    if ($ticks.Length -lt 2) { Write-Host "Движений не зарегистрировано — файлы не сохранены." -ForegroundColor Yellow; continue }

    $st = [RawMouse]::StartTick; $en = [RawMouse]::EndTick
    $t0 = if ($st -gt 0) { $st } else { $ticks[0] }
    $base = Join-Path $Desktop "mouse_$stamp"
    $utf8bom = New-Object Text.UTF8Encoding $true
    $utf8 = New-Object Text.UTF8Encoding $false

    # ---- 1. информация о мыши и условиях замера ----
    $info = New-Object System.Collections.Generic.List[string]
    $info.Add("=== ХАРАКТЕРИСТИКИ МЫШИ — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===")
    foreach ($l in $sys) { $info.Add($l) }
    $info.Add("Устройство: $(if ($devName) { $devName } else { 'не определено' })")
    try {
        if (-not $main) { throw "мышь не определена" }
        foreach ($l in (Get-MouseInfo $main.Key $devName)) { $info.Add($l) }
    } catch { $info.Add("Сведения о мыши: не удалось собрать ($($_.Exception.Message))") }
    $info.Add("Длительность теста: $dur с")
    $info.Add("Наблюдаемый поток: CPU $Cpu (нумерация с 0)")
    $info.Add("Режим · Тип замера: $(if ($Mode -eq 2) { 'во время игры (перехватчик WH_MOUSE_LL)' } else { 'обычный (окно теста, Raw Input)' })")
    $info.Add("Режим · Длительность: $dur с")
    $info.Add("Режим · Права администратора: $(if ($isAdmin) { 'да' } else { 'нет' })")
    if ($Mode -eq 2) {
        if ([RawMouse]::HookInjected -gt 0) { $info.Add("Режим · Отброшено программных событий: $([RawMouse]::HookInjected)") }
    } else {
        $info.Add("Событий в фоне (окно неактивно): $([RawMouse]::BgEvents)")
    }
    if ($main) { try { foreach ($l in [RawMouse]::MotionSummary($main.Value, $ticks)) { $info.Add($l) } } catch {} }
    $fpsLines = $null
    if ($Mode -eq 2) {
        $pres = [EtwFps]::Presents
        if (-not [RawMouse]::UseEtw) { $info.Add("CS2 · FPS: не записан — нужен mouse_latency_admin.bat") } elseif ([RawMouse]::FpsPid -eq 0) { $info.Add("CS2 · FPS: не записан — CS2 не была запущена") } elseif ([EtwFps]::Error) { $info.Add("CS2 · FPS: не записан — $([EtwFps]::Error)") } elseif ($pres.Count -lt 10) { $info.Add("CS2 · FPS: нет кадров — возможно, игра запущена через Vulkan (-vulkan)") } else {
            $pa = $pres.ToArray(); [Array]::Sort($pa)
            $qo = [RawMouse]::QpcOffset; for ($i = 0; $i -lt $pa.Length; $i++) { $pa[$i] -= $qo }
            $fpsLines = New-Object System.Collections.Generic.List[string]
            $fpsLines.Add("index,time_ms,frametime_ms")
            for ($i = 0; $i -lt $pa.Length; $i++) {
                $ftv = if ($i -gt 0) { F (($pa[$i] - $pa[$i - 1]) * $k) 4 } else { '' }
                $fpsLines.Add("$i,$(F (($pa[$i] - $t0) * $k) 4),$ftv")
            }
            $info.Add("CS2 · FPS: записано кадров: $($pa.Length)")
        }
    }
    $fg = [RawMouse]::FgCounts
    if ($fg.Count) {
        $tot = ($fg.Values | Measure-Object -Sum).Sum
        $info.Add("Режим · Активное окно: " + (($fg.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 4 | ForEach-Object { "{0} {1:N0}%" -f $_.Key, ($_.Value / $tot * 100) }) -join '; '))
    }

    # ---- 2. задержка: время каждого отчёта мыши ----
    $lat = New-Object System.Collections.Generic.List[string]
    $lat.Add("index,time_ms,interval_ms")
    for ($i = 0; $i -lt $ticks.Length; $i++) {
        $d = if ($i -gt 0) { F (($ticks[$i] - $ticks[$i - 1]) * $k) 4 } else { '' }
        $lat.Add("$i,$(F (($ticks[$i] - $t0) * $k) 4),$d")
    }

    # ---- 3. перемещение: смещение по X/Y в каждом отчёте ----
    $mov = New-Object System.Collections.Generic.List[string]
    $mov.Add("time_ms,dx,dy")
    if ($main) {
        $mt = $main.Value.T; $mx = $main.Value.X; $my = $main.Value.Y
        for ($i = 0; $i -lt $mt.Count; $i++) { $mov.Add("$(F (($mt[$i] - $t0) * $k) 4),$($mx[$i]),$($my[$i])") }
    }

    # ---- 4. процессор (JSON) ----
    $nC = [RawMouse]::NCpu
    $sb = New-Object Text.StringBuilder
    [void]$sb.Append('{"version":2,"thread":' + $Cpu + ',"nCpu":' + $nC + ',"sampleMs":' + [RawMouse]::SampleMs)
    [void]$sb.Append(',"admin":' + $(if ([RawMouse]::UseEtw) { 'true' } else { 'false' }))
    [void]$sb.Append(',"error":' + $(if ([RawMouse]::SamplerError) { JS ([RawMouse]::SamplerError) } else { 'null' }))
    [void]$sb.Append(',"columns":["t_start_ms","t_end_ms","thread_load","thread_interrupt","thread_dpc","thread_interrupts_s","thread_dpcs_s","total"')
    for ($c = 0; $c -lt $nC; $c++) { [void]$sb.Append(',"cpu' + $c + '"') }
    [void]$sb.Append('],"series":[')
    $smp = [RawMouse]::GetSamples(); $first = $true
    for ($j = 1; $j -lt $smp.Length; $j++) {
        if ($smp[$j][0] -le $st -or $smp[$j - 1][0] -ge $en) { continue }
        $r = $smp[$j]
        $vals = @((JN (($smp[$j - 1][0] - $t0) * $k) 2), (JN (($r[0] - $t0) * $k) 2))
        for ($q = 1; $q -lt $r.Length; $q++) { $vals += (JN $r[$q] 2) }
        if (-not $first) { [void]$sb.Append(',') }; $first = $false
        [void]$sb.Append('[' + ($vals -join ',') + ']')
    }
    [void]$sb.Append(']')
    $avgL = [RawMouse]::AvgLoads; $maxL = [RawMouse]::MaxLoads
    if ($avgL) {
        [void]$sb.Append(',"avg":[' + (($avgL | ForEach-Object { JN $_ 2 }) -join ',') + ']')
        [void]$sb.Append(',"max":[' + (($maxL | ForEach-Object { JN $_ 2 }) -join ',') + ']')
    }
    $pl = @()
    foreach ($p in [RawMouse]::TopProcs) { $pl += ('{"name":' + (JS $p[0]) + ',"pid":' + $p[1] + ',"total":' + $p[2] + ',"core":' + $p[3] + '}') }
    [void]$sb.Append(',"processes":[' + ($pl -join ',') + ']')
    if ([RawMouse]::UseEtw) {
        if ([RawMouse]::ThreadProcs.Count) {
            $tl = @()
            foreach ($r in [RawMouse]::ThreadProcs) {
                $items = @()
                if ($r[4]) { foreach ($pp in $r[4].Split(';')) { $x = $pp.Split('|'); $items += ('{"name":' + (JS $x[0]) + ',"pct":' + $x[1] + '}') } }
                $tl += ('{"cpu":' + $r[0] + ',"busy":' + $r[1] + ',"dpc":' + $r[2] + ',"isr":' + $r[3] + ',"items":[' + ($items -join ',') + ']}')
            }
            $ppl = @(); foreach ($p in [RawMouse]::PreciseProcs) { $ppl += ('{"name":' + (JS $p[0]) + ',"total":' + $p[1] + ',"core":' + $p[2] + '}') }
            $dl = @(); foreach ($d in [RawMouse]::DriverStats) { $dl += ('{"name":' + (JS $d[0]) + ',"dpcCount":' + $d[1] + ',"dpcMs":' + $d[2] + ',"dpcMaxUs":' + $d[3] + ',"isrCount":' + $d[4] + ',"isrMs":' + $d[5] + ',"isrMaxUs":' + $d[6] + '}') }
            [void]$sb.Append(',"precise":{"events":' + [EtwCpu]::Events + ',"threads":[' + ($tl -join ',') + '],"processes":[' + ($ppl -join ',') + '],"drivers":[' + ($dl -join ',') + ']}')
        } else {
            [void]$sb.Append(',"precise":null,"preciseError":' + $(if ([EtwCpu]::Error) { JS ([EtwCpu]::Error) } else { JS 'нет данных трассировки' }))
        }
    }
    [void]$sb.Append('}')

    $files = @("${base}_1_info.txt", "${base}_2_latency.csv", "${base}_3_movement.csv", "${base}_4_cpu.json")
    try {
        [IO.File]::WriteAllLines($files[0], $info, $utf8bom)
        [IO.File]::WriteAllLines($files[1], $lat, $utf8)
        [IO.File]::WriteAllLines($files[2], $mov, $utf8)
        [IO.File]::WriteAllText($files[3], $sb.ToString(), $utf8)
        if ($fpsLines) { $ff = "${base}_5_cs2_fps.csv"; [IO.File]::WriteAllLines($ff, $fpsLines, $utf8); $files += $ff }
        Write-Host "Готово. Файлов на рабочем столе: $($files.Count) — перетащите их в mouse_analyzer.html:" -ForegroundColor Green
        foreach ($f in $files) { Write-Host ("  " + [IO.Path]::GetFileName($f)) }
        if ([RawMouse]::UseEtw -and -not [RawMouse]::ThreadProcs.Count) { Write-Host "Точный разбор процессора не удался: $([EtwCpu]::Error)" -ForegroundColor Yellow }
    } catch { Write-Host "Не удалось сохранить файлы: $_" -ForegroundColor Red }

    $again = Read-Host "Enter — ещё замер, Q — выход"
    if ($again -match '^[qQйЙ]') { break }
}
