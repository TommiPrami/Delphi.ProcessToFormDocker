unit ProcessToFormDocker;

{
  TProcessDocker - start a process (optionally elevated) and dock its main window
  into a VCL form or any TWinControl (panel, tab sheet...).

  Features
    - Start normally (CreateProcess) or elevated (ShellExecuteEx "runas"),
      automatic elevation fallback for executables that require it.
    - Finds the main window of the started process tree, or a new window of a given
      class / exe name (needed for apps like Windows Terminal or Store Notepad that
      create their window from another process).
    - Docks by re-parenting the window into an internal container control that fills
      HostControl, follows resizes, forwards focus, survives handle re-creation
      (DPI change, moving to another parent) and can undock back to a normal window.
    - Graceful close (WM_CLOSE, sync or async), kill (job object / process tree),
      restart, suspend / resume.
    - Optional job object so started processes die with the host, even on a crash.
    - Watchdog thread: exit detection, title changes, "Not responding" detection
      with the same rules Windows uses (IsHungAppWindow + ping with timeout),
      automatic kill / restart on hang, automatic restart on unexpected exit with
      crash loop protection, and an emergency kill when the host UI is blocked.
    - Events with var parameters so the application can veto kills and restarts.
    - BrokerMode: an ELEVATED application docked into a NON elevated host through an
      elevated broker process (see ProcessToFormDocker.Broker).

  Docking a window of another process is not something Windows officially supports
  for arbitrary applications. It works well for many (classic console, most Win32
  apps), partially for some (Windows Terminal, UWP/WinUI apps) and not at all for
  others. Always test the application you want to dock.
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  System.Generics.Collections, Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics, Vcl.Forms,
  ProcessToFormDocker.WinApi, ProcessToFormDocker.Watchdog;

type
  EProcessDocker = class(Exception);

  TProcessDocker = class;

  TProcessDockerState = (
    pdsIdle,      // Nothing started yet
    pdsStarting,  // Process started, looking for its window
    pdsRunning,   // Running (docked or not, see IsDocked)
    pdsClosing,   // Close requested, waiting for the process to exit
    pdsExited,    // Process / window is gone
    pdsFailed     // Start or window discovery failed and nothing is running
  );

  TDockHangAction = (dhaNone, dhaKill, dhaRestart);
  TDockKillReason = (dkrManual, dkrHung, dkrCloseTimeout);
  TDockRestartReason = (drrManual, drrHung, drrUnexpectedExit);

  /// <summary>What happens to a running process when the TProcessDocker is destroyed.</summary>
  TDockShutdownAction = (
    dsaCloseThenKill,   // WM_CLOSE, wait CloseTimeoutMs, then kill
    dsaKill,            // Kill immediately
    dsaCloseOnly,       // Undock, post WM_CLOSE and leave it be
    dsaUndockAndLeave   // Undock and leave the process running
  );

  TDockPreset = (dpClassicCmd, dpClassicPowerShell, dpPowerShell7, dpWindowsTerminal, dpNotepad);

  /// <summary>
  ///   Docking an elevated application into a non elevated host through an elevated
  ///   broker process (see ProcessToFormDocker.Broker). Needs RunProcessDockerBroker in
  ///   the .dpr.
  /// </summary>
  TDockBrokerMode = (
    dbmOff,                  // Never use a broker
    dbmWhenElevationNeeded,  // RunElevated, or the exe requires elevation, and the host is not elevated
    dbmAlways                // Always through a broker (mainly for testing)
  );

  /// <summary>Custom broker launch (testing, a service...). Returns the broker process handle.</summary>
  TDockBrokerLaunchHook = reference to function(const AFileName, AParameters: string; AElevated: Boolean): THandle;

  TDockPresetInfo = record
    Caption: string;
    FileName: string;
    Parameters: string;
    WindowClassName: string;
    WindowProcessName: string;
    AcceptForeignWindows: Boolean;
  end;

  TDockedProcessInfo = record
    State: TProcessDockerState;
    FileName: string;
    Parameters: string;
    LaunchedProcessId: DWORD;
    WindowProcessId: DWORD;
    WindowProcessName: string;
    WindowIsForeign: Boolean;
    WindowHandle: HWND;
    WindowClassName: string;
    WindowTitle: string;
    Docked: Boolean;
    Responding: Boolean;
    Suspended: Boolean;
    Elevated: Boolean;
    StartTime: TDateTime;
    RestartCount: Integer;
    UnresponsiveMs: Cardinal;
    WorkingSetBytes: UInt64;
    ExitCode: DWORD;
  end;

  TDockWindowCandidate = record
    Handle: HWND;
    ProcessId: DWORD;
    ProcessName: string;
    ClassName: string;
    Title: string;
    Visible: Boolean;
    InProcessTree: Boolean;
  end;

  TDockFindWindowEvent = procedure(Sender: TObject; const ACandidate: TDockWindowCandidate;
    var AAccept: Boolean) of object;
  TDockFailedEvent = procedure(Sender: TObject; const AReason: string) of object;
  TDockHungEvent = procedure(Sender: TObject; const AInfo: TDockedProcessInfo;
    var AAction: TDockHangAction) of object;
  TDockHangInfoEvent = procedure(Sender: TObject; const AInfo: TDockedProcessInfo;
    AUnresponsiveMs: Cardinal) of object;
  TDockBeforeKillEvent = procedure(Sender: TObject; const AInfo: TDockedProcessInfo;
    AReason: TDockKillReason; var AAllow: Boolean) of object;
  TDockBeforeRestartEvent = procedure(Sender: TObject; const AInfo: TDockedProcessInfo;
    AReason: TDockRestartReason; var AAllow: Boolean) of object;
  TDockProcessExitEvent = procedure(Sender: TObject; const AInfo: TDockedProcessInfo;
    AExitCode: DWORD; AExpected: Boolean) of object;
  TDockTextEvent = procedure(Sender: TObject; const AText: string) of object;

  /// <summary>Internal control the docked window lives in. Fills HostControl.</summary>
  TProcessDockContainer = class(TCustomControl)
  private
    FDocker: TProcessDocker;
    procedure WMDestroy(var AMessage: TWMDestroy); message WM_DESTROY;
    procedure WMSetFocus(var AMessage: TWMSetFocus); message WM_SETFOCUS;
    procedure WMEraseBkgnd(var AMessage: TWMEraseBkgnd); message WM_ERASEBKGND;
  protected
    procedure CreateParams(var AParams: TCreateParams); override;
    procedure CreateWnd; override;
    procedure Resize; override;
    procedure Paint; override;
  public
    constructor Create(ADocker: TProcessDocker); reintroduce;
    destructor Destroy; override;
  end;

  TProcessDocker = class(TComponent)
  private
    // Configuration
    FHostControl: TWinControl;
    FFileName: string;
    FParameters: string;
    FWorkingDirectory: string;
    FRunElevated: Boolean;
    FStartHidden: Boolean;
    FWindowClassName: string;
    FWindowProcessName: string;
    FAcceptForeignWindows: Boolean;
    FFindWindowTimeoutMs: Cardinal;
    FUseChildStyle: Boolean;
    FRemoveWindowFrame: Boolean;
    FFocusOnDock: Boolean;
    FKillOnHostExit: Boolean;
    FAllowKillForeignProcess: Boolean;
    FCloseTimeoutMs: Cardinal;
    FKillAfterCloseTimeout: Boolean;
    FShutdownAction: TDockShutdownAction;
    FHangDetection: Boolean;
    FHangTimeoutMs: Cardinal;
    FPollIntervalMs: Cardinal;
    FHangAction: TDockHangAction;
    FEmergencyKillTimeoutMs: Cardinal;
    FRestartOnUnexpectedExit: Boolean;
    FMaxRestarts: Integer;
    FRestartWindowMs: Cardinal;
    FRestartDelayMs: Cardinal;
    FColor: TColor;
    FShowStatusText: Boolean;
    FBrokerMode: TDockBrokerMode;
    FBrokerFileName: string;
    FEmergencyWatchWindow: HWND;

    // Broker (host side)
    class var FBrokerLaunchHook: TDockBrokerLaunchHook;
    var
    FBrokerActive: Boolean;
    FBrokerProcess: THandle;
    FBrokerWnd: HWND;
    FBrokerLinkWnd: HWND;
    FBrokerSession: Integer;
    FBrokerCookie: Word;
    FBrokerSignature: string;
    FBrokerSessionAlive: Boolean;
    FBrokerPending: TList<TPair<Word, LPARAM>>;
    FBrokerEvents: TList<TPair<Integer, string>>;

    // Runtime
    FContainer: TProcessDockContainer;
    FLink: IProcessDockerLink;
    FLinkObject: TObject;
    FTimer: TTimer;
    FWatchdog: TDockWatchdog;
    FWatchdogCounter: Integer;
    FParkingWnd: HWND;
    FState: TProcessDockerState;
    FJob: THandle;
    FLaunchedProcess: THandle;
    FLaunchedPid: DWORD;
    FLaunchedElevated: Boolean;
    FWindowProcess: THandle;
    FWindowPid: DWORD;
    FWindowIsForeign: Boolean;
    FWindowProcessNameFound: string;
    FWindowClassFound: string;
    FDockedWnd: HWND;
    FIsDocked: Boolean;
    FIsParked: Boolean;
    FHaveOriginal: Boolean;
    FOriginalStyle: NativeInt;
    FOriginalExStyle: NativeInt;
    FOriginalParent: HWND;
    FOriginalRect: TRect;
    FOriginalClientRect: TRect;
    FTitle: string;
    FStartTime: TDateTime;
    FExitCode: DWORD;
    FResponding: Boolean;
    FUnresponsiveSince: UInt64;
    FSuspended: Boolean;
    FExpectingExit: Boolean;
    FLastError: string;
    FRestartCount: Integer;
    FRestartHistory: TList<UInt64>;
    FPreLaunchWindows: TDictionary<HWND, Boolean>;
    FTreePids: TProcessIdArray;
    FDiscovering: Boolean;
    FDiscoveryDeadline: UInt64;
    FCloseRequested: Boolean;
    FCloseDeadline: UInt64;
    FRestartPending: Boolean;
    FRestartAt: UInt64;
    FPendingRestartReason: TDockRestartReason;
    FRestartAfterExit: Boolean;
    FRestartAfterExitReason: TDockRestartReason;
    FSettleUntil: UInt64;
    FInRestart: Boolean;
    FShuttingDown: Boolean;

    // Events
    FOnStateChange: TNotifyEvent;
    FOnFindWindow: TDockFindWindowEvent;
    FOnDocked: TNotifyEvent;
    FOnUndocked: TNotifyEvent;
    FOnDockFailed: TDockFailedEvent;
    FOnHung: TDockHungEvent;
    FOnResponding: TDockHangInfoEvent;
    FOnEmergencyKill: TDockHangInfoEvent;
    FOnBeforeKill: TDockBeforeKillEvent;
    FOnBeforeRestart: TDockBeforeRestartEvent;
    FOnProcessExit: TDockProcessExitEvent;
    FOnTitleChange: TDockTextEvent;
    FOnLog: TDockTextEvent;

    procedure SetHostControl(const AValue: TWinControl);
    procedure SetColor(const AValue: TColor);
    procedure SetShowStatusText(const AValue: Boolean);
    procedure SetHangDetection(const AValue: Boolean);
    procedure SetHangTimeoutMs(const AValue: Cardinal);
    procedure SetPollIntervalMs(const AValue: Cardinal);
    procedure SetEmergencyKillTimeoutMs(const AValue: Cardinal);
    procedure SetEmergencyWatchWindow(const AValue: HWND);
    procedure WatchdogSettingsChanged;
    function GetIsRunning: Boolean;
    function GetEffectiveHangTimeoutMs: Cardinal;

    // Container / parking
    function ResolveHost: TWinControl;
    procedure EnsureContainer;
    procedure EnsureParkingWindow;
    procedure ContainerHandleCreated;
    procedure ContainerHandleDestroying;
    procedure ContainerDestroyed;
    procedure ParkWindow;
    function StatusText: string;

    // Launch & discovery
    function BuildCommandLine: string;
    procedure SnapshotPreLaunchWindows;
    procedure LaunchWithCreateProcess(out AElevationRequired: Boolean);
    procedure LaunchWithShellExecute(AElevated: Boolean);
    procedure DiscoverStep;
    function IsIgnoredWindowClass(const AClassName: string): Boolean;
    function EvaluateCandidate(AWnd: HWND; out ACandidate: TDockWindowCandidate): Boolean;
    function FindDockableWindow(out ACandidate: TDockWindowCandidate): Boolean;
    procedure AttachToWindow(const ACandidate: TDockWindowCandidate);
    procedure FailStart(const AReason: string);

    // Docking
    procedure SaveOriginalWindowState;
    procedure RestoreOriginalWindow(AShow: Boolean);
    function BuildDockError(AErrorCode: DWORD): string;

    // Session lifetime
    function BuildKillTargets: TKillTargets;
    function IsSessionAlive: Boolean;
    function OwnProcessesAlive: Boolean;
    function WaitForSessionEnd(ATimeoutMs: Cardinal): Boolean;
    procedure PostCloseMessage;
    function KillInternal: Boolean;
    function CloseGracefullyInternal(ATimeoutMs: Cardinal): Boolean;
    procedure HandleSessionEnded(AExpected: Boolean);
    procedure CloseSessionHandles;
    procedure ResetSession;
    function ReadExitCode: DWORD;
    procedure ScheduleRestart(AReason: TDockRestartReason; ADelayMs: Cardinal);
    function IsRestartLimitReached: Boolean;

    // Watchdog
    procedure StartWatchdog;
    procedure StopWatchdog;
    function IsCurrentWatchdog(AId: Integer): Boolean;
    procedure HandleWatchdogSessionEnded(AId: Integer);
    procedure HandleWatchdogHung(AId: Integer; AUnresponsiveMs: Cardinal);
    procedure HandleWatchdogResponding(AId: Integer; AUnresponsiveMs: Cardinal);
    procedure HandleWatchdogTitle(AId: Integer; const ATitle: string);
    procedure HandleWatchdogEmergencyKill(AId: Integer; AUnresponsiveMs: Cardinal; AKilled: Boolean);
    procedure ProcessHang(AUnresponsiveMs: Cardinal);
    procedure ProcessResponding(AUnresponsiveMs: Cardinal);
    procedure ProcessTitle(const ATitle: string);
    procedure ProcessEmergencyKill(AUnresponsiveMs: Cardinal; AKilled: Boolean);

    // Broker (host side)
    function NeedsBrokerFor(AElevate: Boolean): Boolean;
    function BrokerSignature(AElevated: Boolean): string;
    function BuildBrokerSettings(AElevated: Boolean): string;
    procedure EnsureBrokerLink;
    procedure StartViaBroker(AElevated: Boolean);
    procedure LaunchBroker(AElevated: Boolean; const ASettings: string);
    procedure ReleaseBroker;
    function IsBrokerAlive: Boolean;
    procedure BrokerCommand(ACommand: Word; AArgument: LPARAM = 0);
    procedure BrokerLinkWndProc(var AMessage: TMessage);
    function HandleBrokerData(ASender: HWND; const AData: TCopyDataStruct): LRESULT;
    procedure ProcessBrokerEvents;
    procedure ProcessBrokerEvent(AEvent: Integer; AFields: TStrings);

    // Timer
    procedure TimerTick(Sender: TObject);
    procedure UpdateTimer;
    procedure EnforceDockedLayout;

    // Event helpers
    function CanFireEvents: Boolean;
    procedure SetState(AState: TProcessDockerState);
    procedure Log(const AMessage: string); overload;
    procedure Log(const AFormat: string; const AArgs: array of const); overload;
    procedure DoDocked;
    procedure DoUndocked;
    procedure DoDockFailed(const AReason: string);
    function DoBeforeKill(AReason: TDockKillReason): Boolean;
    function DoBeforeRestart(AReason: TDockRestartReason): Boolean;
  protected
    procedure Notification(AComponent: TComponent; AOperation: TOperation); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    class function PresetInfo(APreset: TDockPreset): TDockPresetInfo;
    class function IsHostElevated: Boolean;
    /// <summary>The time Windows waits before it calls a window "Not responding".</summary>
    class function SystemHungAppTimeoutMs: Cardinal;

    /// <summary>Sets FileName, Parameters and window search options for a known application.</summary>
    procedure ApplyPreset(APreset: TDockPreset);

    /// <summary>
    ///   Starts the process. Window discovery and docking are asynchronous: watch
    ///   OnDocked / OnDockFailed. Raises EProcessDocker if the process can not be started.
    /// </summary>
    procedure Start;
    /// <summary>Posts WM_CLOSE and waits (pumping only sent messages). Does not kill.</summary>
    function CloseGracefully(ATimeoutMs: Cardinal = 0): Boolean;
    /// <summary>Posts WM_CLOSE and returns. Kills after CloseTimeoutMs if KillAfterCloseTimeout.</summary>
    procedure RequestClose;
    /// <summary>Terminates the process (tree / job). Fires OnBeforeKill.</summary>
    function Kill: Boolean; overload;
    function Kill(AReason: TDockKillReason): Boolean; overload;
    /// <summary>CloseGracefully, then Kill if it did not close in CloseTimeoutMs.</summary>
    procedure Stop;
    /// <summary>Stops (or kills when hung) and starts again. Fires OnBeforeRestart.</summary>
    function Restart(AReason: TDockRestartReason = drrManual): Boolean;

    /// <summary>Docks the found window into HostControl (done automatically after Start).</summary>
    function Dock: Boolean;
    /// <summary>Restores the window as a normal top level window. The process keeps running.</summary>
    procedure Undock;

    /// <summary>Suspends every process of the session. Useful to simulate a hang.</summary>
    function SuspendProcess: Boolean;
    function ResumeProcess: Boolean;

    /// <summary>
    ///   Posts the text as WM_CHAR messages to the docked window. Works with classic
    ///   console windows (conhost), best effort for anything else.
    /// </summary>
    procedure SendTextInput(const AText: string; AAppendEnter: Boolean = False);
    procedure FocusDockedWindow;
    /// <summary>Resizes the docked window to the container (called automatically).</summary>
    procedure UpdateLayout(AForce: Boolean = False);
    function GetInfo: TDockedProcessInfo;

    property State: TProcessDockerState read FState;
    property IsRunning: Boolean read GetIsRunning;
    property IsDocked: Boolean read FIsDocked;
    property IsResponding: Boolean read FResponding;
    property IsSuspended: Boolean read FSuspended;
    property WindowHandle: HWND read FDockedWnd;
    property WindowTitle: string read FTitle;
    property LaunchedProcessId: DWORD read FLaunchedPid;
    property WindowProcessId: DWORD read FWindowPid;
    property ExitCode: DWORD read FExitCode;
    property RestartCount: Integer read FRestartCount;
    property LastError: string read FLastError;
    property Container: TProcessDockContainer read FContainer;
    property EffectiveHangTimeoutMs: Cardinal read GetEffectiveHangTimeoutMs;
    /// <summary>
    ///   The docked window as it was before docking: window and client rect (screen
    ///   coordinates) and style. Valid once OnDocked has fired.
    /// </summary>
    property OriginalWindowRect: TRect read FOriginalRect;
    property OriginalClientRect: TRect read FOriginalClientRect;
    property OriginalWindowStyle: NativeInt read FOriginalStyle;
    /// <summary>True when the current / last process runs through the elevated broker.</summary>
    property IsBrokered: Boolean read FBrokerActive;
    /// <summary>
    ///   Advanced: a window of another process whose UI is watched for the emergency kill
    ///   as well (the broker sets the host form here). 0 = none.
    /// </summary>
    property EmergencyWatchWindow: HWND read FEmergencyWatchWindow write SetEmergencyWatchWindow;
    /// <summary>Advanced: replaces the broker launch (ShellExecuteEx "runas" / CreateProcess).</summary>
    class property BrokerLaunchHook: TDockBrokerLaunchHook read FBrokerLaunchHook write FBrokerLaunchHook;
  published
    /// <summary>Form, panel, tab sheet... the docked window fills it. Defaults to Owner when it is a TWinControl.</summary>
    property HostControl: TWinControl read FHostControl write SetHostControl;

    property FileName: string read FFileName write FFileName;
    property Parameters: string read FParameters write FParameters;
    property WorkingDirectory: string read FWorkingDirectory write FWorkingDirectory;
    /// <summary>
    ///   Start with the "runas" verb (UAC). Note: Windows (UIPI) does not allow a non
    ///   elevated host to dock an elevated window; the host has to be elevated too.
    /// </summary>
    property RunElevated: Boolean read FRunElevated write FRunElevated default False;
    /// <summary>Ask the process to start with a hidden window (less flicker). Not all apps honour it.</summary>
    property StartHidden: Boolean read FStartHidden write FStartHidden default True;
    /// <summary>Only dock a window of this class (e.g. ConsoleWindowClass). Empty = any.</summary>
    property WindowClassName: string read FWindowClassName write FWindowClassName;
    /// <summary>Only dock a window owned by this exe (e.g. WindowsTerminal.exe). Empty = any.</summary>
    property WindowProcessName: string read FWindowProcessName write FWindowProcessName;
    /// <summary>
    ///   Also accept new windows (matching WindowClassName / WindowProcessName) from processes
    ///   that are not part of the started process tree. Needed for launchers like wt.exe.
    /// </summary>
    property AcceptForeignWindows: Boolean read FAcceptForeignWindows write FAcceptForeignWindows default False;
    property FindWindowTimeoutMs: Cardinal read FFindWindowTimeoutMs write FFindWindowTimeoutMs default 10000;

    /// <summary>Make the docked window a real WS_CHILD. Recommended, some apps behave better without.</summary>
    property UseChildStyle: Boolean read FUseChildStyle write FUseChildStyle default True;
    property RemoveWindowFrame: Boolean read FRemoveWindowFrame write FRemoveWindowFrame default True;
    property FocusOnDock: Boolean read FFocusOnDock write FFocusOnDock default True;

    /// <summary>Put started processes into a job object that kills them when the host exits (even on crash).</summary>
    property KillOnHostExit: Boolean read FKillOnHostExit write FKillOnHostExit default True;
    /// <summary>Allow killing the window's process when it was not started by us (e.g. shared Windows Terminal process).</summary>
    property AllowKillForeignProcess: Boolean read FAllowKillForeignProcess write FAllowKillForeignProcess default False;
    property CloseTimeoutMs: Cardinal read FCloseTimeoutMs write FCloseTimeoutMs default 5000;
    property KillAfterCloseTimeout: Boolean read FKillAfterCloseTimeout write FKillAfterCloseTimeout default True;
    property ShutdownAction: TDockShutdownAction read FShutdownAction write FShutdownAction default dsaCloseThenKill;

    property HangDetection: Boolean read FHangDetection write SetHangDetection default True;
    /// <summary>How long the window must be unresponsive to be reported as hung. 0 = Windows' HungAppTimeout (5 s).</summary>
    property HangTimeoutMs: Cardinal read FHangTimeoutMs write SetHangTimeoutMs default 0;
    property PollIntervalMs: Cardinal read FPollIntervalMs write SetPollIntervalMs default 1000;
    /// <summary>Default action when hung. OnHung can change it per case.</summary>
    property HangAction: TDockHangAction read FHangAction write FHangAction default dhaNone;
    /// <summary>
    ///   While the docked window is hung, the watchdog sends heartbeats to the main thread.
    ///   When one is not processed within this time (the host UI is blocked, typically by
    ///   the hung docked window itself through the shared input queue), the watchdog thread
    ///   kills the process. 0 = disabled. No events can veto this kill.
    /// </summary>
    property EmergencyKillTimeoutMs: Cardinal read FEmergencyKillTimeoutMs write SetEmergencyKillTimeoutMs default 0;

    property RestartOnUnexpectedExit: Boolean read FRestartOnUnexpectedExit write FRestartOnUnexpectedExit default False;
    /// <summary>Crash loop protection: max automatic restarts within RestartWindowMs. 0 = unlimited.</summary>
    property MaxRestarts: Integer read FMaxRestarts write FMaxRestarts default 3;
    property RestartWindowMs: Cardinal read FRestartWindowMs write FRestartWindowMs default 60000;
    property RestartDelayMs: Cardinal read FRestartDelayMs write FRestartDelayMs default 1000;

    /// <summary>
    ///   Show an ELEVATED application in this (non elevated) host through an elevated
    ///   broker process. Requires RunProcessDockerBroker (ProcessToFormDocker.Broker) at
    ///   the start of the .dpr, or BrokerFileName.
    /// </summary>
    property BrokerMode: TDockBrokerMode read FBrokerMode write FBrokerMode default dbmOff;
    /// <summary>Broker executable. Empty = this application itself (ParamStr(0)).</summary>
    property BrokerFileName: string read FBrokerFileName write FBrokerFileName;

    property Color: TColor read FColor write SetColor default clBtnFace;
    property ShowStatusText: Boolean read FShowStatusText write SetShowStatusText default True;

    property OnStateChange: TNotifyEvent read FOnStateChange write FOnStateChange;
    /// <summary>Called for every candidate window. Set AAccept to False to skip it.</summary>
    property OnFindWindow: TDockFindWindowEvent read FOnFindWindow write FOnFindWindow;
    property OnDocked: TNotifyEvent read FOnDocked write FOnDocked;
    property OnUndocked: TNotifyEvent read FOnUndocked write FOnUndocked;
    property OnDockFailed: TDockFailedEvent read FOnDockFailed write FOnDockFailed;
    /// <summary>Window has been unresponsive for HangTimeoutMs. Change AAction to decide what happens.</summary>
    property OnHung: TDockHungEvent read FOnHung write FOnHung;
    property OnResponding: TDockHangInfoEvent read FOnResponding write FOnResponding;
    property OnEmergencyKill: TDockHangInfoEvent read FOnEmergencyKill write FOnEmergencyKill;
    property OnBeforeKill: TDockBeforeKillEvent read FOnBeforeKill write FOnBeforeKill;
    /// <summary>AAllow defaults to False when the crash loop limit (MaxRestarts) is reached.</summary>
    property OnBeforeRestart: TDockBeforeRestartEvent read FOnBeforeRestart write FOnBeforeRestart;
    property OnProcessExit: TDockProcessExitEvent read FOnProcessExit write FOnProcessExit;
    property OnTitleChange: TDockTextEvent read FOnTitleChange write FOnTitleChange;
    property OnLog: TDockTextEvent read FOnLog write FOnLog;
  end;

const
  DockerStateNames: array[TProcessDockerState] of string = (
    'Idle', 'Starting', 'Running', 'Closing', 'Exited', 'Failed');

implementation

uses
  Winapi.ShellAPI, System.Math, System.StrUtils, ProcessToFormDocker.Broker;

type
  TProcessDockerLink = class(TInterfacedObject, IProcessDockerLink)
  private
    FDocker: TProcessDocker;
  public
    constructor Create(ADocker: TProcessDocker);
    procedure Detach;
    procedure WatchdogSessionEnded(AWatchdogId: Integer);
    procedure WatchdogHung(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
    procedure WatchdogResponding(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
    procedure WatchdogTitleChanged(AWatchdogId: Integer; const ATitle: string);
    procedure WatchdogEmergencyKill(AWatchdogId: Integer; AUnresponsiveMs: Cardinal; AKilled: Boolean);
    procedure WatchdogHeartbeat(AWatchdogId: Integer);
  end;

const
  PROCESS_QUERY_LIMITED_INFORMATION_ = $1000;
  PM_QS_SENDMESSAGE_ = QS_SENDMESSAGE shl 16;
  ERROR_ELEVATION_REQUIRED_ = 740;
  KILL_WAIT_MS = 3000;
  DOCK_SETTLE_MS = 3000;
  WM_BROKER_EVENTS = WM_APP + $3B0;

  IGNORED_WINDOW_CLASSES: array[0..9] of string = (
    'IME', 'MSCTFIME UI', 'GDI+ Hook Window Class', 'OleMainThreadWndClass', 'tooltips_class32',
    'CicMarshalWndClass', 'PseudoConsoleWindow', 'Shell_TrayWnd', 'ConsoleIMEWindowClass',
    'TaskManagerWindow');

{ Helpers }

function PCharOrNil(const AValue: string): PChar;
begin
  if AValue = '' then
    Result := nil
  else
    Result := PChar(AValue);
end;

function TicksNow: UInt64;
begin
  Result := GetTickCount64;
end;

function MergeProcessIds(const AIds, AMore: TProcessIdArray): TProcessIdArray;
var
  LId: DWORD;
begin
  Result := AIds;
  for LId in AMore do
    if not ContainsProcessId(Result, LId) then
      Result := Result + [LId];
end;

{ TProcessDockerLink }

constructor TProcessDockerLink.Create(ADocker: TProcessDocker);
begin
  inherited Create;
  FDocker := ADocker;
end;

procedure TProcessDockerLink.Detach;
begin
  FDocker := nil;
end;

procedure TProcessDockerLink.WatchdogSessionEnded(AWatchdogId: Integer);
begin
  if Assigned(FDocker) then
    FDocker.HandleWatchdogSessionEnded(AWatchdogId);
end;

procedure TProcessDockerLink.WatchdogHung(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
begin
  if Assigned(FDocker) then
    FDocker.HandleWatchdogHung(AWatchdogId, AUnresponsiveMs);
end;

procedure TProcessDockerLink.WatchdogResponding(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
begin
  if Assigned(FDocker) then
    FDocker.HandleWatchdogResponding(AWatchdogId, AUnresponsiveMs);
end;

procedure TProcessDockerLink.WatchdogTitleChanged(AWatchdogId: Integer; const ATitle: string);
begin
  if Assigned(FDocker) then
    FDocker.HandleWatchdogTitle(AWatchdogId, ATitle);
end;

procedure TProcessDockerLink.WatchdogEmergencyKill(AWatchdogId: Integer; AUnresponsiveMs: Cardinal;
  AKilled: Boolean);
begin
  if Assigned(FDocker) then
    FDocker.HandleWatchdogEmergencyKill(AWatchdogId, AUnresponsiveMs, AKilled);
end;

procedure TProcessDockerLink.WatchdogHeartbeat(AWatchdogId: Integer);
begin
  // Reaching this proves the main thread is alive
  if Assigned(FDocker) and FDocker.IsCurrentWatchdog(AWatchdogId) then
    FDocker.FWatchdog.AcknowledgeHang;
end;

{ TProcessDockContainer }

constructor TProcessDockContainer.Create(ADocker: TProcessDocker);
begin
  inherited Create(nil);
  FDocker := ADocker;
  ControlStyle := ControlStyle + [csOpaque] - [csAcceptsControls, csSetCaption];
  TabStop := True;
  Color := ADocker.Color;
  ParentBackground := False;
end;

destructor TProcessDockContainer.Destroy;
var
  LDocker: TProcessDocker;
begin
  LDocker := FDocker;
  inherited Destroy; // Destroys the handle -> WM_DESTROY parks the docked window
  if Assigned(LDocker) then
    LDocker.ContainerDestroyed;
end;

procedure TProcessDockContainer.CreateParams(var AParams: TCreateParams);
begin
  inherited CreateParams(AParams);
  AParams.Style := AParams.Style or WS_CLIPCHILDREN;
end;

procedure TProcessDockContainer.CreateWnd;
begin
  inherited CreateWnd;
  if Assigned(FDocker) then
    FDocker.ContainerHandleCreated;
end;

procedure TProcessDockContainer.WMDestroy(var AMessage: TWMDestroy);
begin
  // Covers both VCL handle re-creation and the parent form being destroyed:
  // move the foreign window out before Windows destroys it with us.
  if Assigned(FDocker) then
    FDocker.ContainerHandleDestroying;
  inherited;
end;

procedure TProcessDockContainer.WMSetFocus(var AMessage: TWMSetFocus);
begin
  inherited;
  if Assigned(FDocker) then
    FDocker.FocusDockedWindow;
end;

procedure TProcessDockContainer.WMEraseBkgnd(var AMessage: TWMEraseBkgnd);
begin
  AMessage.Result := 1;
end;

procedure TProcessDockContainer.Resize;
begin
  inherited Resize;
  if Assigned(FDocker) then
    FDocker.UpdateLayout(False);
end;

procedure TProcessDockContainer.Paint;
var
  LText: string;
  LRect: TRect;
  LTextRect: TRect;
  LColor: Longint;
  LLuminance: Integer;
begin
  Canvas.Brush.Color := Color;
  Canvas.FillRect(ClientRect);

  if not Assigned(FDocker) then
    Exit;

  LText := FDocker.StatusText;
  if LText = '' then
    Exit;

  LColor := ColorToRGB(Color);
  LLuminance := (GetRValue(LColor) * 299 + GetGValue(LColor) * 587 + GetBValue(LColor) * 114) div 1000;
  Canvas.Font := Font;
  if LLuminance < 128 then
    Canvas.Font.Color := clSilver
  else
    Canvas.Font.Color := clGrayText;
  Canvas.Brush.Style := bsClear;

  LRect := ClientRect;
  InflateRect(LRect, -16, -16);
  LTextRect := LRect;
  DrawText(Canvas.Handle, PChar(LText), Length(LText), LTextRect, DT_CALCRECT or DT_WORDBREAK or DT_CENTER);
  OffsetRect(LTextRect, 0, (LRect.Height - LTextRect.Height) div 2);
  LTextRect.Left := LRect.Left;
  LTextRect.Right := LRect.Right;
  DrawText(Canvas.Handle, PChar(LText), Length(LText), LTextRect, DT_WORDBREAK or DT_CENTER);
end;

{ TProcessDocker }

constructor TProcessDocker.Create(AOwner: TComponent);
var
  LLink: TProcessDockerLink;
begin
  inherited Create(AOwner);

  FStartHidden := True;
  FFindWindowTimeoutMs := 10000;
  FUseChildStyle := True;
  FRemoveWindowFrame := True;
  FFocusOnDock := True;
  FKillOnHostExit := True;
  FCloseTimeoutMs := 5000;
  FKillAfterCloseTimeout := True;
  FShutdownAction := dsaCloseThenKill;
  FHangDetection := True;
  FHangTimeoutMs := 0;
  FPollIntervalMs := 1000;
  FHangAction := dhaNone;
  FEmergencyKillTimeoutMs := 0;
  FMaxRestarts := 3;
  FRestartWindowMs := 60000;
  FRestartDelayMs := 1000;
  FColor := clBtnFace;
  FShowStatusText := True;

  FState := pdsIdle;
  FResponding := True;
  FRestartHistory := TList<UInt64>.Create;
  FPreLaunchWindows := TDictionary<HWND, Boolean>.Create;
  FBrokerPending := TList<TPair<Word, LPARAM>>.Create;
  FBrokerEvents := TList<TPair<Integer, string>>.Create;

  LLink := TProcessDockerLink.Create(Self);
  FLinkObject := LLink;
  FLink := LLink;

  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 100;
  FTimer.OnTimer := TimerTick;
end;

destructor TProcessDocker.Destroy;
begin
  FShuttingDown := True;
  TProcessDockerLink(FLinkObject).Detach;

  if not (csDesigning in ComponentState) then
  try
    if IsBrokerAlive then
    begin
      // We may not touch the elevated process: the broker applies the shutdown action
      if FState in [pdsStarting, pdsRunning, pdsClosing] then
        BrokerCommand(BROKER_CMD_SHUTDOWN, Ord(FShutdownAction))
      else
        BrokerCommand(BROKER_CMD_SHUTDOWN, Ord(dsaKill));
    end
    else if FState in [pdsStarting, pdsRunning, pdsClosing] then
      case FShutdownAction of
        dsaCloseThenKill:
          if not CloseGracefullyInternal(FCloseTimeoutMs) then
            KillInternal;
        dsaKill:
          KillInternal;
        dsaCloseOnly:
          begin
            StopWatchdog;
            RestoreOriginalWindow(True);
            PostCloseMessage;
            ReleaseKillOnCloseJob(FJob);
          end;
        dsaUndockAndLeave:
          begin
            StopWatchdog;
            RestoreOriginalWindow(True);
            ReleaseKillOnCloseJob(FJob);
          end;
      end;
  except
    // Never raise from a destructor
  end;

  StopWatchdog;

  if Assigned(FContainer) then
  begin
    FContainer.FDocker := nil;
    FreeAndNil(FContainer);
  end;

  CloseSessionHandles;

  if FParkingWnd <> 0 then
  begin
    DeallocateHWnd(FParkingWnd);
    FParkingWnd := 0;
  end;

  if FBrokerProcess <> 0 then
  begin
    CloseHandle(FBrokerProcess);
    FBrokerProcess := 0;
  end;
  // A broker that never got our shutdown command quits (and kills) when this window is gone
  if FBrokerLinkWnd <> 0 then
  begin
    DeallocateHWnd(FBrokerLinkWnd);
    FBrokerLinkWnd := 0;
  end;

  FLink := nil;
  FRestartHistory.Free;
  FPreLaunchWindows.Free;
  FBrokerPending.Free;
  FBrokerEvents.Free;

  inherited Destroy;
end;

procedure TProcessDocker.Notification(AComponent: TComponent; AOperation: TOperation);
begin
  inherited Notification(AComponent, AOperation);
  if (AOperation = opRemove) and (AComponent = FHostControl) then
    FHostControl := nil;
end;

class function TProcessDocker.PresetInfo(APreset: TDockPreset): TDockPresetInfo;
var
  LConHost: string;
begin
  Result := Default(TDockPresetInfo);
  // conhost.exe <app> forces the classic console window even when Windows Terminal is the
  // default terminal application (Windows 11 would otherwise hand the console over to it).
  LConHost := IncludeTrailingPathDelimiter(GetNativeSystemDirectory) + 'conhost.exe';

  case APreset of
    dpClassicCmd:
      begin
        Result.Caption := 'Classic cmd.exe (conhost)';
        Result.FileName := LConHost;
        Result.Parameters := 'cmd.exe';
        Result.WindowClassName := 'ConsoleWindowClass';
      end;
    dpClassicPowerShell:
      begin
        Result.Caption := 'Windows PowerShell (conhost)';
        Result.FileName := LConHost;
        Result.Parameters := 'powershell.exe -NoLogo';
        Result.WindowClassName := 'ConsoleWindowClass';
      end;
    dpPowerShell7:
      begin
        Result.Caption := 'PowerShell 7 (conhost)';
        Result.FileName := LConHost;
        Result.Parameters := 'pwsh.exe -NoLogo';
        Result.WindowClassName := 'ConsoleWindowClass';
      end;
    dpWindowsTerminal:
      begin
        Result.Caption := 'Windows Terminal';
        Result.FileName := 'wt.exe';
        Result.Parameters := '-w new';
        Result.WindowClassName := 'CASCADIA_HOSTING_WINDOW_CLASS';
        // wt.exe is a launcher, the window may come from an already running WindowsTerminal.exe
        Result.AcceptForeignWindows := True;
      end;
    dpNotepad:
      begin
        Result.Caption := 'Notepad';
        Result.FileName := 'notepad.exe';
        Result.WindowClassName := 'Notepad';
        // Windows 11 Notepad is a Store app and may be activated outside our process tree.
        // NOTE: tested on Windows 11 (build 26300): the Store Notepad crashes
        // (0xC000027B) as soon as it is re-parented. Kept as an example of an app
        // that can not be docked - always test the app you want to dock.
        Result.AcceptForeignWindows := True;
      end;
  end;
end;

procedure TProcessDocker.ApplyPreset(APreset: TDockPreset);
var
  LInfo: TDockPresetInfo;
begin
  LInfo := PresetInfo(APreset);
  FFileName := LInfo.FileName;
  FParameters := LInfo.Parameters;
  FWindowClassName := LInfo.WindowClassName;
  FWindowProcessName := LInfo.WindowProcessName;
  FAcceptForeignWindows := LInfo.AcceptForeignWindows;
end;

class function TProcessDocker.IsHostElevated: Boolean;
begin
  Result := IsCurrentProcessElevated;
end;

class function TProcessDocker.SystemHungAppTimeoutMs: Cardinal;
begin
  Result := GetSystemHungAppTimeout;
end;

function TProcessDocker.GetEffectiveHangTimeoutMs: Cardinal;
begin
  if FHangTimeoutMs = 0 then
    Result := GetSystemHungAppTimeout
  else
    Result := FHangTimeoutMs;
end;

function TProcessDocker.GetIsRunning: Boolean;
begin
  Result := FState in [pdsStarting, pdsRunning, pdsClosing];
end;

procedure TProcessDocker.SetHostControl(const AValue: TWinControl);
begin
  if FHostControl = AValue then
    Exit;

  if Assigned(FHostControl) then
    FHostControl.RemoveFreeNotification(Self);

  FHostControl := AValue;

  if Assigned(FHostControl) then
  begin
    FHostControl.FreeNotification(Self);
    // Moving the container destroys and re-creates its handle; the docked window is
    // parked meanwhile and re-docked in the new parent.
    if Assigned(FContainer) then
      FContainer.Parent := FHostControl;
  end;
end;

procedure TProcessDocker.SetColor(const AValue: TColor);
begin
  FColor := AValue;
  if Assigned(FContainer) then
    FContainer.Color := AValue;
end;

procedure TProcessDocker.SetShowStatusText(const AValue: Boolean);
begin
  FShowStatusText := AValue;
  if Assigned(FContainer) then
    FContainer.Invalidate;
end;

procedure TProcessDocker.SetEmergencyWatchWindow(const AValue: HWND);
begin
  if FEmergencyWatchWindow <> AValue then
  begin
    FEmergencyWatchWindow := AValue;
    WatchdogSettingsChanged;
  end;
end;

procedure TProcessDocker.WatchdogSettingsChanged;
begin
  // Settings are copied to the watchdog thread when it starts, so start a new one
  if Assigned(FWatchdog) then
    StartWatchdog;
end;

procedure TProcessDocker.SetHangDetection(const AValue: Boolean);
begin
  if FHangDetection <> AValue then
  begin
    FHangDetection := AValue;
    WatchdogSettingsChanged;
  end;
end;

procedure TProcessDocker.SetHangTimeoutMs(const AValue: Cardinal);
begin
  if FHangTimeoutMs <> AValue then
  begin
    FHangTimeoutMs := AValue;
    WatchdogSettingsChanged;
  end;
end;

procedure TProcessDocker.SetPollIntervalMs(const AValue: Cardinal);
begin
  if FPollIntervalMs <> AValue then
  begin
    FPollIntervalMs := AValue;
    WatchdogSettingsChanged;
  end;
end;

procedure TProcessDocker.SetEmergencyKillTimeoutMs(const AValue: Cardinal);
begin
  if FEmergencyKillTimeoutMs <> AValue then
  begin
    FEmergencyKillTimeoutMs := AValue;
    WatchdogSettingsChanged;
  end;
end;

{ Container & parking }

function TProcessDocker.ResolveHost: TWinControl;
begin
  Result := FHostControl;
  if not Assigned(Result) and (Owner is TWinControl) then
    Result := TWinControl(Owner);
end;

procedure TProcessDocker.EnsureContainer;
var
  LHost: TWinControl;
begin
  if not Assigned(FContainer) then
  begin
    LHost := ResolveHost;
    if not Assigned(LHost) then
      raise EProcessDocker.Create('TProcessDocker: HostControl is not assigned');

    FContainer := TProcessDockContainer.Create(Self);
    FContainer.Align := alClient;
    FContainer.Parent := LHost;
  end;

  FContainer.HandleNeeded;
end;

procedure TProcessDocker.EnsureParkingWindow;
begin
  if FParkingWnd = 0 then
    FParkingWnd := AllocateHWnd(nil);
end;

procedure TProcessDocker.ParkWindow;
begin
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;

  EnsureParkingWindow;
  ShowWindowAsync(FDockedWnd, SW_HIDE);
  Winapi.Windows.SetParent(FDockedWnd, FParkingWnd);
  FIsDocked := False;
  FIsParked := True;
end;

procedure TProcessDocker.ContainerHandleDestroying;
begin
  // Through a broker the window is the broker's: it parks it itself
  if FIsDocked and not FBrokerActive then
    ParkWindow;
end;

procedure TProcessDocker.ContainerHandleCreated;
begin
  if FBrokerActive then
  begin
    // The broker's panel died with our old container window: tell it the new one
    if IsRunning and Assigned(FContainer) then
      BrokerCommand(BROKER_CMD_CONTAINER, LPARAM(FContainer.Handle));
    Exit;
  end;

  if not FIsParked then
    Exit;

  FIsParked := False;
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;

  Winapi.Windows.SetParent(FDockedWnd, FContainer.Handle);
  FIsDocked := True;
  UpdateLayout(True);
end;

procedure TProcessDocker.ContainerDestroyed;
begin
  FContainer := nil;
end;

function TProcessDocker.StatusText: string;
begin
  Result := '';
  if not FShowStatusText then
    Exit;

  case FState of
    pdsIdle:
      Result := 'Not started';
    pdsStarting:
      if FBrokerActive and (FBrokerWnd = 0) then
        Result := Format('Starting %s %s through the elevated broker ...', [ExtractFileName(FFileName), FParameters])
      else
        Result := Format('Starting %s %s ...', [ExtractFileName(FFileName), FParameters]);
    pdsRunning:
      if FIsDocked then
        Result := ''
      else if FLastError <> '' then
        Result := FLastError
      else
        Result := 'Running in its own window (undocked)';
    pdsClosing:
      Result := 'Closing ...';
    pdsExited:
      Result := Format('Process exited (exit code %u)', [FExitCode]);
    pdsFailed:
      Result := FLastError;
  end;
end;

{ Launch & discovery }

function TProcessDocker.BuildCommandLine: string;
begin
  Result := Trim(FFileName);
  if (Pos(' ', Result) > 0) and (Result[1] <> '"') then
    Result := '"' + Result + '"';
  if FParameters <> '' then
    Result := Result + ' ' + FParameters;
end;

procedure TProcessDocker.SnapshotPreLaunchWindows;
var
  LWnd: HWND;
begin
  FPreLaunchWindows.Clear;
  for LWnd in GetTopLevelWindows do
    FPreLaunchWindows.AddOrSetValue(LWnd, True);
end;

procedure TProcessDocker.LaunchWithCreateProcess(out AElevationRequired: Boolean);
var
  LStartupInfo: TStartupInfo;
  LProcessInfo: TProcessInformation;
  LCommandLine: string;
  LFlags: DWORD;
  LError: DWORD;
begin
  AElevationRequired := False;

  LCommandLine := BuildCommandLine;
  UniqueString(LCommandLine);

  LStartupInfo := Default(TStartupInfo);
  LStartupInfo.cb := SizeOf(LStartupInfo);
  LStartupInfo.dwFlags := STARTF_USESHOWWINDOW;
  if FStartHidden then
    LStartupInfo.wShowWindow := SW_HIDE
  else
    LStartupInfo.wShowWindow := SW_SHOWNORMAL;

  LFlags := CREATE_NEW_CONSOLE or CREATE_DEFAULT_ERROR_MODE;

  if FKillOnHostExit then
  begin
    FJob := CreateKillOnCloseJob;
    if FJob <> 0 then
      LFlags := LFlags or CREATE_SUSPENDED
    else
      Log('Could not create job object: %s', [SysErrorMessage(GetLastError)]);
  end;

  LProcessInfo := Default(TProcessInformation);
  if not CreateProcess(nil, PChar(LCommandLine), nil, nil, False, LFlags, nil,
    PCharOrNil(FWorkingDirectory), LStartupInfo, LProcessInfo) then
  begin
    LError := GetLastError;
    if FJob <> 0 then
    begin
      CloseHandle(FJob);
      FJob := 0;
    end;

    if LError = ERROR_ELEVATION_REQUIRED_ then
    begin
      AElevationRequired := True;
      Exit;
    end;

    raise EProcessDocker.CreateFmt('Could not start "%s": %s', [LCommandLine, SysErrorMessage(LError)]);
  end;

  if FJob <> 0 then
  begin
    if not AssignProcessToJob(FJob, LProcessInfo.hProcess) then
    begin
      Log('Could not assign process to job object: %s', [SysErrorMessage(GetLastError)]);
      CloseHandle(FJob);
      FJob := 0;
    end;
    ResumeThread(LProcessInfo.hThread);
  end;

  CloseHandle(LProcessInfo.hThread);
  FLaunchedProcess := LProcessInfo.hProcess;
  FLaunchedPid := LProcessInfo.dwProcessId;
  FLaunchedElevated := IsCurrentProcessElevated;
end;

procedure TProcessDocker.LaunchWithShellExecute(AElevated: Boolean);
var
  LInfo: TShellExecuteInfo;
  LForm: TCustomForm;
  LError: DWORD;
begin
  LInfo := Default(TShellExecuteInfo);
  LInfo.cbSize := SizeOf(LInfo);
  LInfo.fMask := SEE_MASK_NOCLOSEPROCESS or SEE_MASK_NOASYNC;
  if AElevated then
    LInfo.lpVerb := 'runas';
  LInfo.lpFile := PChar(FFileName);
  LInfo.lpParameters := PCharOrNil(FParameters);
  LInfo.lpDirectory := PCharOrNil(FWorkingDirectory);
  if FStartHidden then
    LInfo.nShow := SW_HIDE
  else
    LInfo.nShow := SW_SHOWNORMAL;

  if Assigned(FContainer) then
  begin
    LForm := GetParentForm(FContainer);
    if Assigned(LForm) and LForm.HandleAllocated then
      LInfo.Wnd := LForm.Handle;
  end;

  if not ShellExecuteEx(@LInfo) then
  begin
    LError := GetLastError;
    if LError = ERROR_CANCELLED then
      raise EProcessDocker.CreateFmt('Starting "%s" elevated was cancelled by the user', [FFileName]);
    raise EProcessDocker.CreateFmt('Could not start "%s": %s', [FFileName, SysErrorMessage(LError)]);
  end;

  FLaunchedProcess := LInfo.hProcess;
  FLaunchedPid := GetProcessIdOfHandle(LInfo.hProcess);
  FLaunchedElevated := AElevated or IsCurrentProcessElevated;
  if AElevated and FKillOnHostExit then
    Log('KillOnHostExit is not available for processes started elevated from a non elevated host');
end;

procedure TProcessDocker.Start;
var
  LElevationRequired: Boolean;
  LElevate: Boolean;
begin
  if IsRunning then
    raise EProcessDocker.Create('TProcessDocker: a process is already running');
  if Trim(FFileName) = '' then
    raise EProcessDocker.Create('TProcessDocker: FileName is empty');

  EnsureContainer;
  StopWatchdog;
  CloseSessionHandles;
  ResetSession;
  SnapshotPreLaunchWindows;

  Log('Starting: %s', [BuildCommandLine]);
  SetState(pdsStarting);
  try
    LElevate := FRunElevated and not IsCurrentProcessElevated;
    if NeedsBrokerFor(LElevate) then
      StartViaBroker(LElevate)
    else if LElevate then
      LaunchWithShellExecute(True)
    else
    begin
      LaunchWithCreateProcess(LElevationRequired);
      if LElevationRequired then
      begin
        if NeedsBrokerFor(True) then
        begin
          Log('The executable requires elevation, starting it through an elevated broker');
          StartViaBroker(True);
        end
        else
        begin
          Log('The executable requires elevation, starting it with "runas"');
          LaunchWithShellExecute(True);
        end;
      end;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      FBrokerSessionAlive := False;
      SetState(pdsFailed);
      raise;
    end;
  end;

  FStartTime := Now;
  if FBrokerActive then
  begin
    // The broker starts and docks it, and reports back
    UpdateTimer;
    Exit;
  end;
  FTreePids := [FLaunchedPid];
  Log('Process started, pid %d', [FLaunchedPid]);

  FDiscovering := True;
  FDiscoveryDeadline := TicksNow + FFindWindowTimeoutMs;
  UpdateTimer;
  DiscoverStep;
end;

function TProcessDocker.IsIgnoredWindowClass(const AClassName: string): Boolean;
var
  LClass: string;
begin
  for LClass in IGNORED_WINDOW_CLASSES do
    if SameText(LClass, AClassName) then
      Exit(True);
  Result := False;
end;

function TProcessDocker.EvaluateCandidate(AWnd: HWND; out ACandidate: TDockWindowCandidate): Boolean;
var
  LStyle: NativeInt;
  LExStyle: NativeInt;
  LPid: DWORD;
begin
  Result := False;
  ACandidate := Default(TDockWindowCandidate);

  LPid := GetWindowProcessId(AWnd);
  if (LPid = 0) or (LPid = GetCurrentProcessId) then
    Exit;

  LStyle := GetWindowLongPtr(AWnd, GWL_STYLE);
  LExStyle := GetWindowLongPtr(AWnd, GWL_EXSTYLE);
  if (LStyle and WS_CHILD) <> 0 then
    Exit;
  if (LExStyle and WS_EX_TOOLWINDOW) <> 0 then
    Exit;
  if GetWindow(AWnd, GW_OWNER) <> 0 then
    Exit;

  ACandidate.Handle := AWnd;
  ACandidate.ProcessId := LPid;
  ACandidate.Visible := IsWindowVisible(AWnd);

  // Hidden windows are only interesting when we asked for a hidden start, and then
  // only when they look like a main window.
  if not ACandidate.Visible then
    if not FStartHidden or ((LStyle and WS_CAPTION) <> WS_CAPTION) then
      Exit;

  ACandidate.ClassName := GetWindowClassNameStr(AWnd);
  if IsIgnoredWindowClass(ACandidate.ClassName) then
    Exit;

  ACandidate.InProcessTree := ContainsProcessId(FTreePids, LPid);
  if not ACandidate.InProcessTree then
  begin
    if not FAcceptForeignWindows then
      Exit;
    // Foreign windows only with a filter, and only when they were created after the launch
    if (FWindowClassName = '') and (FWindowProcessName = '') then
      Exit;
    if FPreLaunchWindows.ContainsKey(AWnd) then
      Exit;
  end;

  if (FWindowClassName <> '') and not SameText(ACandidate.ClassName, FWindowClassName) then
    Exit;

  ACandidate.ProcessName := GetProcessImageName(LPid);
  if (FWindowProcessName <> '') and not SameText(ACandidate.ProcessName, FWindowProcessName) then
    Exit;

  ACandidate.Title := GetWindowTextStr(AWnd);
  Result := True;

  if Assigned(FOnFindWindow) and CanFireEvents then
    FOnFindWindow(Self, ACandidate, Result);
end;

function TProcessDocker.FindDockableWindow(out ACandidate: TDockWindowCandidate): Boolean;
var
  LWnd: HWND;
  LCandidate: TDockWindowCandidate;
  LHidden: TDockWindowCandidate;
  LHaveHidden: Boolean;
begin
  Result := False;
  LHaveHidden := False;
  LHidden := Default(TDockWindowCandidate);

  for LWnd in GetTopLevelWindows do
    if EvaluateCandidate(LWnd, LCandidate) then
    begin
      if LCandidate.Visible then
      begin
        ACandidate := LCandidate;
        Exit(True);
      end;

      if not LHaveHidden then
      begin
        LHidden := LCandidate;
        LHaveHidden := True;
      end;
    end;

  if LHaveHidden then
  begin
    ACandidate := LHidden;
    Result := True;
  end;
end;

procedure TProcessDocker.DiscoverStep;
var
  LCandidate: TDockWindowCandidate;
begin
  if not FDiscovering then
    Exit;

  // Keep the dead launcher PIDs as seeds: children of an exited launcher still point to it
  FTreePids := MergeProcessIds(FTreePids, GetDescendantProcessIds(FTreePids));

  if FindDockableWindow(LCandidate) then
  begin
    FDiscovering := False;
    UpdateTimer;
    AttachToWindow(LCandidate);
    Exit;
  end;

  if TicksNow >= FDiscoveryDeadline then
  begin
    FDiscovering := False;
    UpdateTimer;
    FailStart(Format('No dockable window appeared within %d ms', [FFindWindowTimeoutMs]));
    Exit;
  end;

  if not FAcceptForeignWindows and not IsSessionAlive then
  begin
    FDiscovering := False;
    UpdateTimer;
    FExitCode := ReadExitCode;
    FailStart(Format('Process exited before its window appeared (exit code %u)', [FExitCode]));
  end;
end;

procedure TProcessDocker.FailStart(const AReason: string);
begin
  FLastError := AReason;
  Log(AReason);

  if IsSessionAlive then
  begin
    // Leave it running, but visible, so the user can still use or kill it
    SetState(pdsRunning);
    if FLaunchedProcess <> 0 then
      StartWatchdog;
  end
  else
  begin
    CloseSessionHandles;
    SetState(pdsFailed);
  end;

  DoDockFailed(AReason);
end;

procedure TProcessDocker.AttachToWindow(const ACandidate: TDockWindowCandidate);
begin
  FDockedWnd := ACandidate.Handle;
  FWindowPid := ACandidate.ProcessId;
  FWindowIsForeign := not ACandidate.InProcessTree;
  FWindowProcessNameFound := ACandidate.ProcessName;
  FWindowClassFound := ACandidate.ClassName;
  FTitle := ACandidate.Title;
  FHaveOriginal := False;

  FWindowProcess := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION_ or PROCESS_TERMINATE,
    False, FWindowPid);
  if FWindowProcess = 0 then
    FWindowProcess := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION_, False, FWindowPid);

  Log('Found window $%x "%s" (class %s, pid %d %s%s)', [FDockedWnd, FTitle, FWindowClassFound, FWindowPid,
    FWindowProcessNameFound, IfThen(FWindowIsForeign, ', not started by us', '')]);

  SetState(pdsRunning);

  if not Dock then
  begin
    // Make sure a hidden started window does not stay invisible
    if not IsWindowVisible(FDockedWnd) then
      ShowWindow(FDockedWnd, SW_SHOWNORMAL);
  end;

  StartWatchdog;
end;

{ Docking }

procedure TProcessDocker.SaveOriginalWindowState;
begin
  FOriginalStyle := GetWindowLongPtr(FDockedWnd, GWL_STYLE);
  FOriginalExStyle := GetWindowLongPtr(FDockedWnd, GWL_EXSTYLE);
  FOriginalParent := Winapi.Windows.GetParent(FDockedWnd);
  if FOriginalParent = GetDesktopWindow then
    FOriginalParent := 0;
  GetWindowRect(FDockedWnd, FOriginalRect);
  // Client area in screen coordinates
  GetClientRect(FDockedWnd, FOriginalClientRect);
  MapWindowPoints(FDockedWnd, 0, FOriginalClientRect, 2);
  FHaveOriginal := True;
end;

function TProcessDocker.BuildDockError(AErrorCode: DWORD): string;
begin
  if (AErrorCode = ERROR_ACCESS_DENIED) and not IsCurrentProcessElevated
    and IsProcessProbablyElevated(FWindowPid) then
    Result := 'Can not dock: the window belongs to an elevated (administrator) process and this ' +
      'application is not elevated. Windows (UIPI) blocks that. Run this application elevated too.'
  else
    Result := Format('Can not dock the window: %s', [SysErrorMessage(AErrorCode)]);
end;

function TProcessDocker.Dock: Boolean;
var
  LStyle: NativeInt;
  LExStyle: NativeInt;
  LError: DWORD;
begin
  Result := False;
  if FIsDocked then
    Exit(True);
  if FBrokerActive then
  begin
    Log('Dock / Undock is not available for an application shown through the broker');
    Exit;
  end;
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;

  EnsureContainer;

  if FIsParked then
  begin
    ContainerHandleCreated;
    Exit(FIsDocked);
  end;

  if not IsCurrentProcessElevated and IsProcessProbablyElevated(FWindowPid) then
  begin
    FLastError := BuildDockError(ERROR_ACCESS_DENIED);
    Log(FLastError);
    DoDockFailed(FLastError);
    FContainer.Invalidate;
    Exit;
  end;

  if not FHaveOriginal then
    SaveOriginalWindowState;

  if IsIconic(FDockedWnd) or IsZoomed(FDockedWnd) then
    ShowWindow(FDockedWnd, SW_RESTORE);

  LStyle := FOriginalStyle;
  LExStyle := FOriginalExStyle and not WS_EX_APPWINDOW;
  if FRemoveWindowFrame then
  begin
    LStyle := LStyle and not (WS_CAPTION or WS_THICKFRAME or WS_SYSMENU or WS_MINIMIZEBOX or WS_MAXIMIZEBOX);
    LExStyle := LExStyle and not (WS_EX_DLGMODALFRAME or WS_EX_WINDOWEDGE or WS_EX_CLIENTEDGE or WS_EX_STATICEDGE);
  end;
  if FUseChildStyle then
    LStyle := (LStyle and not WS_POPUP) or WS_CHILD;
  // No WM_PARENTNOTIFY: it would be sent synchronously to us when the app destroys its window
  LExStyle := LExStyle or WS_EX_NOPARENTNOTIFY;

  // MSDN: clear WS_POPUP and set WS_CHILD before calling SetParent
  SetLastError(0);
  SetWindowLongPtr(FDockedWnd, GWL_STYLE, LStyle);
  LError := GetLastError;
  if LError = 0 then
  begin
    SetWindowLongPtr(FDockedWnd, GWL_EXSTYLE, LExStyle);
    SetLastError(0);
    if Winapi.Windows.SetParent(FDockedWnd, FContainer.Handle) = 0 then
      LError := GetLastError;
  end;

  if LError <> 0 then
  begin
    SetWindowLongPtr(FDockedWnd, GWL_STYLE, FOriginalStyle);
    SetWindowLongPtr(FDockedWnd, GWL_EXSTYLE, FOriginalExStyle);
    FLastError := BuildDockError(LError);
    Log(FLastError);
    DoDockFailed(FLastError);
    FContainer.Invalidate;
    Exit;
  end;

  FIsDocked := True;
  FIsParked := False;
  FLastError := '';
  UpdateLayout(True);

  if FFocusOnDock then
    FocusDockedWindow;

  // Many apps still move / resize / show themselves right after creation (restoring
  // their saved placement etc.). Keep enforcing our layout for a moment.
  FSettleUntil := TicksNow + DOCK_SETTLE_MS;
  UpdateTimer;

  Log('Docked');
  DoDocked;
  Result := True;
end;

procedure TProcessDocker.RestoreOriginalWindow(AShow: Boolean);
var
  LRect: TRect;
  LPoint: TPoint;
  LFlags: UINT;
begin
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) or not (FIsDocked or FIsParked) then
    Exit;

  if FHaveOriginal then
  begin
    SetWindowLongPtr(FDockedWnd, GWL_STYLE, FOriginalStyle);
    SetWindowLongPtr(FDockedWnd, GWL_EXSTYLE, FOriginalExStyle);
  end;
  Winapi.Windows.SetParent(FDockedWnd, FOriginalParent);

  // Put it where the container was, with the original frame around it
  if Assigned(FContainer) and FContainer.HandleAllocated and IsWindowVisible(FContainer.Handle) then
  begin
    LPoint := FContainer.ClientToScreen(Point(0, 0));
    LRect := Rect(LPoint.X, LPoint.Y, LPoint.X + FContainer.ClientWidth, LPoint.Y + FContainer.ClientHeight);
    AdjustWindowRectEx(LRect, DWORD(FOriginalStyle), False, DWORD(FOriginalExStyle));
  end
  else
    LRect := FOriginalRect;

  LFlags := SWP_FRAMECHANGED or SWP_NOACTIVATE or SWP_ASYNCWINDOWPOS;
  if AShow then
    LFlags := LFlags or SWP_SHOWWINDOW;
  SetWindowPos(FDockedWnd, HWND_TOP, LRect.Left, LRect.Top, LRect.Width, LRect.Height, LFlags);

  FIsDocked := False;
  FIsParked := False;
end;

procedure TProcessDocker.Undock;
begin
  if FBrokerActive then
  begin
    Log('Dock / Undock is not available for an application shown through the broker');
    Exit;
  end;
  if not (FIsDocked or FIsParked) then
    Exit;

  RestoreOriginalWindow(True);
  if (FDockedWnd <> 0) and IsWindow(FDockedWnd) then
    SetForegroundWindow(FDockedWnd);

  Log('Undocked');
  if Assigned(FContainer) then
    FContainer.Invalidate;
  DoUndocked;
end;

procedure TProcessDocker.UpdateLayout(AForce: Boolean);
var
  LFlags: UINT;
begin
  if FBrokerActive then
  begin
    // The broker follows our container size; this just makes it react at once
    if FIsDocked and IsRunning then
      BrokerCommand(BROKER_CMD_LAYOUT);
    Exit;
  end;
  if not FIsDocked or not Assigned(FContainer) or not FContainer.HandleAllocated then
    Exit;
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;
  // Never block on a hung window: SetWindowPos would wait for it
  if (not FResponding or FSuspended) and not AForce then
    Exit;

  LFlags := SWP_NOZORDER or SWP_NOACTIVATE or SWP_ASYNCWINDOWPOS;
  if AForce then
    LFlags := LFlags or SWP_FRAMECHANGED or SWP_SHOWWINDOW;

  SetWindowPos(FDockedWnd, 0, 0, 0, FContainer.ClientWidth, FContainer.ClientHeight, LFlags);
end;

procedure TProcessDocker.EnforceDockedLayout;
var
  LRect: TRect;
  LParent: HWND;
begin
  if not FIsDocked or not FResponding or FSuspended or not Assigned(FContainer)
    or not FContainer.HandleAllocated or (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;

  LParent := Winapi.Windows.GetParent(FDockedWnd);
  if FUseChildStyle and (LParent <> FContainer.Handle) then
  begin
    Log('The window left the container, docking it again');
    Winapi.Windows.SetParent(FDockedWnd, FContainer.Handle);
  end;

  GetWindowRect(FDockedWnd, LRect);
  MapWindowPoints(0, FContainer.Handle, LRect, 2);
  // The window's own WS_VISIBLE: IsWindowVisible is also False while the host is hidden
  if ((GetWindowLongPtr(FDockedWnd, GWL_STYLE) and WS_VISIBLE) = 0) or (LRect.Left <> 0) or (LRect.Top <> 0)
    or (LRect.Width <> FContainer.ClientWidth) or (LRect.Height <> FContainer.ClientHeight) then
  begin
    Log('Window changed its own position / visibility after docking, layout re-applied');
    UpdateLayout(True);
  end;
end;

procedure TProcessDocker.FocusDockedWindow;
begin
  if FBrokerActive then
  begin
    if FIsDocked and IsRunning then
      BrokerCommand(BROKER_CMD_FOCUS);
    Exit;
  end;
  if FIsDocked and FResponding and not FSuspended and (FDockedWnd <> 0) and IsWindow(FDockedWnd) then
    Winapi.Windows.SetFocus(FDockedWnd);
end;

procedure TProcessDocker.SendTextInput(const AText: string; AAppendEnter: Boolean);
var
  LText: string;
  LChar: Char;
begin
  if FBrokerActive then
  begin
    // On purpose: it would let any non elevated program type into an elevated window
    Log('SendTextInput is not available through the elevated broker');
    Exit;
  end;
  if (FDockedWnd = 0) or not IsWindow(FDockedWnd) then
    Exit;

  LText := StringReplace(AText, #13#10, #13, [rfReplaceAll]);
  LText := StringReplace(LText, #10, #13, [rfReplaceAll]);
  if AAppendEnter then
    LText := LText + #13;

  for LChar in LText do
    PostMessage(FDockedWnd, WM_CHAR, WPARAM(Ord(LChar)), 1);
end;

{ Session lifetime }

function TProcessDocker.BuildKillTargets: TKillTargets;
begin
  Result.Clear;
  Result.Job := FJob;
  Result.LaunchedProcess := FLaunchedProcess;
  // Tree kill only while we hold a handle to the root, so its PID can not have been reused
  if FLaunchedProcess <> 0 then
    Result.LaunchedProcessId := FLaunchedPid;
  Result.WindowProcess := FWindowProcess;
  Result.KillWindowProcess := not FWindowIsForeign or FAllowKillForeignProcess;
end;

function TProcessDocker.OwnProcessesAlive: Boolean;
begin
  if FBrokerActive then
    Exit(FBrokerSessionAlive and IsBrokerAlive);
  Result := IsProcessHandleAlive(FLaunchedProcess)
    or (not FWindowIsForeign and IsProcessHandleAlive(FWindowProcess))
    or ((FLaunchedProcess <> 0) and (Length(GetDescendantProcessIds([FLaunchedPid])) > 0));
end;

function TProcessDocker.IsSessionAlive: Boolean;
begin
  if FBrokerActive then
    Exit(FBrokerSessionAlive and IsBrokerAlive);
  Result := ((FDockedWnd <> 0) and IsWindow(FDockedWnd)) or OwnProcessesAlive;
end;

function TProcessDocker.ReadExitCode: DWORD;
var
  LCode: DWORD;
begin
  Result := FExitCode;
  // Through a broker: reported with the exit event
  if FBrokerActive then
    Exit;
  if not FWindowIsForeign and (FWindowProcess <> 0) and GetExitCodeProcess(FWindowProcess, LCode)
    and (LCode <> STILL_ACTIVE) then
    Exit(LCode);
  if (FLaunchedProcess <> 0) and GetExitCodeProcess(FLaunchedProcess, LCode) and (LCode <> STILL_ACTIVE) then
    Result := LCode;
end;

function TProcessDocker.WaitForSessionEnd(ATimeoutMs: Cardinal): Boolean;
var
  LStart: UInt64;
  LHandle: THandle;
  LMsg: TMsg;
begin
  LStart := TicksNow;
  repeat
    if not IsSessionAlive then
      Exit(True);
    if TicksNow - LStart >= ATimeoutMs then
      Exit(False);

    // Through a broker the exit arrives as a sent WM_COPYDATA, processed below
    if FBrokerActive then
      LHandle := FBrokerProcess
    else if not FWindowIsForeign and IsProcessHandleAlive(FWindowProcess) then
      LHandle := FWindowProcess
    else if IsProcessHandleAlive(FLaunchedProcess) then
      LHandle := FLaunchedProcess
    else
      LHandle := 0;

    // Wake up on process exit or on a *sent* message only. Sent messages must be
    // processed, the docked window may SendMessage to us while closing. Posted
    // messages (input, timers, paint) are left in the queue to avoid re-entrancy.
    if LHandle <> 0 then
      MsgWaitForMultipleObjects(1, LHandle, False, 50, QS_SENDMESSAGE)
    else
      MsgWaitForMultipleObjects(0, Pointer(nil)^, False, 50, QS_SENDMESSAGE);
    PeekMessage(LMsg, 0, 0, 0, PM_NOREMOVE or PM_QS_SENDMESSAGE_);
  until False;
end;

procedure TProcessDocker.PostCloseMessage;
begin
  if FBrokerActive then
    BrokerCommand(BROKER_CMD_CLOSE)
  else if (FDockedWnd <> 0) and IsWindow(FDockedWnd) then
    PostMessage(FDockedWnd, WM_CLOSE, 0, 0)
  else
    Log('No window to send WM_CLOSE to');
end;

function TProcessDocker.CloseGracefullyInternal(ATimeoutMs: Cardinal): Boolean;
begin
  if not IsSessionAlive then
  begin
    HandleSessionEnded(True);
    Exit(True);
  end;

  if FSuspended then
    ResumeProcess;

  FExpectingExit := True;
  FCloseRequested := False;
  SetState(pdsClosing);
  Log('Closing gracefully (WM_CLOSE), waiting up to %d ms', [ATimeoutMs]);
  PostCloseMessage;

  Result := WaitForSessionEnd(ATimeoutMs);
  if Result then
    HandleSessionEnded(True)
  else
  begin
    Log('Did not close within %d ms', [ATimeoutMs]);
    FExpectingExit := False;
    SetState(pdsRunning);
  end;
end;

function TProcessDocker.CloseGracefully(ATimeoutMs: Cardinal): Boolean;
begin
  if ATimeoutMs = 0 then
    ATimeoutMs := FCloseTimeoutMs;
  Result := CloseGracefullyInternal(ATimeoutMs);
end;

procedure TProcessDocker.RequestClose;
begin
  if not IsRunning then
    Exit;

  if FSuspended then
    ResumeProcess;

  FExpectingExit := True;
  SetState(pdsClosing);
  Log('Close requested (WM_CLOSE), timeout %d ms', [FCloseTimeoutMs]);
  PostCloseMessage;
  FCloseRequested := True;
  FCloseDeadline := TicksNow + FCloseTimeoutMs;
  UpdateTimer;
end;

function TProcessDocker.KillInternal: Boolean;
begin
  if not IsSessionAlive then
  begin
    HandleSessionEnded(True);
    Exit(True);
  end;

  FExpectingExit := True;
  FCloseRequested := False;
  Log('Killing process');
  if FBrokerActive then
    BrokerCommand(BROKER_CMD_KILL)
  else
    KillTargets(BuildKillTargets, 1);

  Result := WaitForSessionEnd(KILL_WAIT_MS);
  if Result then
    HandleSessionEnded(True)
  else
  begin
    FExpectingExit := False;
    if FWindowIsForeign and not FAllowKillForeignProcess then
      Log('The window belongs to %s (pid %d) which was not started by us. ' +
        'Set AllowKillForeignProcess to allow killing it.', [FWindowProcessNameFound, FWindowPid])
    else
      Log('Process is still running after kill: %s', [SysErrorMessage(GetLastError)]);
    if FState = pdsClosing then
      SetState(pdsRunning);
  end;
end;

function TProcessDocker.Kill: Boolean;
begin
  Result := Kill(dkrManual);
end;

function TProcessDocker.Kill(AReason: TDockKillReason): Boolean;
begin
  if not IsSessionAlive then
    Exit(True);

  if not DoBeforeKill(AReason) then
  begin
    Log('Kill cancelled by OnBeforeKill');
    if FState = pdsClosing then
      SetState(pdsRunning);
    Exit(False);
  end;

  Result := KillInternal;
end;

procedure TProcessDocker.Stop;
begin
  FRestartPending := False;
  if not IsSessionAlive then
  begin
    if IsRunning then
      HandleSessionEnded(True);
    Exit;
  end;

  if not CloseGracefullyInternal(FCloseTimeoutMs) then
    Kill(dkrCloseTimeout);
end;

function TProcessDocker.IsRestartLimitReached: Boolean;
var
  LNow: UInt64;
  LIndex: Integer;
begin
  if FMaxRestarts <= 0 then
    Exit(False);

  LNow := TicksNow;
  for LIndex := FRestartHistory.Count - 1 downto 0 do
    if LNow - FRestartHistory[LIndex] > FRestartWindowMs then
      FRestartHistory.Delete(LIndex);

  Result := FRestartHistory.Count >= FMaxRestarts;
end;

function TProcessDocker.Restart(AReason: TDockRestartReason): Boolean;
begin
  Result := False;
  if FInRestart then
    Exit;

  FRestartPending := False;
  if not DoBeforeRestart(AReason) then
  begin
    Log('Restart cancelled');
    Exit;
  end;

  FInRestart := True;
  try
    if AReason <> drrManual then
      FRestartHistory.Add(TicksNow);
    Inc(FRestartCount);

    if IsSessionAlive then
    begin
      Log('Restarting: stopping current process');
      if AReason = drrHung then
        KillInternal
      else if not CloseGracefullyInternal(FCloseTimeoutMs) then
        KillInternal;
    end;

    if IsSessionAlive then
    begin
      Log('Restart aborted: the process could not be stopped');
      Exit;
    end;

    FState := pdsIdle;
    Start;
    Result := True;
  finally
    FInRestart := False;
  end;
end;

procedure TProcessDocker.ScheduleRestart(AReason: TDockRestartReason; ADelayMs: Cardinal);
begin
  FPendingRestartReason := AReason;
  FRestartPending := True;
  FRestartAt := TicksNow + ADelayMs;
  Log('Restart scheduled in %d ms', [ADelayMs]);
  UpdateTimer;
end;

procedure TProcessDocker.HandleSessionEnded(AExpected: Boolean);
var
  LInfo: TDockedProcessInfo;
  LExpected: Boolean;
  LExitCode: DWORD;
begin
  if not IsRunning then
    Exit;

  StopWatchdog;
  FDiscovering := False;
  FCloseRequested := False;
  LExpected := AExpected or FExpectingExit;

  // The window is gone but some of our processes may still linger (tray apps, helpers)
  if not FBrokerActive and OwnProcessesAlive then
  begin
    WaitForSessionEnd(1000);
    if OwnProcessesAlive then
    begin
      Log('Window is gone but the process is still running, terminating it');
      KillTargets(BuildKillTargets, 0);
    end;
  end;

  LExitCode := ReadExitCode;
  FExitCode := LExitCode;
  FResponding := True;
  FUnresponsiveSince := 0;
  FSuspended := False;
  LInfo := GetInfo;

  FIsDocked := False;
  FIsParked := False;
  FDockedWnd := 0;
  FExpectingExit := False;
  CloseSessionHandles;

  Log('Process exited, exit code %u / $%x (%s)', [LExitCode, LExitCode, IfThen(LExpected, 'expected', 'unexpected')]);
  SetState(pdsExited);

  if Assigned(FOnProcessExit) and CanFireEvents then
    FOnProcessExit(Self, LInfo, LExitCode, LExpected);

  if FShuttingDown or FInRestart then
    Exit;

  if FRestartAfterExit then
  begin
    FRestartAfterExit := False;
    ScheduleRestart(FRestartAfterExitReason, 0);
  end
  else if not LExpected and FRestartOnUnexpectedExit then
    ScheduleRestart(drrUnexpectedExit, FRestartDelayMs);

  // Keep the elevated broker only for a restart (no new UAC prompt)
  if FBrokerActive and not FRestartPending then
    ReleaseBroker;
end;

procedure TProcessDocker.CloseSessionHandles;
begin
  if FLaunchedProcess <> 0 then
  begin
    CloseHandle(FLaunchedProcess);
    FLaunchedProcess := 0;
  end;
  if FWindowProcess <> 0 then
  begin
    CloseHandle(FWindowProcess);
    FWindowProcess := 0;
  end;
  if FJob <> 0 then
  begin
    // Kill on close: anything still in the job dies here (intended)
    CloseHandle(FJob);
    FJob := 0;
  end;
end;

procedure TProcessDocker.ResetSession;
begin
  FLaunchedPid := 0;
  FLaunchedElevated := False;
  FWindowPid := 0;
  FWindowIsForeign := False;
  FWindowProcessNameFound := '';
  FWindowClassFound := '';
  FDockedWnd := 0;
  FIsDocked := False;
  FIsParked := False;
  FHaveOriginal := False;
  FTitle := '';
  FExitCode := 0;
  FResponding := True;
  FUnresponsiveSince := 0;
  FSuspended := False;
  FExpectingExit := False;
  FLastError := '';
  FTreePids := nil;
  FDiscovering := False;
  FCloseRequested := False;
  FRestartAfterExit := False;
  FBrokerActive := False;
  FBrokerSessionAlive := False;
end;

function TProcessDocker.SuspendProcess: Boolean;
var
  LPid: DWORD;
begin
  Result := False;
  if not IsRunning or FSuspended then
    Exit;

  if FBrokerActive then
  begin
    BrokerCommand(BROKER_CMD_SUSPEND);
    FSuspended := True;
    Exit(True);
  end;

  if FLaunchedProcess <> 0 then
    for LPid in GetDescendantProcessIds([FLaunchedPid]) do
      if SuspendProcessById(LPid) then
        Result := True;

  if (FWindowPid <> 0) and (not FWindowIsForeign or FAllowKillForeignProcess) then
    if SuspendProcessById(FWindowPid) then
      Result := True;

  FSuspended := Result;
  if Result then
    Log('Process suspended')
  else
    Log('Could not suspend the process');
end;

function TProcessDocker.ResumeProcess: Boolean;
var
  LPid: DWORD;
begin
  Result := False;
  if not FSuspended then
    Exit;

  if FBrokerActive then
  begin
    BrokerCommand(BROKER_CMD_RESUME);
    FSuspended := False;
    Exit(True);
  end;

  if FLaunchedProcess <> 0 then
    for LPid in GetDescendantProcessIds([FLaunchedPid]) do
      if ResumeProcessById(LPid) then
        Result := True;

  if (FWindowPid <> 0) and (not FWindowIsForeign or FAllowKillForeignProcess) then
    if ResumeProcessById(FWindowPid) then
      Result := True;

  FSuspended := False;
  Log('Process resumed');
end;

function TProcessDocker.GetInfo: TDockedProcessInfo;
var
  LPid: DWORD;
  LIds: TProcessIdArray;
begin
  Result := Default(TDockedProcessInfo);
  Result.State := FState;
  Result.FileName := FFileName;
  Result.Parameters := FParameters;
  Result.LaunchedProcessId := FLaunchedPid;
  Result.WindowProcessId := FWindowPid;
  Result.WindowProcessName := FWindowProcessNameFound;
  Result.WindowIsForeign := FWindowIsForeign;
  Result.WindowHandle := FDockedWnd;
  Result.WindowClassName := FWindowClassFound;
  Result.WindowTitle := FTitle;
  Result.Docked := FIsDocked;
  Result.Responding := FResponding;
  Result.Suspended := FSuspended;
  Result.Elevated := FLaunchedElevated;
  Result.StartTime := FStartTime;
  Result.RestartCount := FRestartCount;
  Result.ExitCode := FExitCode;
  if FUnresponsiveSince <> 0 then
    Result.UnresponsiveMs := Cardinal(TicksNow - FUnresponsiveSince);

  if IsRunning then
  begin
    if FLaunchedProcess <> 0 then
      LIds := GetDescendantProcessIds([FLaunchedPid])
    else
      LIds := nil;
    if (FWindowPid <> 0) and not ContainsProcessId(LIds, FWindowPid) then
      LIds := LIds + [FWindowPid];
    for LPid in LIds do
      Inc(Result.WorkingSetBytes, GetProcessWorkingSetSize(LPid));
  end;
end;

{ Watchdog }

procedure TProcessDocker.StartWatchdog;
var
  LConfig: TDockWatchdogConfig;
  LWaitProcess: THandle;
  LHangTimeout: Cardinal;
begin
  StopWatchdog;

  if (FDockedWnd = 0) and (FLaunchedProcess = 0) then
    Exit;

  if not FWindowIsForeign and (FWindowProcess <> 0) then
    LWaitProcess := FWindowProcess
  else if FDockedWnd = 0 then
    LWaitProcess := FLaunchedProcess
  else
    LWaitProcess := 0;

  LHangTimeout := GetEffectiveHangTimeoutMs;
  // The new watchdog evaluates responsiveness from scratch
  FResponding := True;
  FUnresponsiveSince := 0;

  Inc(FWatchdogCounter);
  LConfig := Default(TDockWatchdogConfig);
  LConfig.Id := FWatchdogCounter;
  LConfig.Window := FDockedWnd;
  if LWaitProcess <> 0 then
    DuplicateHandle(GetCurrentProcess, LWaitProcess, GetCurrentProcess, @LConfig.WaitProcess, 0, False,
      DUPLICATE_SAME_ACCESS);
  LConfig.PollIntervalMs := FPollIntervalMs;
  LConfig.HangDetection := FHangDetection and (FDockedWnd <> 0);
  LConfig.HangTimeoutMs := LHangTimeout;
  LConfig.PingTimeoutMs := Min(Cardinal(1000), Max(Cardinal(100), LHangTimeout div 2));
  LConfig.EmergencyKillTimeoutMs := FEmergencyKillTimeoutMs;
  LConfig.WatchWindow := FEmergencyWatchWindow;
  LConfig.KillTargets := BuildKillTargets.Duplicate;
  LConfig.InitialTitle := FTitle;

  FWatchdog := TDockWatchdog.Create(LConfig, FLink);
end;

procedure TProcessDocker.StopWatchdog;
var
  LWatchdog: TDockWatchdog;
begin
  if not Assigned(FWatchdog) then
    Exit;

  LWatchdog := FWatchdog;
  FWatchdog := nil;
  LWatchdog.Stop;
  // Plain wait: the watchdog never Synchronizes, so it can not wait for us.
  // (TThread.WaitFor would run CheckSynchronize here and re-enter our code.)
  WaitForSingleObject(LWatchdog.Handle, 10000);
  LWatchdog.Free;
end;

function TProcessDocker.IsCurrentWatchdog(AId: Integer): Boolean;
begin
  Result := Assigned(FWatchdog) and (FWatchdog.Id = AId);
end;

procedure TProcessDocker.HandleWatchdogSessionEnded(AId: Integer);
begin
  if IsCurrentWatchdog(AId) then
    HandleSessionEnded(False);
end;

procedure TProcessDocker.HandleWatchdogHung(AId: Integer; AUnresponsiveMs: Cardinal);
begin
  if not IsCurrentWatchdog(AId) then
    Exit;

  FResponding := False;
  FUnresponsiveSince := TicksNow - AUnresponsiveMs;
  Log('Window is not responding (%d ms)', [AUnresponsiveMs]);

  if not IsSessionAlive then
    Exit; // Emergency kill already happened, exit notification will follow

  // We got here, so the main thread is alive. Acknowledge before the event: a modal
  // dialog in OnHung keeps processing the watchdog heartbeats, a blocked one does not.
  if IsCurrentWatchdog(AId) then
    FWatchdog.AcknowledgeHang;

  ProcessHang(AUnresponsiveMs);
end;

procedure TProcessDocker.ProcessHang(AUnresponsiveMs: Cardinal);
var
  LAction: TDockHangAction;
begin
  FResponding := False;
  if FUnresponsiveSince = 0 then
    FUnresponsiveSince := TicksNow - AUnresponsiveMs;

  LAction := FHangAction;
  if Assigned(FOnHung) and CanFireEvents then
    FOnHung(Self, GetInfo, LAction);

  if not IsSessionAlive or FResponding then
    Exit;

  case LAction of
    dhaKill:
      Kill(dkrHung);
    dhaRestart:
      Restart(drrHung);
  end;
end;

procedure TProcessDocker.HandleWatchdogResponding(AId: Integer; AUnresponsiveMs: Cardinal);
begin
  if IsCurrentWatchdog(AId) then
    ProcessResponding(AUnresponsiveMs);
end;

procedure TProcessDocker.ProcessResponding(AUnresponsiveMs: Cardinal);
begin
  FResponding := True;
  FUnresponsiveSince := 0;
  if not FBrokerActive then // the broker logs it itself
    Log('Window is responding again (was unresponsive %d ms)', [AUnresponsiveMs]);
  if Assigned(FOnResponding) and CanFireEvents then
    FOnResponding(Self, GetInfo, AUnresponsiveMs);
  UpdateLayout(False);
end;

procedure TProcessDocker.HandleWatchdogTitle(AId: Integer; const ATitle: string);
begin
  if IsCurrentWatchdog(AId) then
    ProcessTitle(ATitle);
end;

procedure TProcessDocker.ProcessTitle(const ATitle: string);
begin
  FTitle := ATitle;
  if Assigned(FOnTitleChange) and CanFireEvents then
    FOnTitleChange(Self, ATitle);
end;

procedure TProcessDocker.HandleWatchdogEmergencyKill(AId: Integer; AUnresponsiveMs: Cardinal; AKilled: Boolean);
begin
  if IsCurrentWatchdog(AId) then
    ProcessEmergencyKill(AUnresponsiveMs, AKilled);
end;

procedure TProcessDocker.ProcessEmergencyKill(AUnresponsiveMs: Cardinal; AKilled: Boolean);
begin
  FExpectingExit := True;
  if FBrokerActive then
    // The broker logs the details
  else if AKilled then
    Log('EMERGENCY KILL: the host UI thread was blocked while the docked window was hung, process killed')
  else
    Log('EMERGENCY KILL failed: could not terminate the process');

  if FHangAction = dhaRestart then
  begin
    FRestartAfterExit := True;
    FRestartAfterExitReason := drrHung;
  end;

  if Assigned(FOnEmergencyKill) and CanFireEvents then
    FOnEmergencyKill(Self, GetInfo, AUnresponsiveMs);
end;

{ Broker (host side) }

function BoolText(AValue: Boolean): string;
begin
  if AValue then
    Result := '1'
  else
    Result := '0';
end;

function TProcessDocker.NeedsBrokerFor(AElevate: Boolean): Boolean;
begin
  Result := (FBrokerMode = dbmAlways)
    or ((FBrokerMode = dbmWhenElevationNeeded) and AElevate and not IsCurrentProcessElevated);
end;

function TProcessDocker.IsBrokerAlive: Boolean;
begin
  Result := (FBrokerProcess <> 0) and IsProcessHandleAlive(FBrokerProcess);
end;

function TProcessDocker.BrokerSignature(AElevated: Boolean): string;
var
  LList: TStringList;
begin
  // Everything the broker is started with. It never accepts another command line.
  LList := TStringList.Create;
  try
    LList.Add('elevated=' + BoolText(AElevated));
    LList.Add('file=' + BrokerValue(FFileName));
    LList.Add('params=' + BrokerValue(FParameters));
    LList.Add('dir=' + BrokerValue(FWorkingDirectory));
    LList.Add('starthidden=' + BoolText(FStartHidden));
    LList.Add('class=' + BrokerValue(FWindowClassName));
    LList.Add('procname=' + BrokerValue(FWindowProcessName));
    LList.Add('foreign=' + BoolText(FAcceptForeignWindows));
    LList.Add('findtimeout=' + IntToStr(FFindWindowTimeoutMs));
    LList.Add('childstyle=' + BoolText(FUseChildStyle));
    LList.Add('removeframe=' + BoolText(FRemoveWindowFrame));
    LList.Add('focusondock=' + BoolText(FFocusOnDock));
    LList.Add('allowkillforeign=' + BoolText(FAllowKillForeignProcess));
    LList.Add('closetimeout=' + IntToStr(FCloseTimeoutMs));
    LList.Add('hangdetection=' + BoolText(FHangDetection));
    LList.Add('hangtimeout=' + IntToStr(FHangTimeoutMs));
    LList.Add('poll=' + IntToStr(FPollIntervalMs));
    LList.Add('emergency=' + IntToStr(FEmergencyKillTimeoutMs));
    LList.Add('color=' + IntToStr(ColorToRGB(FColor)));
    Result := LList.Text;
  finally
    LList.Free;
  end;
end;

function TProcessDocker.BuildBrokerSettings(AElevated: Boolean): string;
begin
  Result := BrokerSignature(AElevated)
    + 'container=' + IntToStr(NativeUInt(FContainer.Handle)) + sLineBreak
    + 'link=' + IntToStr(NativeUInt(FBrokerLinkWnd)) + sLineBreak
    + 'hostpid=' + IntToStr(GetCurrentProcessId) + sLineBreak
    + 'cookie=' + IntToStr(FBrokerCookie) + sLineBreak
    + 'session=' + IntToStr(FBrokerSession) + sLineBreak;
end;

procedure TProcessDocker.EnsureBrokerLink;
begin
  if FBrokerLinkWnd = 0 then
    FBrokerLinkWnd := AllocateHWnd(BrokerLinkWndProc);
end;

procedure TProcessDocker.StartViaBroker(AElevated: Boolean);
var
  LSignature: string;
begin
  EnsureBrokerLink;
  FBrokerActive := True;
  FBrokerSessionAlive := True;
  Inc(FBrokerSession);
  FLaunchedElevated := AElevated or IsCurrentProcessElevated;

  LSignature := BrokerSignature(AElevated);
  if IsBrokerAlive and (LSignature = FBrokerSignature) then
  begin
    Log('Starting again through the running broker');
    BrokerCommand(BROKER_CMD_START, FBrokerSession);
    Exit;
  end;

  ReleaseBroker;
  // Identifies our broker; also guards against commands to / events from strangers
  FBrokerCookie := Word(1 + (GetTickCount64 * 2654435761 + NativeUInt(Self) + GetCurrentProcessId) mod 65534);
  LaunchBroker(AElevated, BuildBrokerSettings(AElevated));
  FBrokerSignature := LSignature;
end;

procedure TProcessDocker.LaunchBroker(AElevated: Boolean; const ASettings: string);
var
  LFileName: string;
  LParameters: string;
  LProcess: THandle;
  LInfo: TShellExecuteInfo;
  LStartupInfo: TStartupInfo;
  LProcessInfo: TProcessInformation;
  LCommandLine: string;
  LForm: TCustomForm;
  LError: DWORD;
begin
  LFileName := FBrokerFileName;
  if LFileName = '' then
  begin
    LFileName := ParamStr(0);
    if not IsBrokerEntryPointReady and not Assigned(FBrokerLaunchHook) then
      raise EProcessDocker.Create('BrokerMode: call RunProcessDockerBroker (unit ProcessToFormDocker.Broker) ' +
        'first in the .dpr, or set BrokerFileName');
  end;
  LParameters := Format('/%s %s', [BROKER_SWITCH, EncodeBrokerData(ASettings)]);

  if Assigned(FBrokerLaunchHook) then
    LProcess := FBrokerLaunchHook(LFileName, LParameters, AElevated)
  else if AElevated then
  begin
    LInfo := Default(TShellExecuteInfo);
    LInfo.cbSize := SizeOf(LInfo);
    LInfo.fMask := SEE_MASK_NOCLOSEPROCESS or SEE_MASK_NOASYNC;
    LInfo.lpVerb := 'runas';
    LInfo.lpFile := PChar(LFileName);
    LInfo.lpParameters := PChar(LParameters);
    LInfo.nShow := SW_HIDE;
    LForm := GetParentForm(FContainer);
    if Assigned(LForm) and LForm.HandleAllocated then
      LInfo.Wnd := LForm.Handle;
    if not ShellExecuteEx(@LInfo) then
    begin
      LError := GetLastError;
      if LError = ERROR_CANCELLED then
        raise EProcessDocker.CreateFmt('Starting "%s" elevated was cancelled by the user', [FFileName]);
      raise EProcessDocker.CreateFmt('Could not start the elevated broker: %s', [SysErrorMessage(LError)]);
    end;
    LProcess := LInfo.hProcess;
  end
  else
  begin
    LCommandLine := Format('"%s" %s', [LFileName, LParameters]);
    UniqueString(LCommandLine);
    LStartupInfo := Default(TStartupInfo);
    LStartupInfo.cb := SizeOf(LStartupInfo);
    LStartupInfo.dwFlags := STARTF_USESHOWWINDOW;
    LStartupInfo.wShowWindow := SW_HIDE;
    LProcessInfo := Default(TProcessInformation);
    if not CreateProcess(nil, PChar(LCommandLine), nil, nil, False, CREATE_DEFAULT_ERROR_MODE, nil, nil,
      LStartupInfo, LProcessInfo) then
      raise EProcessDocker.CreateFmt('Could not start the broker: %s', [SysErrorMessage(GetLastError)]);
    CloseHandle(LProcessInfo.hThread);
    LProcess := LProcessInfo.hProcess;
  end;

  if LProcess = 0 then
    raise EProcessDocker.Create('Could not start the broker');

  FBrokerProcess := LProcess;
  FBrokerWnd := 0;
  FBrokerPending.Clear;
  Log('Broker started (pid %d%s)', [GetProcessIdOfHandle(LProcess), IfThen(AElevated, ', elevated', '')]);
end;

procedure TProcessDocker.ReleaseBroker;
begin
  if FBrokerProcess <> 0 then
  begin
    if IsProcessHandleAlive(FBrokerProcess) then
      BrokerCommand(BROKER_CMD_SHUTDOWN, Ord(dsaKill));
    CloseHandle(FBrokerProcess);
    FBrokerProcess := 0;
  end;
  FBrokerWnd := 0;
  FBrokerPending.Clear;
  FBrokerSignature := '';
  // A broker that says hello after this is told to quit
  FBrokerCookie := 0;
end;

procedure TProcessDocker.BrokerCommand(ACommand: Word; AArgument: LPARAM);
begin
  if FBrokerWnd <> 0 then
    PostMessage(FBrokerWnd, BrokerCommandMessage, MakeWParam(ACommand, FBrokerCookie), AArgument)
  else if (ACommand <> BROKER_CMD_LAYOUT) and (ACommand <> BROKER_CMD_FOCUS) then
    // Not connected yet (UAC prompt open...): sent on hello
    FBrokerPending.Add(TPair<Word, LPARAM>.Create(ACommand, AArgument));
end;

procedure TProcessDocker.BrokerLinkWndProc(var AMessage: TMessage);
begin
  case AMessage.Msg of
    WM_COPYDATA:
      AMessage.Result := HandleBrokerData(HWND(AMessage.WParam), PCopyDataStruct(AMessage.LParam)^);
    WM_BROKER_EVENTS:
      ProcessBrokerEvents;
  else
    AMessage.Result := DefWindowProc(FBrokerLinkWnd, AMessage.Msg, AMessage.WParam, AMessage.LParam);
  end;
end;

function TProcessDocker.HandleBrokerData(ASender: HWND; const AData: TCopyDataStruct): LRESULT;
var
  LText: string;
  LEvent: Integer;
  LFields: TStringList;
  LCookie: Integer;
  LSession: Integer;
  LWnd: HWND;
  LPending: TPair<Word, LPARAM>;
begin
  // Sent message: may arrive while we wait in CloseGracefully / Kill. Only update the
  // session state here, the events are fired later from the posted WM_BROKER_EVENTS.
  Result := 1;
  LText := ReadBrokerData(AData);
  LEvent := Integer(AData.dwData);
  LFields := TStringList.Create;
  try
    LFields.Text := LText;
    LCookie := StrToIntDef(LFields.Values['cookie'], -1);
    if (FBrokerCookie = 0) or (LCookie <> FBrokerCookie) then
    begin
      // A broker we gave up on (UAC prompt answered after a Stop...): tell it to quit
      if (LEvent = BROKER_EVT_HELLO) and (LCookie > 0) then
      begin
        LWnd := HWND(StrToInt64Def(LFields.Values['wnd'], 0));
        if LWnd <> 0 then
          PostMessage(LWnd, BrokerCommandMessage, MakeWParam(BROKER_CMD_SHUTDOWN, Word(LCookie)), Ord(dsaKill));
      end;
      Exit;
    end;

    LSession := StrToIntDef(LFields.Values['session'], -1);
    case LEvent of
      BROKER_EVT_HELLO:
        begin
          FBrokerWnd := HWND(StrToInt64Def(LFields.Values['wnd'], 0));
          for LPending in FBrokerPending do
            PostMessage(FBrokerWnd, BrokerCommandMessage, MakeWParam(LPending.Key, FBrokerCookie), LPending.Value);
          FBrokerPending.Clear;
        end;
      BROKER_EVT_EXITED:
        if LSession = FBrokerSession then
        begin
          FExitCode := DWORD(StrToInt64Def(LFields.Values['code'], 0));
          if LFields.Values['expected'] = '1' then
            FExpectingExit := True;
          FBrokerSessionAlive := False;
        end;
      BROKER_EVT_STARTFAILED:
        if LSession = FBrokerSession then
          FBrokerSessionAlive := False;
      BROKER_EVT_DOCKFAILED:
        if (LSession = FBrokerSession) and (LFields.Values['running'] <> '1') then
          FBrokerSessionAlive := False;
    end;
  finally
    LFields.Free;
  end;

  FBrokerEvents.Add(TPair<Integer, string>.Create(LEvent, LText));
  PostMessage(FBrokerLinkWnd, WM_BROKER_EVENTS, 0, 0);
end;

procedure TProcessDocker.ProcessBrokerEvents;
var
  LItem: TPair<Integer, string>;
  LFields: TStringList;
begin
  while (FBrokerEvents.Count > 0) and not FShuttingDown do
  begin
    // Taken out first: an event handler may run a message loop and get here again
    LItem := FBrokerEvents[0];
    FBrokerEvents.Delete(0);
    LFields := TStringList.Create;
    try
      LFields.Text := LItem.Value;
      if (LItem.Key in [BROKER_EVT_HELLO, BROKER_EVT_LOG])
        or (StrToIntDef(LFields.Values['session'], -1) = FBrokerSession) then
        ProcessBrokerEvent(LItem.Key, LFields);
    finally
      LFields.Free;
    end;
  end;
end;

procedure TProcessDocker.ProcessBrokerEvent(AEvent: Integer; AFields: TStrings);

  function Num(const AName: string): Int64;
  begin
    Result := StrToInt64Def(AFields.Values[AName], 0);
  end;

var
  LReason: string;
begin
  case AEvent of
    BROKER_EVT_HELLO:
      Log('Broker connected (pid %d%s)', [Num('pid'), IfThen(AFields.Values['elevated'] = '1', ', elevated', '')]);

    BROKER_EVT_LOG:
      Log('Broker: ' + AFields.Values['text']);

    BROKER_EVT_STARTED:
      FLaunchedPid := DWORD(Num('pid'));

    BROKER_EVT_STARTFAILED:
      if IsRunning then
      begin
        FLastError := AFields.Values['reason'];
        Log(FLastError);
        SetState(pdsFailed);
        DoDockFailed(FLastError);
        if not FRestartPending then
          ReleaseBroker;
      end;

    BROKER_EVT_DOCKED:
      if IsRunning then
      begin
        FDockedWnd := HWND(Num('wnd'));
        FWindowPid := DWORD(Num('pid'));
        FLaunchedPid := DWORD(Num('launchedpid'));
        FWindowClassFound := AFields.Values['class'];
        FWindowProcessNameFound := AFields.Values['procname'];
        FTitle := AFields.Values['title'];
        FWindowIsForeign := AFields.Values['foreign'] = '1';
        FLaunchedElevated := AFields.Values['elevated'] = '1';
        FOriginalStyle := NativeInt(Num('style'));
        FOriginalClientRect := Rect(Integer(Num('clientleft')), Integer(Num('clienttop')),
          Integer(Num('clientright')), Integer(Num('clientbottom')));
        FOriginalRect := FOriginalClientRect;
        FIsDocked := True;
        FResponding := True;
        FLastError := '';
        SetState(pdsRunning);
        DoDocked;
      end;

    BROKER_EVT_DOCKFAILED:
      if IsRunning then
      begin
        LReason := AFields.Values['reason'];
        FLastError := LReason;
        FIsDocked := False;
        if AFields.Values['running'] = '1' then
          SetState(pdsRunning) // in its own window
        else
        begin
          SetState(pdsFailed);
          if not FRestartPending then
            ReleaseBroker;
        end;
        DoDockFailed(LReason);
      end;

    BROKER_EVT_HUNG:
      if IsRunning then
        ProcessHang(Cardinal(Num('ms')));

    BROKER_EVT_RESPONDING:
      if IsRunning then
        ProcessResponding(Cardinal(Num('ms')));

    BROKER_EVT_TITLE:
      ProcessTitle(AFields.Values['title']);

    BROKER_EVT_EMERGENCY:
      if IsRunning then
        ProcessEmergencyKill(Cardinal(Num('ms')), True);

    BROKER_EVT_EXITED:
      if IsRunning then
        HandleSessionEnded(AFields.Values['expected'] = '1');
  end;
end;

{ Timer }

procedure TProcessDocker.UpdateTimer;
begin
  if Assigned(FTimer) then
    FTimer.Enabled := (FDiscovering or FCloseRequested or FRestartPending or (FIsDocked and (TicksNow < FSettleUntil))
      or (FBrokerActive and IsRunning)) and not FShuttingDown;
end;

procedure TProcessDocker.TimerTick(Sender: TObject);
var
  LReason: TDockRestartReason;
  LCode: DWORD;
begin
  FTimer.Enabled := False;
  try
    // The broker process itself ended (crash, killed): the session is over
    if FBrokerActive and IsRunning and (FBrokerProcess <> 0) and not IsProcessHandleAlive(FBrokerProcess) then
    begin
      Log('The broker process has ended');
      if FBrokerSessionAlive and GetExitCodeProcess(FBrokerProcess, LCode) then
        FExitCode := LCode;
      FBrokerSessionAlive := False;
      HandleSessionEnded(False);
    end;

    if FDiscovering then
      DiscoverStep;

    if FIsDocked and (TicksNow < FSettleUntil) then
      EnforceDockedLayout;

    if FCloseRequested then
    begin
      if not IsSessionAlive then
        HandleSessionEnded(True)
      else if TicksNow >= FCloseDeadline then
      begin
        FCloseRequested := False;
        Log('Did not close within %d ms', [FCloseTimeoutMs]);
        if FKillAfterCloseTimeout then
          Kill(dkrCloseTimeout)
        else
        begin
          FExpectingExit := False;
          SetState(pdsRunning);
        end;
      end;
    end;

    if FRestartPending and (TicksNow >= FRestartAt) then
    begin
      FRestartPending := False;
      LReason := FPendingRestartReason;
      try
        Restart(LReason);
      except
        on E: Exception do
        begin
          FLastError := E.Message;
          Log('Restart failed: %s', [E.Message]);
          DoDockFailed(E.Message);
        end;
      end;
      // Restart not allowed / failed: the broker kept for it is not needed any more
      if FBrokerActive and not IsRunning and not FRestartPending then
        ReleaseBroker;
    end;
  finally
    UpdateTimer;
  end;
end;

{ Events }

function TProcessDocker.CanFireEvents: Boolean;
begin
  Result := not FShuttingDown and not (csDestroying in ComponentState);
end;

procedure TProcessDocker.SetState(AState: TProcessDockerState);
begin
  if FState = AState then
    Exit;

  FState := AState;
  if Assigned(FContainer) then
    FContainer.Invalidate;
  if Assigned(FOnStateChange) and CanFireEvents then
    FOnStateChange(Self);
end;

procedure TProcessDocker.Log(const AMessage: string);
begin
  if Assigned(FOnLog) and CanFireEvents then
    FOnLog(Self, AMessage);
end;

procedure TProcessDocker.Log(const AFormat: string; const AArgs: array of const);
begin
  if Assigned(FOnLog) and CanFireEvents then
    FOnLog(Self, Format(AFormat, AArgs));
end;

procedure TProcessDocker.DoDocked;
begin
  if Assigned(FContainer) then
    FContainer.Invalidate;
  if Assigned(FOnDocked) and CanFireEvents then
    FOnDocked(Self);
end;

procedure TProcessDocker.DoUndocked;
begin
  if Assigned(FOnUndocked) and CanFireEvents then
    FOnUndocked(Self);
end;

procedure TProcessDocker.DoDockFailed(const AReason: string);
begin
  if Assigned(FOnDockFailed) and CanFireEvents then
    FOnDockFailed(Self, AReason);
end;

function TProcessDocker.DoBeforeKill(AReason: TDockKillReason): Boolean;
begin
  Result := True;
  if Assigned(FOnBeforeKill) and CanFireEvents then
    FOnBeforeKill(Self, GetInfo, AReason, Result);
end;

function TProcessDocker.DoBeforeRestart(AReason: TDockRestartReason): Boolean;
begin
  Result := (AReason = drrManual) or not IsRestartLimitReached;
  if not Result then
    Log('Restart limit reached (%d restarts within %d ms)', [FMaxRestarts, FRestartWindowMs]);
  if Assigned(FOnBeforeRestart) and CanFireEvents then
    FOnBeforeRestart(Self, GetInfo, AReason, Result);
end;

end.
