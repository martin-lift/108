using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class Agent108Taskbar {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    public static void IdentifyWindowProcess() {
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID("Edu108.Agent108"));
    }
}

class Agent108 {
    [STAThread] static int Main(string[] args) {
        try {
            var script = new StringBuilder();
            foreach (string resource in new[]{"Network.ps1","BrowserProcesses.ps1","BrowserGuard.ps1","GameProcesses.ps1","GameGuard.ps1","Main.ps1"}) {
                using(var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
                using(var reader = new StreamReader(stream, Encoding.UTF8)) script.AppendLine(reader.ReadToEnd());
            }
            using(var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Reconnect.ps1"))
            using(var reader = new StreamReader(stream)) script.Insert(0,"$worker=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('"+Convert.ToBase64String(Encoding.UTF8.GetBytes(reader.ReadToEnd()))+"'))\n");
            foreach(string arg in args) if(!System.Text.RegularExpressions.Regex.IsMatch(arg,@"\A[a-zA-Z0-9-]+\z")) throw new Exception("Invalid argument");
            script.AppendLine("Invoke-Agent "+String.Join(" ",Array.ConvertAll(args,a=>"'"+a+"'")));
            string boot="$ErrorActionPreference='Stop';try { & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())))); exit 0 }catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }";
            var start=new ProcessStartInfo(Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\powershell.exe"),"-NoProfile -NonInteractive -STA -EncodedCommand "+Convert.ToBase64String(Encoding.Unicode.GetBytes(boot)));
            start.UseShellExecute=false; start.CreateNoWindow=true; start.RedirectStandardInput=true; start.RedirectStandardError=true;
            start.EnvironmentVariables["PSModulePath"]=Path.Combine(Environment.SystemDirectory,@"WindowsPowerShell\v1.0\Modules");
            using(var process=Process.Start(start)){
                process.StandardInput.Write(Convert.ToBase64String(Encoding.UTF8.GetBytes(script.ToString()))); process.StandardInput.Close();
                string error=process.StandardError.ReadToEnd();process.WaitForExit();
                if(process.ExitCode!=0){if(args.Length==0) MessageBox.Show(error,"Agent108"); else Console.Error.WriteLine(error);}
                return process.ExitCode;
            }
        } catch(Exception e){if(args.Length==0) MessageBox.Show(e.Message,"Agent108");return 1;}
    }
}
