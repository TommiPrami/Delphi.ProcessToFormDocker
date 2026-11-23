# Delphi.ProcessToFormDocker

Start a process (optionally elevated) and dock its main window into a VCL form, panel, tab sheet
or any other `TWinControl`. Includes a watchdog that detects when the docked application stops
responding, and can kill or restart it automatically.

```pascal
uses
  ProcessToFormDocker;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  FDocker := TProcessDocker.Create(Self);
  FDocker.HostControl := PanelTerminal;
  FDocker.ApplyPreset(dpClassicCmd);   // or FileName / Parameters
  FDocker.HangAction := dhaRestart;    // kill / restart when "Not responding"
  FDocker.OnHung := DockerHung;        // ... or decide case by case
  FDocker.Start;                       // window is found and docked asynchronously
end;
```

Add the `Source` folder to your search path. Units:

| Unit | Contents |
|---|---|
| `ProcessToFormDocker.pas` | `TProcessDocker` component and its container control |
| `ProcessToFormDocker.Form.pas` | `TProcessDockForm`: run an app in a modal form that looks like the app's own window, get its exit code |
| `ProcessToFormDocker.Broker.pas` | Elevated broker: dock an elevated app into a non elevated host (`RunProcessDockerBroker`) |
| `ProcessToFormDocker.Watchdog.pas` | Background thread: exit, title, hang detection, emergency kill |
| `ProcessToFormDocker.WinApi.pas` | Plain Win32 helpers, usable on their own: [elevation](#elevation-helpers) (`StartElevated`, `StartNonElevated`, `RestartSelfElevated`...), `KillProcessTree`, `GetSystemHungAppTimeout`, job objects... |

Built and tested with Delphi 13 (Win32 and Win64) on Windows 11.

> **Docking a window of another process is not something Windows officially supports.**
> It works well for many applications, partially for some and not at all for others.
> The component accepts any application on purpose; **you** have to test the application you
> want to dock before you ship. See [Compatibility](#compatibility).

## Features

- **Start** with `CreateProcess`, or elevated with `ShellExecuteEx("runas")` (`RunElevated`).
  Executables whose manifest requires elevation are restarted with `runas` automatically.
- **Window discovery**. The component finds the main window of the started process *tree*, or a
  *new* window of a given class or exe name created by another process (`WindowClassName`,
  `WindowProcessName`, `AcceptForeignWindows`). Launchers like `wt.exe` need this. `OnFindWindow`
  can veto candidates.
- **Docking**. The window is reparented into an internal container (`alClient` in `HostControl`).
  The container removes the frame, follows resizes and forwards focus. It re-applies the layout
  while the app is still placing itself after startup, and survives handle re-creation (DPI
  change, `RecreateWnd`). You can move a docked window to another host at runtime by setting
  `HostControl`. `Undock` / `Dock` toggle between docked and a normal top-level window.
- **Close / kill / restart**:
  - `CloseGracefully` (posts `WM_CLOSE` and waits) or `RequestClose` (asynchronous; kills after
    `CloseTimeoutMs`).
  - `Kill` terminates the job object, or the process tree if there is no job.
  - `Stop` closes gracefully, then kills.
  - `Restart`.
- **Dies with the host**. With `KillOnHostExit` (on by default), started processes are put into a
  job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. No orphans even when the host crashes or is
  killed from Task Manager.
- **Hang detection**, see below: notify, kill or restart, crash loop protection, and an emergency
  kill when the host UI itself gets blocked.
- `SuspendProcess` / `ResumeProcess` (great for testing hang handling), `SendTextInput` (posts
  characters to a classic console), `GetInfo` (PIDs, window, state, memory usage, restart count...).
- `ShutdownAction` decides what happens to a still-running process when the component is
  destroyed: close then kill, kill, close only, or undock and leave it running.

## Run an app as "its own window" and get the exit code

`TProcessDockForm` (unit `ProcessToFormDocker.Form`) is for running an application as part of a
workflow: start it, let the user work in it, continue when it ends.

```pascal
uses
  ProcessToFormDocker.Form;

LExitCode := TProcessDockForm.Execute('C:\Tools\Importer.exe', '/interactive');
case LExitCode of
  0: ShowImportedData;
  2: ShowMessage('Import cancelled');
else
  ShowMessageFmt('Import failed (%d)', [LExitCode]);
end;
```

- The form stays hidden until the window is docked, then takes over the application's caption
  (and follows it), icon, client size (scroll bars included), position and frame style: not
  resizable, no maximize button and so on. It gets its own taskbar button. For the user it looks
  like the application just opened.
- It is modal. When the process ends, the form closes and `Execute` returns the exit code.
- Closing the form (X, Alt+F4) sends `WM_CLOSE` to the application. The application decides what
  to do ("Save changes?") and the form follows when the process has exited. It is never killed
  for that. A console closed this way returns `$C000013A` (`STATUS_CONTROL_C_EXIT`).
- `Execute` raises `EProcessDocker` if the process can not be started. `ExecuteEx` never raises.
  It returns a `TProcessFormResult` with `Started`, `ExitCode`, `WasDocked`, `ClosedByUser` and
  `ErrorMessage`.
- If the window can not be docked (for example an elevated app in a non-elevated host), the
  application runs in its own window. The form stays hidden and the call still waits for the
  exit code. If the process exits before it shows a window, you get its exit code too.
- The optional third parameter configures the form and the docker before the start:

```pascal
LResult := TProcessDockForm.ExecuteEx(TProcessDocker.PresetInfo(dpClassicCmd).FileName,
  'cmd.exe /c build.cmd',
  procedure(AForm: TProcessDockForm)
  begin
    AForm.Placement := pfpMainFormCenter;      // pfpWindow (default), pfpScreenCenter, pfpKeep
    AForm.MirrorFrame := False;                // keep a sizeable frame
    AForm.Docker.EmergencyKillTimeoutMs := 10000;
  end);
```

Other properties: `UseWindowSize`, `MirrorCaption`, `MirrorIcon`, `ShowInTaskbar`. You can also
create a `TProcessDockForm` yourself, set it up and call `Run`. The form ends with the first
process exit, so the docker's restart options are not used here.

## Events

| Event | When | Can decide |
|---|---|---|
| `OnFindWindow` | For every candidate window during discovery | `var AAccept` |
| `OnDocked` / `OnUndocked` / `OnDockFailed` | Docking state changes / docking is impossible (with the reason) | |
| `OnHung` | Window has not responded for `HangTimeoutMs` | `var AAction` (`dhaNone`, `dhaKill`, `dhaRestart`) |
| `OnResponding` | Responding again after a reported hang | |
| `OnBeforeKill` | Before any kill: manual, hang, close timeout | `var AAllow` |
| `OnBeforeRestart` | Before any restart: manual, hang, unexpected exit | `var AAllow` (defaults to `False` when the crash loop limit is reached) |
| `OnEmergencyKill` | The watchdog had to kill because the host UI was blocked | |
| `OnProcessExit` | Process / window gone, with exit code and whether it was expected | |
| `OnTitleChange`, `OnStateChange`, `OnLog` | Informational | |

Every event receives a `TDockedProcessInfo` record (PIDs, exe names, window handle and class,
title, docked/responding/suspended state, elevation, start time, restart count, working set,
exit code).

## Hang detection

Windows considers a window "Not responding" when it has not processed messages for
`HKCU\Control Panel\Desktop\HungAppTimeout` milliseconds (default 5000). The watchdog thread uses
the same signals: `IsHungAppWindow()` plus a `WM_NULL` ping sent with `SendMessageTimeout`.

- `HangTimeoutMs = 0` (the default) uses the system value (`TProcessDocker.SystemHungAppTimeoutMs`).
  Set your own value to react faster or slower.
- `HangAction` is the default reaction. `OnHung` can change it case by case, and kills and
  restarts still go through `OnBeforeKill` / `OnBeforeRestart`.
- `RestartOnUnexpectedExit` restarts after a crash. `MaxRestarts` within `RestartWindowMs` is the
  crash loop protection.
- The watchdog settings apply live; changing them restarts the watchdog thread.

### Why an emergency kill?

When a window of another process is a child of your window, Windows attaches the input queues of
the two threads. If the docked application hangs, **your UI thread can hang too**. Activation and
focus changes are sent synchronously to the hung window: clicking your form or showing a dialog
can be enough.

The watchdog runs in its own thread and never waits for the UI thread. While the docked window is
hung, it keeps sending heartbeats to the main thread (`TThread.Queue`). If one is not processed
within `EmergencyKillTimeoutMs`, the main thread is blocked, and the watchdog kills the process
itself. That frees your UI. `OnEmergencyKill` tells you afterwards, and with `HangAction =
dhaRestart` the application is restarted. The emergency kill is off by default (`0`) because no
event can veto it. Turning it on is recommended.

Because of the same input queue sharing, avoid modal dialogs in `OnHung`. They work, but showing
one may itself block until the emergency kill steps in.

## Terminals

| Preset | Command | Notes |
|---|---|---|
| `dpClassicCmd` | `conhost.exe cmd.exe` | Works well |
| `dpClassicPowerShell` | `conhost.exe powershell.exe -NoLogo` | Works well |
| `dpPowerShell7` | `conhost.exe pwsh.exe -NoLogo` | Needs PowerShell 7 installed |
| `dpWindowsTerminal` | `wt.exe -w new` | Works. WT draws its own tab bar and caption buttons inside the docked area. |

On Windows 11, when Windows Terminal is the default terminal app, starting `cmd.exe` directly
hands the console over to Windows Terminal, so there is no classic console window to dock.
Starting it through `conhost.exe` forces the classic console window, which docks reliably. (From
a 32-bit host, `Sysnative\conhost.exe` is used.)

`wt.exe` is only a launcher, and the window can come from another `WindowsTerminal.exe` process.
The preset therefore accepts a *new* window of class `CASCADIA_HOSTING_WINDOW_CLASS` from any
process. If that process was not started by us (one Terminal process can host many windows),
`Kill` will not touch it unless `AllowKillForeignProcess` is set. Otherwise you could kill the
user's other terminal windows. Graceful close (`WM_CLOSE`) always works.

## Elevation (UIPI)

`RunElevated := True` starts the process with a UAC prompt. However, Windows User Interface
Privilege Isolation **does not allow a non-elevated process to re-parent, restyle or send most
messages to an elevated window**. So:

| Host | Docked process | Result |
|---|---|---|
| not elevated | not elevated | Works |
| elevated | elevated (inherits, no UAC prompt) | Works |
| elevated | not elevated | Works |
| not elevated | elevated | **Works with `BrokerMode`** (below). Without it, the process runs in its own window and `OnDockFailed` explains why. |

Without a broker, `KillOnHostExit` is not available for processes started elevated from a
non-elevated host.

### Elevation helpers

Plain functions in `ProcessToFormDocker.WinApi`, usable without `TProcessDocker`:

| Function | |
|---|---|
| `StartElevated(FileName, Parameters, Dir, ShowCmd, ParentWnd)` | UAC prompt (none when already elevated). Returns the process handle; 0 + `ERROR_CANCELLED` when the user said no |
| `StartNonElevated(FileName, Parameters, Dir, ShowCmd)` | Starts a program as the **normal user, also from an elevated process**. It uses the token of the desktop shell (Explorer). When UAC is off, there is no lower level and it runs elevated |
| `RestartSelfElevated(ExtraParameters)` | New elevated copy of your exe with the same parameters and working directory. Close your app when it returns `True` |
| `RestartSelfNonElevated(ExtraParameters)` | The other way around |
| `WaitForProcess(Process, out ExitCode, TimeoutMs)` | Waits for the process and returns its exit code (blocks the calling thread) |
| `GetElevationType` | `petLimited` (admin, not elevated: can elevate), `petFull` (elevated), `petDefault` (standard user / UAC off) |
| `IsCurrentProcessElevated`, `GetCommandLineParameters`, `RelaunchSelfElevated` | |

Elevate only the operation that needs it, and get its result:

```pascal
LProcess := StartElevated(ParamStr(0), '/WriteLicense "' + LFileName + '"');
if LProcess = 0 then
  Exit; // cancelled
try
  WaitForProcess(LProcess, LExitCode);
finally
  CloseHandle(LProcess);
end;
```

When an app restarts itself at startup, pass a marker in `ExtraParameters` and check it. Then a
copy that still isn't elevated (UAC off for a standard user...) doesn't restart again and again.

`Tests/ElevationHelpers` tests all of them. The full run needs one UAC prompt. `/local` tests the
part that needs none.

### Elevated application in a non-elevated host: the broker

A running process can't be elevated, and running your whole application as administrator just
to show one elevated tool is not nice. UIPI only blocks *lower → higher*, so the docking is done
from the elevated side:

```pascal
// .dpr: first thing, before Application.Initialize, single instance checks etc.
uses
  ProcessToFormDocker.Broker;
begin
  if RunProcessDockerBroker then
    Exit;
  Application.Initialize;
  ...

// Anywhere
FDocker.FileName := 'C:\Tools\LicenseTool.exe';   // requireAdministrator in its manifest
FDocker.BrokerMode := dbmWhenElevationNeeded;
FDocker.Start;                                     // one UAC prompt
```

When the application needs elevation (`RunElevated`, or its manifest requires it) and the host is
not elevated, `TProcessDocker` starts **a copy of your exe elevated** with the
`/ProcessDockerBroker` switch. The UAC prompt shows your application's name. That broker:

- creates a panel of its own *inside* your container window (allowed, it is the higher side),
- starts the application and docks it there with a normal `TProcessDocker`,
- follows your container's size,
- executes what your host can't do itself: close, kill, suspend, hang detection,
- reports everything back. **Your events work as usual**: `OnDocked`, `OnHung` (with its
  `AAction`), `OnBeforeKill`, `OnProcessExit` with the exit code, `RestartOnUnexpectedExit`, and
  so on. `IsBrokered` tells you it is in use.
- **dies with your host**: if your application exits or crashes, the broker kills the elevated
  application and exits.

The elevation lasts exactly as long as the elevated application runs. A restart reuses the broker,
so there is no second UAC prompt. With `TProcessDockForm`, set `AForm.Docker.BrokerMode` in the
configure callback.

Security: the command line is fixed when the broker starts, and the broker accepts only a few
commands from the host (close, kill, suspend, resume, focus, layout). It never forwards keyboard
input, so `SendTextInput` is refused, and `Undock` / `Dock` are not available either. That way
other non-elevated programs can't use the broker to type into or run anything as administrator.

Good to know:

- `BrokerFileName` can name a separate broker exe instead (its `.dpr` calls
  `RunProcessDockerBroker`). The UAC prompt then shows that exe.
- A hung elevated application can still block your UI through the shared input queue. The
  broker's emergency kill also watches **your** window: with `EmergencyKillTimeoutMs` set, it
  kills the hung application when your form stops responding.
- The watchdog settings are passed to the broker when it starts. Changing them later applies to
  the next start.
- `dbmAlways` uses a broker even when no elevation is needed (testing).

`Tests/ElevatedBroker` tests all of this without UAC prompts. Its host runs at *low* integrity,
and the broker and application at normal integrity, which follows the same UIPI rules.
`ElevatedBrokerTest.exe real <exe>` runs the real thing with a UAC prompt.

## Compatibility

Tested on Windows 11 (build 26300) with the demo and a scripted smoke test. Each app was docked,
resized, moved to another panel, undocked/re-docked and closed:

| Application | Result |
|---|---|
| cmd.exe / Windows PowerShell via conhost | ✅ Including hang detection, kill, restart, emergency kill |
| Windows Terminal | ✅ |
| Character Map (classic Win32) | ✅ |
| Notepad (Windows 11 Store version) | ❌ Crashes (`0xC000027B`) as soon as it is re-parented |

The general rule: classic Win32 applications usually work. UWP / WinUI / XAML Islands apps may
not. Single-instance apps (one process, many windows or tabs) need `AcceptForeignWindows` and may
open a tab in an existing window instead of creating a new one. Mixed DPI awareness between host
and child can cause scaling glitches.

If an application behaves badly, try `UseChildStyle := False` (no `WS_CHILD`),
`RemoveWindowFrame := False` or `StartHidden := False`.

## Demo

`Demos/ProcessDockerDemo` is a tabbed host:

- Each tab docks one process: the terminal presets, Character Map, Notepad (to show a failure),
  Registry Editor (to show elevation), or a custom command.
- **Dock elevated apps via broker** (on by default): Registry Editor and other elevated apps are
  docked into the non-elevated demo after one UAC prompt.
- Buttons for close / kill / restart / undock / simulate hang (suspend) / resume / send text to
  the console.
- **Run as app window...** runs the selected command with `TProcessDockForm.ExecuteEx` and reacts
  to the exit code.
- Watchdog options: hang action including an *Ask* dialog, hang timeout, auto restart,
  confirmation through `OnBeforeKill` / `OnBeforeRestart`, emergency kill.
- A live log and a status bar.

Open `ProcessDockerDemo.dpr` in the IDE. The `.res` (manifest: themes, per-monitor DPI,
`asInvoker`) is built from `ProcessDockerDemo.rc`.

## Ideas / not done yet

- Design-time package (`Register`) so the component can be dropped on a form.
- Capture the docked window as an image (thumbnails for tabs) with `PrintWindow`.
- Hide Windows Terminal's own caption buttons (WT settings / command line options).
