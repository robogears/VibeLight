namespace VibeLightHelper;

static class Program
{
    [STAThread]
    static void Main()
    {
        // One copy: a second would find the port taken anyway.
        using var single = new Mutex(initiallyOwned: true, @"Local\VibeLightHelper", out bool first);
        if (!first) return;
        // Real pixels on scaled displays: window and display maths would be off otherwise.
        NativeTray.SetProcessDpiAwarenessContext(NativeTray.PerMonitorAwareV2);
        new TrayApp().Run();
    }
}
