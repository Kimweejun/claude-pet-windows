// clawdex-hook: tiny Claude Code hook that forwards events to the clawdex pet daemon.
// Reads the hook JSON from stdin, appends one line to ~/.clawdex/events.log, and (on SessionStart)
// starts the daemon if it is not running. Never blocks, never prints, always exits 0.
using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

static class ClawdexHook
{
    const string MutexName = "Local\\ClawdexPetDaemon";

    static int Main()
    {
        try
        {
            string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".clawdex");
            string input = ReadStdin();
            string ev = Grab(input, "hook_event_name");
            if (ev.Length == 0) return 0;
            string tool = Grab(input, "tool_name");

            if (!DaemonRunning())
            {
                // Only a fresh session brings the pet back; a pet the user closed stays closed mid-session.
                string src = Grab(input, "source");
                if (ev == "SessionStart" && src != "compact") Launch(root);
                return 0;
            }

            Directory.CreateDirectory(root);
            long ts = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
            byte[] line = Encoding.UTF8.GetBytes("{\"event\":\"" + ev + "\",\"tool\":\"" + tool + "\",\"ts\":" + ts + "}\n");
            using (var fs = new FileStream(Path.Combine(root, "events.log"), FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                fs.Write(line, 0, line.Length);
        }
        catch { }
        return 0;
    }

    static string ReadStdin()
    {
        var sb = new StringBuilder();
        var t = new Thread(() =>
        {
            try
            {
                using (var s = Console.OpenStandardInput())
                {
                    var buf = new byte[8192]; int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0) sb.Append(Encoding.UTF8.GetString(buf, 0, n));
                }
            }
            catch { }
        });
        t.IsBackground = true;
        t.Start();
        t.Join(1500);
        lock (sb) return sb.ToString();
    }

    static string Grab(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + key + "\"\\s*:\\s*\"([A-Za-z0-9_.:\\-]*)\"");
        return m.Success ? m.Groups[1].Value : "";
    }

    static bool DaemonRunning()
    {
        try { Mutex.OpenExisting(MutexName).Close(); return true; }
        catch (WaitHandleCannotBeOpenedException) { return false; }
        catch { return false; }
    }

    static void Launch(string root)
    {
        // wscript + ShellExecute: no console flash, and the daemon does not inherit the hook's pipes.
        var psi = new ProcessStartInfo("wscript.exe", "//B //Nologo \"" + Path.Combine(root, "clawdex-launch.vbs") + "\"");
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        Process.Start(psi);
    }
}
