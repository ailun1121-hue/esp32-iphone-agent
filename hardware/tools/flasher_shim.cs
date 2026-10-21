// Minimal argv forwarder: replaces the PyInstaller-packed flasher.exe of the ESP32 Arduino core.
//
// Why: those one-file PyInstaller exes unpack helper DLLs next to themselves at startup. On a
// locked-down toolchain directory that fails with
//   "Failed to extract VCRUNTIME140.dll ... fopen: Permission denied"
// and the upload aborts. The .py implementation ships next to the .exe and is identical, so this
// shim runs it with the same argument vector. No firmware behaviour changes.
//
// Build: csc /target:exe /platform:anycpu /out:flasher.exe flasher_shim.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class FlasherShim {
    static int Main(string[] args) {
        string own = Path.GetDirectoryName(Environment.GetCommandLineArgs()[0]);
        string script = Path.Combine(own, "flasher.py");
        if (!File.Exists(script)) {
            Console.Error.WriteLine("flasher.py not found next to " + own);
            return 127;
        }

        string python = FindPython();
        if (python == null) {
            Console.Error.WriteLine("no python interpreter found (set ESP32_PYTHON to one)");
            return 127;
        }

        var psi = new ProcessStartInfo(python) {
            UseShellExecute = false,
            Arguments = JoinArgs(script, args),
        };

        using (var p = Process.Start(psi)) {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    // Quote for CreateProcess: wrap in quotes, escape backslashes that precede a quote, double the
    // quotes. Matches the CommandLineToArgvW rules the esptool/flasher scripts expect.
    static string JoinArgs(string script, string[] args) {
        var sb = new StringBuilder(Quote(script));
        foreach (string a in args) {
            sb.Append(' ');
            sb.Append(Quote(a));
        }
        return sb.ToString();
    }

    static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return value;
        var sb = new StringBuilder("\"");
        for (int i = 0; i < value.Length; i++) {
            int backslashes = 0;
            while (i < value.Length && value[i] == '\\') { i++; backslashes++; }
            if (i == value.Length) { sb.Append('\\', backslashes * 2); break; }
            if (value[i] == '"') { sb.Append('\\', backslashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', backslashes).Append(value[i]); }
        }
        sb.Append('"');
        return sb.ToString();
    }

    static string FindPython() {
        string env = Environment.GetEnvironmentVariable("ESP32_PYTHON");
        if (!string.IsNullOrEmpty(env) && File.Exists(env)) return env;

        foreach (string name in new[] { "python", "python3", "py" }) {
            string resolved = Which(name);
            if (resolved != null) {
                // Reject the Microsoft Store alias stub: it exits non-zero without doing anything.
                try {
                    var psi = new ProcessStartInfo(resolved, "-c \"import sys\"") {
                        UseShellExecute = false,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                    };
                    using (var p = Process.Start(psi)) {
                        p.StandardOutput.ReadToEnd();
                        p.StandardError.ReadToEnd();
                        p.WaitForExit();
                        if (p.ExitCode == 0) return resolved;
                    }
                } catch { }
            }
        }
        return null;
    }

    static string Which(string name) {
        string path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path)) return null;
        foreach (string dir in path.Split(Path.PathSeparator)) {
            if (dir.Length == 0) continue;
            foreach (string ext in new[] { ".exe", ".bat", ".cmd" }) {
                try {
                    string candidate = Path.Combine(dir, name + ext);
                    if (File.Exists(candidate)) return candidate;
                } catch { }
            }
        }
        return null;
    }
}
