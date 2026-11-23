program ElevatedBrokerTest;

{
  Integration test for TProcessDocker.BrokerMode: an application of HIGHER integrity
  docked into a host of LOWER integrity through the broker.

  No UAC prompt needed: the host runs at LOW integrity, the broker and the application
  at MEDIUM (normal). Windows applies the same UIPI rules as between a normal and an
  elevated process. A LOW process can not start a MEDIUM one, so the host's
  TProcessDocker.BrokerLaunchHook asks the driver (this exe, MEDIUM) to do it; in real
  use that is ShellExecuteEx("runas").

    ElevatedBrokerTest.exe                      runs all scenarios
    ElevatedBrokerTest.exe real <exe> [params]  real thing: UAC prompt, TProcessDockForm
}

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.StrUtils,
  System.Generics.Collections, Vcl.Forms, Vcl.Controls, Vcl.ExtCtrls, Vcl.Graphics,
  ProcessToFormDocker.WinApi in '..\..\Source\ProcessToFormDocker.WinApi.pas',
  ProcessToFormDocker.Watchdog in '..\..\Source\ProcessToFormDocker.Watchdog.pas',
  ProcessToFormDocker in '..\..\Source\ProcessToFormDocker.pas',
  ProcessToFormDocker.Broker in '..\..\Source\ProcessToFormDocker.Broker.pas',
  ProcessToFormDocker.Form in '..\..\Source\ProcessToFormDocker.Form.pas';

const
  DRIVER_LAUNCH = 1;
  DRIVER_PIDS = 2;
  MSGFLT_ALLOW = 1;

type
  TTokenMandatoryLabel = record
    Label_: TSIDAndAttributes;
  end;

function ChangeWindowMessageFilterEx(AWnd: HWND; AMessage: UINT; AAction: DWORD;
  AChangeFilterStruct: Pointer): BOOL; stdcall; external user32;

var
  Role: string;

procedure Say(const AText: string);
begin
  Writeln(Format('[%s] %-6s %s', [FormatDateTime('nn:ss.zzz', Now), Role, AText]));
  Flush(Output);
end;

function IntegrityName: string;
var
  LToken: THandle;
  LBuffer: array[0..255] of Byte;
  LLength: DWORD;
  LSid: PSID;
begin
  Result := '?';
  if not OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, LToken) then
    Exit;
  try
    if GetTokenInformation(LToken, TokenIntegrityLevel, @LBuffer, SizeOf(LBuffer), LLength) then
    begin
      LSid := PSIDAndAttributes(@LBuffer)^.Sid;
      case GetSidSubAuthority(LSid, GetSidSubAuthorityCount(LSid)^ - 1)^ of
        $1000: Result := 'LOW';
        $2000: Result := 'MEDIUM';
        $3000: Result := 'HIGH';
      end;
    end;
  finally
    CloseHandle(LToken);
  end;
end;

function SendCopyData(ATarget: HWND; AKind: Integer; const AText: string; out AResult: DWORD_PTR): Boolean;
var
  LData: TCopyDataStruct;
begin
  LData.dwData := ULONG_PTR(AKind);
  LData.cbData := DWORD(Length(AText) * SizeOf(Char));
  LData.lpData := PChar(AText);
  AResult := 0;
  Result := SendMessageTimeout(ATarget, WM_COPYDATA, 0, LPARAM(@LData), SMTO_NORMAL, 15000, @AResult) <> 0;
end;

{ ------------------------------------------------------------------ HOST (LOW integrity) }

var
  DriverWnd: HWND;
  BrokerLaunches: Integer;

function LaunchBrokerThroughDriver(const AFileName, AParameters: string; AElevated: Boolean): THandle;
var
  LResult: DWORD_PTR;
begin
  Inc(BrokerLaunches);
  Say(Format('broker launch #%d requested (elevated=%s)', [BrokerLaunches, BoolToStr(AElevated, True)]));
  if not SendCopyData(DriverWnd, DRIVER_LAUNCH, Format('"%s" %s', [AFileName, AParameters]), LResult) then
    Exit(0);
  Result := THandle(LResult);
end;

procedure ReportPids(ADocker: TProcessDocker);
var
  LResult: DWORD_PTR;
begin
  SendCopyData(DriverWnd, DRIVER_PIDS, Format('%d %d', [ADocker.LaunchedProcessId, ADocker.WindowProcessId]), LResult);
end;

type
  THostForm = class(TForm)
  private
    FPanelA: TPanel;
    FPanelB: TPanel;
    FDocker: TProcessDocker;
    FTimer: TTimer;
    FScenario: string;
    FTicks: Integer;
    FDockCount: Integer;
    FExitCount: Integer;
    procedure Tick(Sender: TObject);
    procedure DockerLog(Sender: TObject; const AText: string);
    procedure DockerDocked(Sender: TObject);
    procedure DockerDockFailed(Sender: TObject; const AReason: string);
    procedure DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
    procedure DockerEmergency(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
    procedure DockerExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD; AExpected: Boolean);
    procedure CheckFill(const AWhen: string; AHost: TWinControl);
    procedure Finish(ACode: Integer);
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  HostForm: THostForm;

constructor THostForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'Broker integration test host (' + IntegrityName + ' integrity)';
  SetBounds(100, 100, 1000, 560);
  FScenario := ParamStr(2);

  FPanelB := TPanel.Create(Self);
  FPanelB.Parent := Self;
  FPanelB.Align := alRight;
  FPanelB.Width := 420;
  FPanelB.Caption := 'panel B';
  FPanelA := TPanel.Create(Self);
  FPanelA.Parent := Self;
  FPanelA.Align := alClient;
  FPanelA.Caption := 'panel A';

  FDocker := TProcessDocker.Create(Self);
  FDocker.HostControl := FPanelA;
  FDocker.BrokerMode := dbmAlways;
  FDocker.ApplyPreset(dpClassicCmd);
  FDocker.Color := clBlack;
  FDocker.OnLog := DockerLog;
  FDocker.OnDocked := DockerDocked;
  FDocker.OnDockFailed := DockerDockFailed;
  FDocker.OnHung := DockerHung;
  FDocker.OnEmergencyKill := DockerEmergency;
  FDocker.OnProcessExit := DockerExit;

  if FScenario = 'selfexit' then
    FDocker.Parameters := 'cmd.exe /c echo Exiting with 42 & ping -n 4 127.0.0.1 >nul & exit 42'
  else if FScenario = 'restart' then
  begin
    FDocker.Parameters := 'cmd.exe /c echo Crashing with 3 & ping -n 3 127.0.0.1 >nul & exit 3';
    FDocker.RestartOnUnexpectedExit := True;
    FDocker.RestartDelayMs := 300;
    FDocker.MaxRestarts := 1;
  end
  else
    FDocker.Parameters := 'cmd.exe /k echo Shown through the broker, scenario ' + FScenario;

  if FScenario = 'hangkill' then
  begin
    FDocker.HangTimeoutMs := 2000;
    FDocker.PollIntervalMs := 250;
    FDocker.HangAction := dhaKill;
  end
  else if FScenario = 'emergency' then
  begin
    FDocker.HangTimeoutMs := 2000;
    FDocker.PollIntervalMs := 250;
    FDocker.EmergencyKillTimeoutMs := 4000;
  end;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := 500;
  FTimer.OnTimer := Tick;
end;

procedure THostForm.Finish(ACode: Integer);
begin
  Say(Format('broker launches: %d', [BrokerLaunches]));
  ExitCode := ACode;
  FTimer.Enabled := False;
  Application.Terminate;
end;

procedure THostForm.DockerLog(Sender: TObject; const AText: string);
begin
  Say('  log: ' + AText);
end;

procedure THostForm.DockerDocked(Sender: TObject);
begin
  Inc(FDockCount);
  FTicks := 0;
  Say(Format('OnDocked #%d: brokered=%s docked=%s window $%x class %s pid %d', [FDockCount,
    BoolToStr(FDocker.IsBrokered, True), BoolToStr(FDocker.IsDocked, True), FDocker.WindowHandle,
    FDocker.GetInfo.WindowClassName, FDocker.WindowProcessId]));
  ReportPids(FDocker);
end;

procedure THostForm.DockerDockFailed(Sender: TObject; const AReason: string);
begin
  Say('OnDockFailed: ' + AReason);
  if not FDocker.IsRunning then
    Finish(200);
end;

procedure THostForm.DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
begin
  Say(Format('OnHung: unresponsive %d ms, action %d', [AInfo.UnresponsiveMs, Ord(AAction)]));
end;

procedure THostForm.DockerEmergency(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
begin
  Say(Format('OnEmergencyKill: unresponsive %d ms', [AUnresponsiveMs]));
end;

procedure THostForm.DockerExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD; AExpected: Boolean);
begin
  Inc(FExitCount);
  Say(Format('OnProcessExit #%d: exit code %u ($%x), expected %s', [FExitCount, AExitCode, AExitCode,
    BoolToStr(AExpected, True)]));
  if FScenario = 'restart' then
  begin
    // First exit: restarted through the same broker. Second: crash loop limit (1) reached.
    if FExitCount >= 2 then
      Finish(Integer(AExitCode));
  end
  else
    Finish(Integer(AExitCode));
end;

procedure THostForm.CheckFill(const AWhen: string; AHost: TWinControl);
var
  LGuest: TRect;
  LHost: TRect;
begin
  GetWindowRect(FDocker.WindowHandle, LGuest);
  // The docker's container fills the host control (inside the panel bevel)
  LHost := FDocker.Container.ClientRect;
  MapWindowPoints(FDocker.Container.Handle, 0, LHost, 2);
  Say(Format('%s: guest %dx%d at (%d,%d), host area %dx%d at (%d,%d), inside %s -> %s', [AWhen,
    LGuest.Width, LGuest.Height, LGuest.Left, LGuest.Top, LHost.Width, LHost.Height, LHost.Left, LHost.Top,
    IfThen(AHost = FPanelA, 'panel A', 'panel B'),
    IfThen((LGuest = LHost) and IsChild(AHost.Handle, FDocker.WindowHandle) and (FDocker.Container.Parent = AHost), 'OK', 'MISMATCH')]));
end;

procedure THostForm.Tick(Sender: TObject);
var
  LStart: UInt64;
begin
  if FDocker = nil then
  begin
    // 'destroy': no events any more, just give the broker time and end
    Inc(FTicks);
    if FTicks > 8 then
      Finish(0);
    Exit;
  end;
  if not FDocker.IsDocked then
    Exit;
  Inc(FTicks);

  if FScenario = 'close' then
    case FTicks of
      2: CheckFill('docked', FPanelA);
      3: SetBounds(Left, Top, Width + 160, Height + 90);
      5: CheckFill('after the host form was resized', FPanelA);
      6:
        begin
          Say('RequestClose');
          FDocker.RequestClose;
        end;
    end
  else if FScenario = 'move' then
    case FTicks of
      2: CheckFill('docked', FPanelA);
      3:
        begin
          Say('HostControl := panel B (the host re-creates its container window)');
          FDocker.HostControl := FPanelB;
        end;
      6: CheckFill('after moving', FPanelB);
      7: FDocker.RequestClose;
    end
  else if FScenario = 'hangkill' then
  begin
    if FTicks = 2 then
    begin
      Say('SuspendProcess (simulated hang), HangAction = dhaKill');
      FDocker.SuspendProcess;
    end;
  end
  else if FScenario = 'emergency' then
    case FTicks of
      2:
        begin
          Say('SuspendProcess (simulated hang), emergency kill 4000 ms');
          FDocker.SuspendProcess;
        end;
      5:
        begin
          Say('host moves the focus while the application is hung...');
          LStart := GetTickCount64;
          Winapi.Windows.SetFocus(FPanelB.Handle);
          Say(Format('... SetFocus returned after %d ms', [GetTickCount64 - LStart]));
        end;
    end
  else if FScenario = 'destroy' then
  begin
    if FTicks = 2 then
    begin
      Say('freeing the docker while the application runs (ShutdownAction = dsaCloseThenKill)');
      FreeAndNil(FDocker);
    end;
  end;
end;

procedure RunFormScenario;
var
  LResult: TProcessFormResult;
begin
  LResult := TProcessDockForm.ExecuteEx(TProcessDocker.PresetInfo(dpClassicCmd).FileName,
    'cmd.exe /c echo TProcessDockForm through the broker & ping -n 4 127.0.0.1 >nul & exit 42',
    procedure(AForm: TProcessDockForm)
    begin
      AForm.Docker.BrokerMode := dbmAlways;
      AForm.Docker.OnLog := HostForm.DockerLog;
    end);
  Say(Format('TProcessDockForm.ExecuteEx: Started=%s ExitCode=%u WasDocked=%s Error="%s"',
    [BoolToStr(LResult.Started, True), LResult.ExitCode, BoolToStr(LResult.WasDocked, True), LResult.ErrorMessage]));
  ExitCode := Integer(LResult.ExitCode);
end;

procedure RunHost;
begin
  Say('host started, integrity ' + IntegrityName);
  DriverWnd := HWND(StrToInt64(ParamStr(3)));
  TProcessDocker.BrokerLaunchHook := LaunchBrokerThroughDriver;
  Application.Initialize;
  Application.CreateForm(THostForm, HostForm);
  if ParamStr(2) = 'form' then
  begin
    RunFormScenario;
    Say(Format('broker launches: %d', [BrokerLaunches]));
    Exit;
  end;
  HostForm.Show;
  try
    HostForm.FDocker.Start;
  except
    on E: Exception do
    begin
      Say('Start raised: ' + E.Message);
      ExitCode := 201;
      Exit;
    end;
  end;
  Application.Run;
end;

{ ------------------------------------------------------------------ DRIVER (MEDIUM) }

type
  TDriver = class
  public
    Wnd: HWND;
    Host: TProcessInformation;
    Brokers: TList<THandle>;
    GuestPids: TList<DWORD>;
    constructor Create;
    destructor Destroy; override;
    procedure WndProc(var AMessage: TMessage);
  end;

var
  Driver: TDriver;

procedure InheritableStdHandles(var AStartup: TStartupInfo);
begin
  SetHandleInformation(GetStdHandle(STD_OUTPUT_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  SetHandleInformation(GetStdHandle(STD_ERROR_HANDLE), HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  AStartup.dwFlags := AStartup.dwFlags or STARTF_USESTDHANDLES;
  AStartup.hStdOutput := GetStdHandle(STD_OUTPUT_HANDLE);
  AStartup.hStdError := GetStdHandle(STD_ERROR_HANDLE);
end;

constructor TDriver.Create;
begin
  Brokers := TList<THandle>.Create;
  GuestPids := TList<DWORD>.Create;
  Wnd := AllocateHWnd(WndProc);
  // The LOW host may send us WM_COPYDATA (broker launch requests, pids)
  ChangeWindowMessageFilterEx(Wnd, WM_COPYDATA, MSGFLT_ALLOW, nil);
end;

destructor TDriver.Destroy;
begin
  DeallocateHWnd(Wnd);
  Brokers.Free;
  GuestPids.Free;
  inherited Destroy;
end;

procedure TDriver.WndProc(var AMessage: TMessage);
var
  LData: PCopyDataStruct;
  LText: string;
  LStartup: TStartupInfo;
  LInfo: TProcessInformation;
  LDuplicate: THandle;
  LParts: TArray<string>;
  LPart: string;
begin
  if AMessage.Msg <> WM_COPYDATA then
  begin
    AMessage.Result := DefWindowProc(Wnd, AMessage.Msg, AMessage.WParam, AMessage.LParam);
    Exit;
  end;

  LData := PCopyDataStruct(AMessage.LParam);
  SetString(LText, PChar(LData.lpData), Integer(LData.cbData) div SizeOf(Char));
  AMessage.Result := 0;
  case LData.dwData of
    DRIVER_LAUNCH:
      begin
        LStartup := Default(TStartupInfo);
        LStartup.cb := SizeOf(LStartup);
        InheritableStdHandles(LStartup);
        UniqueString(LText);
        if CreateProcess(nil, PChar(LText), nil, nil, True, 0, nil, nil, LStartup, LInfo) then
        begin
          CloseHandle(LInfo.hThread);
          Brokers.Add(LInfo.hProcess);
          // Give the LOW host a handle to the MEDIUM broker process
          if DuplicateHandle(GetCurrentProcess, LInfo.hProcess, Host.hProcess, @LDuplicate,
            SYNCHRONIZE or $1000 {PROCESS_QUERY_LIMITED_INFORMATION}, False, 0) then
            AMessage.Result := LRESULT(LDuplicate);
          Say(Format('started broker pid %d at MEDIUM integrity for the host', [LInfo.dwProcessId]));
        end
        else
          Say('broker launch failed: ' + SysErrorMessage(GetLastError));
      end;
    DRIVER_PIDS:
      begin
        LParts := LText.Split([' ']);
        for LPart in LParts do
          if (StrToIntDef(LPart, 0) <> 0) and not GuestPids.Contains(DWORD(StrToInt(LPart))) then
            GuestPids.Add(DWORD(StrToInt(LPart)));
      end;
  end;
end;

function StartLowIntegrity(const ACommandLine: string): TProcessInformation;
var
  LStartup: TStartupInfo;
  LCommandLine: string;
  LToken: THandle;
  LLowToken: THandle;
  LSid: PSID;
  LLabel: TTokenMandatoryLabel;
begin
  LStartup := Default(TStartupInfo);
  LStartup.cb := SizeOf(LStartup);
  InheritableStdHandles(LStartup);
  LCommandLine := ACommandLine;
  UniqueString(LCommandLine);
  Win32Check(OpenProcessToken(GetCurrentProcess, TOKEN_DUPLICATE or TOKEN_ADJUST_DEFAULT or TOKEN_QUERY
    or TOKEN_ASSIGN_PRIMARY, LToken));
  try
    Win32Check(DuplicateTokenEx(LToken, 0, nil, SecurityImpersonation, TokenPrimary, LLowToken));
    try
      Win32Check(ConvertStringSidToSid('S-1-16-4096', LSid));
      try
        LLabel.Label_.Sid := LSid;
        LLabel.Label_.Attributes := SE_GROUP_INTEGRITY;
        Win32Check(SetTokenInformation(LLowToken, TokenIntegrityLevel, @LLabel, SizeOf(LLabel) + GetLengthSid(LSid)));
      finally
        LocalFree(HLOCAL(LSid));
      end;
      Result := Default(TProcessInformation);
      Win32Check(CreateProcessAsUser(LLowToken, nil, PChar(LCommandLine), nil, nil, True, 0, nil, nil,
        LStartup, Result));
    finally
      CloseHandle(LLowToken);
    end;
  finally
    CloseHandle(LToken);
  end;
end;

function IsPidAlive(APid: DWORD): Boolean;
var
  LProcess: THandle;
begin
  LProcess := OpenProcess(SYNCHRONIZE, False, APid);
  Result := (LProcess <> 0) and (WaitForSingleObject(LProcess, 0) = WAIT_TIMEOUT);
  if LProcess <> 0 then
    CloseHandle(LProcess);
end;

function FindHostForm(APid: DWORD): HWND;
var
  LWnd: HWND;
begin
  for LWnd in GetTopLevelWindows do
    if (GetWindowProcessId(LWnd) = APid) and IsWindowVisible(LWnd)
      and MatchText(GetWindowClassNameStr(LWnd), ['THostForm', 'TProcessDockForm']) then
      Exit(LWnd);
  Result := 0;
end;

procedure Pump(AMs: Cardinal);
var
  LEnd: UInt64;
  LMsg: TMsg;
begin
  LEnd := GetTickCount64 + AMs;
  repeat
    while PeekMessage(LMsg, 0, 0, 0, PM_REMOVE) do
    begin
      TranslateMessage(LMsg);
      DispatchMessage(LMsg);
    end;
    MsgWaitForMultipleObjects(0, Pointer(nil)^, False, 20, QS_ALLINPUT);
  until GetTickCount64 >= LEnd;
end;

procedure Scenario(const ATitle, AName: string; AKillHostAfterMs: Integer = 0; APingHost: Boolean = False);
var
  LStart: UInt64;
  LHostWnd: HWND;
  LReply: DWORD_PTR;
  LResponsive: Integer;
  LLast: Integer;
  LCode: DWORD;
  LBroker: THandle;
  LPid: DWORD;
begin
  Writeln;
  Writeln('=== ', ATitle);
  Flush(Output);
  Driver.Brokers.Clear;
  Driver.GuestPids.Clear;
  Driver.Host := StartLowIntegrity(Format('"%s" host %s %d', [ParamStr(0), AName, Driver.Wnd]));

  LStart := GetTickCount64;
  LLast := -1;
  LHostWnd := 0;
  while WaitForSingleObject(Driver.Host.hProcess, 0) = WAIT_TIMEOUT do
  begin
    Pump(100);
    if LHostWnd = 0 then
      LHostWnd := FindHostForm(Driver.Host.dwProcessId);
    if APingHost and (LHostWnd <> 0) then
    begin
      LResponsive := Ord(SendMessageTimeout(LHostWnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 250, @LReply) <> 0);
      if LResponsive <> LLast then
        Say('host UI is ' + IfThen(LResponsive = 1, 'responsive', 'BLOCKED'));
      LLast := LResponsive;
    end;
    if (AKillHostAfterMs > 0) and (Driver.GuestPids.Count > 0) and (GetTickCount64 - LStart > UInt64(AKillHostAfterMs)) then
    begin
      Say('driver kills the host process (simulated crash)');
      TerminateProcess(Driver.Host.hProcess, 99);
      AKillHostAfterMs := 0;
    end;
    if GetTickCount64 - LStart > 40000 then
    begin
      Say('TIMEOUT, killing the host');
      TerminateProcess(Driver.Host.hProcess, 98);
    end;
  end;
  GetExitCodeProcess(Driver.Host.hProcess, LCode);
  Say(Format('host exit code %u ($%x)', [LCode, LCode]));

  for LBroker in Driver.Brokers do
  begin
    if WaitForSingleObject(LBroker, 10000) <> WAIT_OBJECT_0 then
    begin
      Say('broker did NOT exit, killing it');
      TerminateProcess(LBroker, 97);
    end;
    GetExitCodeProcess(LBroker, LCode);
    Say(Format('broker exited, exit code %u ($%x)', [LCode, LCode]));
    CloseHandle(LBroker);
  end;
  Sleep(300);
  for LPid in Driver.GuestPids do
    Say(Format('application pid %d still running: %s', [LPid, BoolToStr(IsPidAlive(LPid), True)]));

  CloseHandle(Driver.Host.hProcess);
  CloseHandle(Driver.Host.hThread);
end;

procedure RunDriver;
begin
  Say('driver integrity ' + IntegrityName + ', host runs at LOW integrity, broker + application at MEDIUM');
  Driver := TDriver.Create;
  try
    Scenario('1. Dock through the broker, host resizes, RequestClose', 'close');
    Scenario('2. Application exits by itself with 42', 'selfexit');
    Scenario('3. Moving to another host control re-creates the container', 'move');
    Scenario('4. Hang: OnHung + HangAction dhaKill in the host', 'hangkill');
    Scenario('5. Hang blocks the host UI: emergency kill by the broker', 'emergency', 0, True);
    Scenario('6. RestartOnUnexpectedExit restarts through the same broker, crash loop limit 1', 'restart');
    Scenario('7. Host crashes: broker kills the application', 'crash', 3000);
    Scenario('8. Docker freed while the application runs', 'destroy');
    Scenario('9. TProcessDockForm.ExecuteEx through the broker', 'form');
  finally
    Driver.Free;
  end;
  Writeln;
  Say('done');
end;

{ ------------------------------------------------------------------ REAL (UAC) }

procedure RunReal;
var
  LResult: TProcessFormResult;
begin
  Say('host integrity ' + IntegrityName + ': starting ' + ParamStr(2) + ' elevated through the broker');
  Application.Initialize;
  LResult := TProcessDockForm.ExecuteEx(ParamStr(2), ParamStr(3),
    procedure(AForm: TProcessDockForm)
    begin
      AForm.Docker.RunElevated := True;
      AForm.Docker.BrokerMode := dbmWhenElevationNeeded;
      AForm.Docker.EmergencyKillTimeoutMs := 10000;
    end);
  Say(Format('Started=%s ExitCode=%u ($%x) WasDocked=%s ClosedByUser=%s Error="%s"',
    [BoolToStr(LResult.Started, True), LResult.ExitCode, LResult.ExitCode, BoolToStr(LResult.WasDocked, True),
     BoolToStr(LResult.ClosedByUser, True), LResult.ErrorMessage]));
end;

begin
  // Broker role: started by TProcessDocker with /ProcessDockerBroker
  if RunProcessDockerBroker then
    Exit;

  Role := LowerCase(ParamStr(1));
  if Role = '' then
    Role := 'driver';
  try
    if Role = 'host' then
      RunHost
    else if Role = 'real' then
      RunReal
    else
      RunDriver;
  except
    on E: Exception do
      Say('EXCEPTION ' + E.ClassName + ': ' + E.Message);
  end;
end.
