unit ProcessToFormDocker.Broker;

{
  Elevated broker: lets a NON elevated host show an ELEVATED application docked.

  Windows (UIPI) does not allow a lower integrity process to re-parent, move or send
  input to the window of a higher integrity process. The other direction is allowed.
  So TProcessDocker (BrokerMode) starts a copy of the host executable elevated, with
  the /ProcessDockerBroker switch. That broker:

    - creates a panel of its own INSIDE the host's container window,
    - starts the application and docks it into that panel with a normal TProcessDocker,
    - follows the size of the host container,
    - does what the host can not do itself: close, kill, suspend, hang detection,
    - reports everything back to the host (WM_COPYDATA), and
    - kills the application and exits when the host goes away (crash included).

  The host only sends a few commands (posted messages, allowed through UIPI with
  ChangeWindowMessageFilterEx). The command line of the application is fixed when
  the broker starts; the broker never accepts a new one and never forwards input
  (no SendTextInput), so other non elevated processes can not use it to run or
  control anything as administrator.

  To support it, call RunProcessDockerBroker first thing in the .dpr:

    begin
      if RunProcessDockerBroker then
        Exit;
      Application.Initialize;
      ...
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes;

const
  BROKER_SWITCH = 'ProcessDockerBroker';

  // Events, broker -> host: WM_COPYDATA, dwData = event, data = "name=value" lines
  BROKER_EVT_HELLO = 1;
  BROKER_EVT_LOG = 2;
  BROKER_EVT_STARTED = 3;
  BROKER_EVT_STARTFAILED = 4;
  BROKER_EVT_DOCKED = 5;
  BROKER_EVT_DOCKFAILED = 6;
  BROKER_EVT_HUNG = 7;
  BROKER_EVT_RESPONDING = 8;
  BROKER_EVT_TITLE = 9;
  BROKER_EVT_EMERGENCY = 10;
  BROKER_EVT_EXITED = 11;

  // Commands, host -> broker: posted BrokerCommandMessage, wParam = MakeWParam(command, cookie)
  BROKER_CMD_START = 1;      // lParam = session number
  BROKER_CMD_CLOSE = 2;
  BROKER_CMD_KILL = 3;
  BROKER_CMD_SUSPEND = 4;
  BROKER_CMD_RESUME = 5;
  BROKER_CMD_FOCUS = 6;
  BROKER_CMD_LAYOUT = 7;
  BROKER_CMD_CONTAINER = 8;  // lParam = new container window
  BROKER_CMD_SHUTDOWN = 9;   // lParam = Ord(TDockShutdownAction)

/// <summary>
///   Call this first in the .dpr of an application that uses TProcessDocker.BrokerMode
///   (before Application.Initialize, single instance checks etc.). Returns True when
///   this process was started as a broker: it has done its job, exit right away.
/// </summary>
function RunProcessDockerBroker: Boolean;

/// <summary>True when RunProcessDockerBroker was called in this (host) process.</summary>
function IsBrokerEntryPointReady: Boolean;

{ Protocol helpers, used by TProcessDocker }

function BrokerCommandMessage: UINT;
function EncodeBrokerData(const AText: string): string;
function DecodeBrokerData(const AHex: string): string;
function BrokerValue(const AText: string): string;
function SendBrokerData(ATarget, ASender: HWND; AEvent: Integer; const AText: string;
  ATimeoutMs: Cardinal): Boolean;
function ReadBrokerData(const ACopyData: TCopyDataStruct): string;

implementation

uses
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics,
  ProcessToFormDocker, ProcessToFormDocker.WinApi;

const
  MSGFLT_ALLOW = 1;
  EVENT_SEND_TIMEOUT_MS = 500;
  IDLE_QUIT_MS = 60000;

function ChangeWindowMessageFilterEx(AWnd: HWND; AMessage: UINT; AAction: DWORD;
  AChangeFilterStruct: Pointer): BOOL; stdcall; external user32 name 'ChangeWindowMessageFilterEx';

var
  GEntryPointReady: Boolean;
  GCommandMessage: UINT;

{ Protocol }

function BrokerCommandMessage: UINT;
begin
  if GCommandMessage = 0 then
    GCommandMessage := RegisterWindowMessage('ProcessToFormDocker.Broker.Command');
  Result := GCommandMessage;
end;

function EncodeBrokerData(const AText: string): string;
var
  LBuilder: TStringBuilder;
  LChar: Char;
begin
  LBuilder := TStringBuilder.Create(Length(AText) * 4);
  try
    for LChar in AText do
      LBuilder.Append(IntToHex(Ord(LChar), 4));
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

function DecodeBrokerData(const AHex: string): string;
var
  LIndex: Integer;
  LCount: Integer;
begin
  LCount := Length(AHex) div 4;
  SetLength(Result, LCount);
  for LIndex := 0 to LCount - 1 do
    Result[LIndex + 1] := Char(StrToIntDef('$' + Copy(AHex, LIndex * 4 + 1, 4), Ord('?')));
end;

function BrokerValue(const AText: string): string;
begin
  // One line per value
  Result := StringReplace(StringReplace(AText, #13, ' ', [rfReplaceAll]), #10, ' ', [rfReplaceAll]);
end;

function SendBrokerData(ATarget, ASender: HWND; AEvent: Integer; const AText: string;
  ATimeoutMs: Cardinal): Boolean;
var
  LData: TCopyDataStruct;
  LResult: DWORD_PTR;
begin
  LData.dwData := ULONG_PTR(AEvent);
  LData.cbData := DWORD(Length(AText) * SizeOf(Char));
  LData.lpData := PChar(AText);
  LResult := 0;
  Result := (SendMessageTimeout(ATarget, WM_COPYDATA, WPARAM(ASender), LPARAM(@LData),
    SMTO_ABORTIFHUNG or SMTO_NORMAL, ATimeoutMs, @LResult) <> 0) and (LResult = 1);
end;

function ReadBrokerData(const ACopyData: TCopyDataStruct): string;
begin
  SetString(Result, PChar(ACopyData.lpData), Integer(ACopyData.cbData) div SizeOf(Char));
end;

{ Broker side }

type
  TBrokerEvent = record
    Event: Integer;
    Text: string;
  end;

  TDockBroker = class
  private
    FSettings: TStringList;
    FContainer: HWND;
    FHostLink: HWND;
    FHostProcess: THandle;
    FCookie: Word;
    FSession: Integer;
    FMsgWnd: HWND;
    FPanel: TPanel;
    FDocker: TProcessDocker;
    FTimer: TTimer;
    FEvents: TList<TBrokerEvent>;
    FQuit: Boolean;
    FIdleSince: UInt64;
    FLastExitCode: DWORD;
    function Setting(const AName: string): string;
    function SettingInt(const AName: string; ADefault: Int64): Int64;
    procedure WndProc(var AMessage: TMessage);
    procedure HandleCommand(ACommand: Word; AArgument: LPARAM);
    procedure Send(AEvent: Integer; const AFields: array of string);
    procedure Flush;
    procedure Tick(Sender: TObject);
    procedure FollowContainer;
    procedure SetContainer(AContainer: HWND);
    procedure StartGuest;
    procedure HostGone(const AReason: string);
    procedure DockerLog(Sender: TObject; const AText: string);
    procedure DockerDocked(Sender: TObject);
    procedure DockerDockFailed(Sender: TObject; const AReason: string);
    procedure DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
    procedure DockerResponding(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
    procedure DockerEmergencyKill(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
    procedure DockerTitleChange(Sender: TObject; const AText: string);
    procedure DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD;
      AExpected: Boolean);
  public
    constructor Create(const ASettingsText: string);
    destructor Destroy; override;
    procedure Run;
    property LastExitCode: DWORD read FLastExitCode;
  end;

function BoolStr(AValue: Boolean): string;
begin
  if AValue then
    Result := '1'
  else
    Result := '0';
end;

constructor TDockBroker.Create(const ASettingsText: string);
begin
  inherited Create;
  FSettings := TStringList.Create;
  FSettings.Text := ASettingsText;
  FEvents := TList<TBrokerEvent>.Create;
  FContainer := HWND(SettingInt('container', 0));
  FHostLink := HWND(SettingInt('link', 0));
  FCookie := Word(SettingInt('cookie', 0));
  FSession := Integer(SettingInt('session', 0));
end;

destructor TDockBroker.Destroy;
begin
  FreeAndNil(FTimer);
  // Applies the shutdown action (kill by default; KillOnHostExit job as a safety net)
  FreeAndNil(FDocker);
  FreeAndNil(FPanel);
  if FMsgWnd <> 0 then
    DeallocateHWnd(FMsgWnd);
  if FHostProcess <> 0 then
    CloseHandle(FHostProcess);
  FEvents.Free;
  FSettings.Free;
  inherited Destroy;
end;

function TDockBroker.Setting(const AName: string): string;
begin
  Result := FSettings.Values[AName];
end;

function TDockBroker.SettingInt(const AName: string; ADefault: Int64): Int64;
begin
  Result := StrToInt64Def(Setting(AName), ADefault);
end;

procedure TDockBroker.Send(AEvent: Integer; const AFields: array of string);
var
  LText: TStringList;
  LField: string;
  LEvent: TBrokerEvent;
begin
  LText := TStringList.Create;
  try
    LText.Add('cookie=' + IntToStr(FCookie));
    LText.Add('session=' + IntToStr(FSession));
    for LField in AFields do
      LText.Add(BrokerValue(LField));
    LEvent.Event := AEvent;
    LEvent.Text := LText.Text;
  finally
    LText.Free;
  end;
  FEvents.Add(LEvent);
  Flush;
end;

procedure TDockBroker.Flush;
begin
  // In order; whatever the host does not take now (busy / hung) is retried on the next tick
  while FEvents.Count > 0 do
  begin
    if not SendBrokerData(FHostLink, FMsgWnd, FEvents[0].Event, FEvents[0].Text, EVENT_SEND_TIMEOUT_MS) then
      Break;
    FEvents.Delete(0);
  end;
end;

procedure TDockBroker.WndProc(var AMessage: TMessage);
begin
  if (AMessage.Msg = BrokerCommandMessage) and (HiWord(AMessage.WParam) = FCookie) then
  begin
    HandleCommand(LoWord(AMessage.WParam), AMessage.LParam);
    AMessage.Result := 0;
  end
  else
    AMessage.Result := DefWindowProc(FMsgWnd, AMessage.Msg, AMessage.WParam, AMessage.LParam);
end;

procedure TDockBroker.HandleCommand(ACommand: Word; AArgument: LPARAM);
begin
  case ACommand of
    BROKER_CMD_START:
      if not FDocker.IsRunning then
      begin
        FSession := Integer(AArgument);
        StartGuest;
      end;
    BROKER_CMD_CLOSE:
      FDocker.RequestClose;
    BROKER_CMD_KILL:
      if not FDocker.Kill then
        Send(BROKER_EVT_LOG, ['text=Broker could not kill the process']);
    BROKER_CMD_SUSPEND:
      FDocker.SuspendProcess;
    BROKER_CMD_RESUME:
      FDocker.ResumeProcess;
    BROKER_CMD_FOCUS:
      FDocker.FocusDockedWindow;
    BROKER_CMD_LAYOUT:
      FollowContainer;
    BROKER_CMD_CONTAINER:
      SetContainer(HWND(AArgument));
    BROKER_CMD_SHUTDOWN:
      begin
        if (AArgument >= Ord(Low(TDockShutdownAction))) and (AArgument <= Ord(High(TDockShutdownAction))) then
          FDocker.ShutdownAction := TDockShutdownAction(AArgument);
        FQuit := True;
      end;
  end;
end;

procedure TDockBroker.FollowContainer;
var
  LRect: TRect;
begin
  if not FPanel.HandleAllocated or not IsWindow(FContainer) then
    Exit;
  GetClientRect(FContainer, LRect);
  if (FPanel.Left <> 0) or (FPanel.Top <> 0) or (FPanel.Width <> LRect.Width) or (FPanel.Height <> LRect.Height) then
    FPanel.SetBounds(0, 0, LRect.Width, LRect.Height);
end;

procedure TDockBroker.SetContainer(AContainer: HWND);
begin
  // The host re-created its container window: ours was destroyed with it and the
  // application was parked. Create our panel in the new container, that docks it again.
  if not IsWindow(AContainer) then
    Exit;
  FContainer := AContainer;
  FPanel.ParentWindow := AContainer;
  FPanel.HandleNeeded;
  if Assigned(FDocker.Container) then
    FDocker.Container.HandleNeeded;
  FDocker.EmergencyWatchWindow := GetAncestor(AContainer, GA_ROOT);
  FollowContainer;
end;

procedure TDockBroker.StartGuest;
begin
  FIdleSince := 0;
  try
    FDocker.Start;
    Send(BROKER_EVT_STARTED, ['pid=' + IntToStr(FDocker.LaunchedProcessId)]);
  except
    on E: Exception do
    begin
      FIdleSince := GetTickCount64;
      Send(BROKER_EVT_STARTFAILED, ['reason=' + E.Message]);
    end;
  end;
end;

procedure TDockBroker.HostGone(const AReason: string);
begin
  // Nobody to report to: make sure nothing elevated is left behind
  FDocker.ShutdownAction := dsaKill;
  if FDocker.IsRunning then
    FDocker.Kill;
  FQuit := True;
end;

procedure TDockBroker.Tick(Sender: TObject);
begin
  if FQuit then
    Exit;

  if ((FHostProcess <> 0) and (WaitForSingleObject(FHostProcess, 0) = WAIT_OBJECT_0)) then
  begin
    HostGone('host process ended');
    Exit;
  end;
  if not IsWindow(FHostLink) then
  begin
    HostGone('host link window is gone');
    Exit;
  end;

  Flush;
  FollowContainer;

  if not FDocker.IsRunning and (FIdleSince <> 0) and (GetTickCount64 - FIdleSince > IDLE_QUIT_MS) then
    FQuit := True;
end;

{ Docker events -> host }

procedure TDockBroker.DockerLog(Sender: TObject; const AText: string);
begin
  Send(BROKER_EVT_LOG, ['text=' + AText]);
end;

procedure TDockBroker.DockerDocked(Sender: TObject);
var
  LInfo: TDockedProcessInfo;
  LRect: TRect;
begin
  LInfo := FDocker.GetInfo;
  LRect := FDocker.OriginalClientRect;
  Send(BROKER_EVT_DOCKED, [
    'wnd=' + IntToStr(NativeUInt(FDocker.WindowHandle)),
    'pid=' + IntToStr(FDocker.WindowProcessId),
    'launchedpid=' + IntToStr(FDocker.LaunchedProcessId),
    'class=' + LInfo.WindowClassName,
    'procname=' + LInfo.WindowProcessName,
    'title=' + LInfo.WindowTitle,
    'foreign=' + BoolStr(LInfo.WindowIsForeign),
    'elevated=' + BoolStr(IsCurrentProcessElevated),
    'style=' + IntToStr(FDocker.OriginalWindowStyle),
    'clientleft=' + IntToStr(LRect.Left),
    'clienttop=' + IntToStr(LRect.Top),
    'clientright=' + IntToStr(LRect.Right),
    'clientbottom=' + IntToStr(LRect.Bottom)]);
end;

procedure TDockBroker.DockerDockFailed(Sender: TObject; const AReason: string);
begin
  Send(BROKER_EVT_DOCKFAILED, ['reason=' + AReason, 'running=' + BoolStr(FDocker.IsRunning)]);
  if not FDocker.IsRunning then
    FIdleSince := GetTickCount64;
end;

procedure TDockBroker.DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
begin
  // The host decides (OnHung there) and sends a command
  AAction := dhaNone;
  Send(BROKER_EVT_HUNG, ['ms=' + IntToStr(AInfo.UnresponsiveMs)]);
end;

procedure TDockBroker.DockerResponding(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
begin
  Send(BROKER_EVT_RESPONDING, ['ms=' + IntToStr(AUnresponsiveMs)]);
end;

procedure TDockBroker.DockerEmergencyKill(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
begin
  Send(BROKER_EVT_EMERGENCY, ['ms=' + IntToStr(AUnresponsiveMs)]);
end;

procedure TDockBroker.DockerTitleChange(Sender: TObject; const AText: string);
begin
  Send(BROKER_EVT_TITLE, ['title=' + AText]);
end;

procedure TDockBroker.DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD;
  AExpected: Boolean);
begin
  FLastExitCode := AExitCode;
  FIdleSince := GetTickCount64;
  Send(BROKER_EVT_EXITED, ['code=' + UIntToStr(AExitCode), 'expected=' + BoolStr(AExpected)]);
end;

procedure TDockBroker.Run;
var
  LHostPid: DWORD;
begin
  FMsgWnd := AllocateHWnd(WndProc);
  // Let the (lower integrity) host post commands to us, nothing else
  ChangeWindowMessageFilterEx(FMsgWnd, BrokerCommandMessage, MSGFLT_ALLOW, nil);

  LHostPid := DWORD(SettingInt('hostpid', 0));
  FHostProcess := OpenProcess(SYNCHRONIZE, False, LHostPid);

  Send(BROKER_EVT_HELLO, ['wnd=' + IntToStr(NativeUInt(FMsgWnd)), 'pid=' + IntToStr(GetCurrentProcessId),
    'elevated=' + BoolStr(IsCurrentProcessElevated)]);

  if not IsWindow(FContainer) or (FHostProcess = 0) then
  begin
    Send(BROKER_EVT_STARTFAILED, ['reason=Broker: the host window or process is gone']);
    Flush;
    Exit;
  end;

  // A panel of ours inside the host's container: allowed, we are the higher integrity side
  FPanel := TPanel.CreateParented(FContainer);
  FPanel.BevelOuter := bvNone;
  FPanel.ParentBackground := False;
  FPanel.Color := TColor(SettingInt('color', clBtnFace));
  FPanel.HandleNeeded;
  FollowContainer;

  FDocker := TProcessDocker.Create(nil);
  FDocker.HostControl := FPanel;
  FDocker.FileName := Setting('file');
  FDocker.Parameters := Setting('params');
  FDocker.WorkingDirectory := Setting('dir');
  FDocker.StartHidden := Setting('starthidden') = '1';
  FDocker.WindowClassName := Setting('class');
  FDocker.WindowProcessName := Setting('procname');
  FDocker.AcceptForeignWindows := Setting('foreign') = '1';
  FDocker.FindWindowTimeoutMs := Cardinal(SettingInt('findtimeout', 10000));
  FDocker.UseChildStyle := Setting('childstyle') = '1';
  FDocker.RemoveWindowFrame := Setting('removeframe') = '1';
  FDocker.FocusOnDock := Setting('focusondock') = '1';
  FDocker.AllowKillForeignProcess := Setting('allowkillforeign') = '1';
  FDocker.KillOnHostExit := True;
  // Closing / hang reactions are decided by the host, the broker only executes them
  FDocker.KillAfterCloseTimeout := False;
  FDocker.CloseTimeoutMs := Cardinal(SettingInt('closetimeout', 5000));
  FDocker.HangAction := dhaNone;
  FDocker.RestartOnUnexpectedExit := False;
  FDocker.ShutdownAction := dsaKill;
  FDocker.ShowStatusText := False;
  FDocker.Color := FPanel.Color;
  FDocker.HangDetection := Setting('hangdetection') = '1';
  FDocker.HangTimeoutMs := Cardinal(SettingInt('hangtimeout', 0));
  FDocker.PollIntervalMs := Cardinal(SettingInt('poll', 1000));
  FDocker.EmergencyKillTimeoutMs := Cardinal(SettingInt('emergency', 0));
  // While the application is hung, also kill it when the HOST form is blocked by it
  FDocker.EmergencyWatchWindow := GetAncestor(FContainer, GA_ROOT);

  FDocker.OnLog := DockerLog;
  FDocker.OnDocked := DockerDocked;
  FDocker.OnDockFailed := DockerDockFailed;
  FDocker.OnHung := DockerHung;
  FDocker.OnResponding := DockerResponding;
  FDocker.OnEmergencyKill := DockerEmergencyKill;
  FDocker.OnTitleChange := DockerTitleChange;
  FDocker.OnProcessExit := DockerProcessExit;

  FTimer := TTimer.Create(nil);
  FTimer.Interval := 100;
  FTimer.OnTimer := Tick;

  StartGuest;

  while not FQuit and not Application.Terminated do
    Application.HandleMessage;

  Flush;
end;

function RunProcessDockerBroker: Boolean;
var
  LIndex: Integer;
  LData: string;
  LBroker: TDockBroker;
begin
  Result := False;
  LData := '';
  for LIndex := 1 to ParamCount - 1 do
    if SameText(ParamStr(LIndex), '/' + BROKER_SWITCH) or SameText(ParamStr(LIndex), '-' + BROKER_SWITCH) then
    begin
      LData := ParamStr(LIndex + 1);
      Result := True;
      Break;
    end;

  if not Result then
  begin
    GEntryPointReady := True;
    Exit;
  end;

  LBroker := TDockBroker.Create(DecodeBrokerData(LData));
  try
    try
      LBroker.Run;
    except
      on E: Exception do
      begin
        LBroker.Send(BROKER_EVT_STARTFAILED, ['reason=Broker: ' + E.Message]);
        LBroker.Flush;
      end;
    end;
    ExitCode := Integer(LBroker.LastExitCode);
  finally
    LBroker.Free;
  end;
end;

function IsBrokerEntryPointReady: Boolean;
begin
  Result := GEntryPointReady;
end;

end.
