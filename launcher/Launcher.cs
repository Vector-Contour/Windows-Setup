// VectorContour Windows Setup launcher.
// A small .exe that carries winsetup.ps1 inside it, writes it to a temp folder,
// and starts it in Windows PowerShell as administrator. Drop a preset .json on the
// exe (or pass it as an argument) to load that preset.
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("VectorContour Windows Setup")]
[assembly: AssemblyProduct("VectorContour Windows Setup")]
[assembly: AssemblyCompany("VectorContour")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]

static class Launcher
{
    const string Title = "VectorContour Windows Setup";

    [STAThread]
    static int Main(string[] args)
    {
        try
        {
            string dir = Path.Combine(Path.GetTempPath(), "VectorContourSetup");
            Directory.CreateDirectory(dir);
            string script = Path.Combine(dir, "winsetup.ps1");

            using (Stream res = Assembly.GetExecutingAssembly().GetManifestResourceStream("winsetup.ps1"))
            using (var reader = new StreamReader(res, Encoding.UTF8))
            {
                // UTF-8 with BOM so Windows PowerShell 5.1 reads the file correctly.
                File.WriteAllText(script, reader.ReadToEnd(), new UTF8Encoding(true));
            }

            var extra = new StringBuilder();
            bool unattended = false;
            foreach (string a in args)
            {
                if (a.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
                    extra.Append(" -Preset \"").Append(Path.GetFullPath(a)).Append('"');
                else
                {
                    if (a.Equals("-Run", StringComparison.OrdinalIgnoreCase)) unattended = true;
                    extra.Append(' ').Append(a);
                }
            }

            // The window has its own log, so hide the console unless running unattended.
            string style = unattended ? "" : " -WindowStyle Hidden";
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -STA" + style + " -File \"" + script + "\"" + extra,
                UseShellExecute = true,
                Verb = "runas",
            };
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            var win32 = ex as Win32Exception;
            if (win32 != null && win32.NativeErrorCode == 1223)
            {
                // The user pressed No on the admin prompt.
                MessageBox.Show("Windows Setup needs administrator rights to make changes.", Title,
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return 1;
            }
            MessageBox.Show("Could not start Windows Setup:\n\n" + ex.Message, Title,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }
    }
}
