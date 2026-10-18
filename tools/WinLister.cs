using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// =====================================================================
//  VERIFICATION TOOL -- NOT PART OF THE PRODUCT BUILD
// =====================================================================
//
// This file is compiled at *test* time by tools/n13_single_instance_test.ps1
// via Add-Type. It is NOT referenced by any CMakeLists.txt / vcxproj and does
// not ship in the app. It exists so the single-instance behaviour can be
// re-verified later without rewriting the P/Invoke plumbing.
//
// Diagnostic helper: list every top-level window belonging to a process.
//
// Why C# and not a PowerShell scriptblock: PS callback marshalling of
// StringBuilder truncated the class/title strings to a single character,
// which produced unusable readings ("class=F title='s'").
public class WinLister {
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);

    public static List<string> List(uint targetPid) {
        var outp = new List<string>();
        EnumWindows((h, l) => {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid != targetPid) return true;
            var t = new StringBuilder(512);
            var c = new StringBuilder(256);
            GetWindowTextW(h, t, t.Capacity);
            GetClassNameW(h, c, c.Capacity);
            outp.Add(string.Format(
                "hwnd={0} class={1} title='{2}' visible={3} owner={4}",
                h, c.ToString(), t.ToString(), IsWindowVisible(h),
                GetWindow(h, 4) != IntPtr.Zero));
            return true;
        }, IntPtr.Zero);
        return outp;
    }
}
