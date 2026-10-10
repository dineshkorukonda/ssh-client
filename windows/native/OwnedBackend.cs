using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace SSHClient.Windows;

public sealed class OwnedBackend : IDisposable
{
    private readonly string root;
    private nint job;
    private nint process;
    private bool disposed;
    public bool IsRunning => process != 0 && GetExitCodeProcess(process, out var code) && code == 259;
    public OwnedBackend(string root) => this.root = root;

    public async Task<DesktopClient> StartAsync()
    {
        var launcher = Path.Combine(root, "bin", "ssh_client.bat");
        if (!File.Exists(launcher)) throw new FileNotFoundException("The packaged SSH backend is missing. Install the complete ssh-client package.", launcher);
        var logs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ssh-client", "logs");
        Directory.CreateDirectory(logs);
        var reservation = new TcpListener(IPAddress.Loopback, 0); reservation.Start();
        var port = ((IPEndPoint)reservation.LocalEndpoint).Port;
        var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var environment = Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>()
            .Where(entry => !entry.Key.ToString()!.StartsWith("RELEASE_", StringComparison.OrdinalIgnoreCase))
            .ToDictionary(entry => entry.Key.ToString()!, entry => entry.Value!.ToString()!, StringComparer.OrdinalIgnoreCase);
        environment["SSH_CLIENT_PORT"] = port.ToString();
        environment["SSH_CLIENT_DESKTOP_TOKEN"] = token;
        environment["SSH_CLIENT_DESKTOP"] = "1";
        environment["RELEASE_DISTRIBUTION"] = "none";
        environment["RELEASE_TMP"] = Path.Combine(logs, "release");
        environment["RELEASE_COOKIE"] = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        var block = string.Join('\0', environment.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase).Select(pair => pair.Key + "=" + pair.Value)) + "\0\0";
        var blockPointer = Marshal.StringToHGlobalUni(block);
        try
        {
            job = CreateJobObject(0, null);
            if (job == 0) throw new Win32Exception();
            var limits = new JobLimits { Basic = new BasicLimits { LimitFlags = 0x2000 } }; // Kill this job's processes when its handle closes.
            if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>())) throw new Win32Exception();
            var startup = new StartupInfo { Size = (uint)Marshal.SizeOf<StartupInfo>() };
            var command = new StringBuilder($"cmd.exe /d /s /c \"\"{launcher}\" start > \"{Path.Combine(logs, "backend.log")}\" 2>&1\"");
            if (!CreateProcess(Path.Combine(Environment.SystemDirectory, "cmd.exe"), command, 0, 0, false, 0x08000000 | 0x00000004 | 0x00000400,
                blockPointer, root, ref startup, out var info)) throw new Win32Exception();
            process = info.Process;
            try
            {
                if (!AssignProcessToJobObject(job, process)) { TerminateProcess(process, 1); throw new Win32Exception(); }
                reservation.Stop();
                if (ResumeThread(info.Thread) == uint.MaxValue) throw new Win32Exception();
            }
            finally { CloseHandle(info.Thread); }
        }
        finally { reservation.Stop(); Marshal.FreeHGlobal(blockPointer); }

        var api = new DesktopClient(port, token);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        while (!deadline.IsCancellationRequested)
        {
            if (!IsRunning) { api.Dispose(); throw new IOException("The SSH backend failed to start. See " + Path.Combine(logs, "backend.log")); }
            try
            {
                var health = await api.GetAsync("health", deadline.Token);
                if (health.GetProperty("ready").GetBoolean() && health.GetProperty("api_version").GetInt32() == 1) return api;
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException) { }
            await Task.Delay(250);
        }
        api.Dispose();
        throw new TimeoutException("The SSH backend did not become ready within 60 seconds. See " + Path.Combine(logs, "backend.log"));
    }

    public void Dispose()
    {
        if (disposed) return; disposed = true;
        if (job != 0) { CloseHandle(job); job = 0; }
        if (process != 0) { CloseHandle(process); process = 0; }
    }

    [StructLayout(LayoutKind.Sequential)] private struct BasicLimits { public long PerProcessTime, PerJobTime; public uint LimitFlags; public nuint MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcessLimit; public nuint Affinity; public uint PriorityClass, SchedulingClass; }
    [StructLayout(LayoutKind.Sequential)] private struct IOCounters { public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
    [StructLayout(LayoutKind.Sequential)] private struct JobLimits { public BasicLimits Basic; public IOCounters IO; public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct StartupInfo { public uint Size; public string? Reserved, Desktop, Title; public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags; public ushort ShowWindow, Reserved2; public nint ReservedPointer, StdInput, StdOutput, StdError; }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public nint Process, Thread; public uint ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern nint CreateJobObject(nint attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(nint job, int infoClass, ref JobLimits information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(nint job, nint process);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcess(string application, StringBuilder command, nint processAttributes, nint threadAttributes, bool inheritHandles, uint flags, nint environment, string currentDirectory, ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(nint thread);
    [DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(nint process, out uint code);
    [DllImport("kernel32.dll")] private static extern bool TerminateProcess(nint process, uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
}
