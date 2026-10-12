using System.ComponentModel;

namespace SSHClient.Windows;

public sealed class TerminalTabItem : INotifyPropertyChanged
{
    public string Title { get; set; } = "";
    public string SessionId { get; set; } = "";
    public Host? Host { get; set; }
    public bool Closing { get; set; }
    public List<string> PaneIds { get; } = [];
    public List<TerminalView> Views { get; } = [];
    private string state = "Connecting";
    public string State
    {
        get => state;
        set { if (state == value) return; state = value; PropertyChanged?.Invoke(this, new(nameof(State))); PropertyChanged?.Invoke(this, new(nameof(Summary))); }
    }
    public string Summary => $"{Title}\n{Host?.Description}\n{State}";
    public event PropertyChangedEventHandler? PropertyChanged;
}
