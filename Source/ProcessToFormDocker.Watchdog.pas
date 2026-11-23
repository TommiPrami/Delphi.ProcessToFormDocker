unit ProcessToFormDocker.Watchdog;

{
  Background thread that watches one docked session:
    - process exit / window destruction
    - window title changes
    - "Not responding" detection (IsHungAppWindow + WM_NULL ping with timeout)
    - optional emergency kill when the host UI thread itself is blocked

  Why a thread: a docked window of another process shares the input queue with the
  host (cross-process parent/child windows attach their input queues). When the
  docked app hangs, the host UI thread can get stuck too, so the watchdog must not
  depend on the host message loop. It never calls Synchronize, only Queue, so it
  never waits for the main thread.
}

interface

uses
  Winapi.Windows, System.Classes, System.SyncObjs, ProcessToFormDocker.WinApi;

type
  /// <summary>Callbacks from the watchdog. Always called in the main thread (TThread.Queue).</summary>
  IProcessDockerLink = interface
    ['{8C0B3F57-4B7D-4E57-9C3A-2E4D7A1B9F10}']
    procedure WatchdogSessionEnded(AWatchdogId: Integer);
    procedure WatchdogHung(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
    procedure WatchdogResponding(AWatchdogId: Integer; AUnresponsiveMs: Cardinal);
    procedure WatchdogTitleChanged(AWatchdogId: Integer; const ATitle: string);
    procedure WatchdogEmergencyKill(AWatchdogId: Integer; AUnresponsiveMs: Cardinal; AKilled: Boolean);
    /// <summary>Main thread must call TDockWatchdog.AcknowledgeHang to prove it is alive.</summary>
    procedure WatchdogHeartbeat(AWatchdogId: Integer);
  end;

  TDockWatchdogConfig = record
    Id: Integer;
    /// <summary>Docked window, 0 when there is no window (then only process exit is watched).</summary>
    Window: HWND;
    /// <summary>Process handle to wait on, owned by the watchdog (duplicate it). 0 = none.</summary>
    WaitProcess: THandle;
    PollIntervalMs: Cardinal;
    HangDetection: Boolean;
    HangTimeoutMs: Cardinal;
    PingTimeoutMs: Cardinal;
    /// <summary>0 = disabled. See TProcessDocker.EmergencyKillTimeoutMs.</summary>
    EmergencyKillTimeoutMs: Cardinal;
    /// <summary>Owned by the watchdog (duplicated handles).</summary>
    KillTargets: TKillTargets;
    InitialTitle: string;
  end;

  TDockWatchdog = class(TThread)
  private
    FConfig: TDockWatchdogConfig;
    FLink: IProcessDockerLink;
    FStopEvent: TEvent;
    FHangAcknowledged: Integer;
    procedure PostSessionEnded;
    procedure PostHung(AUnresponsiveMs: Cardinal);
    procedure PostResponding(AUnresponsiveMs: Cardinal);
    procedure PostTitle(const ATitle: string);
    procedure PostEmergencyKill(AUnresponsiveMs: Cardinal; AKilled: Boolean);
    procedure PostHeartbeat;
  protected
    procedure Execute; override;
  public
    constructor Create(const AConfig: TDockWatchdogConfig; const ALink: IProcessDockerLink);
    destructor Destroy; override;
    /// <summary>Signals the thread to stop. Does not wait.</summary>
    procedure Stop;
    /// <summary>Main thread is alive: acknowledges the hang notification or a heartbeat.</summary>
    procedure AcknowledgeHang;
    property Id: Integer read FConfig.Id;
  end;

implementation

{ TDockWatchdog }

constructor TDockWatchdog.Create(const AConfig: TDockWatchdogConfig; const ALink: IProcessDockerLink);
begin
  // Thread starts in AfterConstruction, so fields are ready before Execute
  inherited Create(False);
  FreeOnTerminate := False;
  FConfig := AConfig;
  if FConfig.PollIntervalMs < 50 then
    FConfig.PollIntervalMs := 50;
  if FConfig.PingTimeoutMs = 0 then
    FConfig.PingTimeoutMs := 1000;
  FLink := ALink;
  FStopEvent := TEvent.Create(nil, True, False, '');
end;

destructor TDockWatchdog.Destroy;
begin
  Stop;
  inherited Destroy;
  FStopEvent.Free;
  if FConfig.WaitProcess <> 0 then
    CloseHandle(FConfig.WaitProcess);
  FConfig.KillTargets.CloseHandles;
  FLink := nil;
end;

procedure TDockWatchdog.Stop;
begin
  Terminate;
  if Assigned(FStopEvent) then
    FStopEvent.SetEvent;
end;

procedure TDockWatchdog.AcknowledgeHang;
begin
  TInterlocked.Exchange(FHangAcknowledged, 1);
end;

procedure TDockWatchdog.PostSessionEnded;
var
  LLink: IProcessDockerLink;
  LId: Integer;
begin
  LLink := FLink;
  LId := FConfig.Id;
  Queue(
    procedure
    begin
      LLink.WatchdogSessionEnded(LId);
    end);
end;

procedure TDockWatchdog.PostHung(AUnresponsiveMs: Cardinal);
var
  LLink: IProcessDockerLink;
  LId: Integer;
begin
  LLink := FLink;
  LId := FConfig.Id;
  Queue(
    procedure
    begin
      LLink.WatchdogHung(LId, AUnresponsiveMs);
    end);
end;

procedure TDockWatchdog.PostResponding(AUnresponsiveMs: Cardinal);
var
  LLink: IProcessDockerLink;
  LId: Integer;
begin
  LLink := FLink;
  LId := FConfig.Id;
  Queue(
    procedure
    begin
      LLink.WatchdogResponding(LId, AUnresponsiveMs);
    end);
end;

procedure TDockWatchdog.PostTitle(const ATitle: string);
var
  LLink: IProcessDockerLink;
  LId: Integer;
  LTitle: string;
begin
  LLink := FLink;
  LId := FConfig.Id;
  LTitle := ATitle;
  Queue(
    procedure
    begin
      LLink.WatchdogTitleChanged(LId, LTitle);
    end);
end;

procedure TDockWatchdog.PostEmergencyKill(AUnresponsiveMs: Cardinal; AKilled: Boolean);
var
  LLink: IProcessDockerLink;
  LId: Integer;
begin
  LLink := FLink;
  LId := FConfig.Id;
  Queue(
    procedure
    begin
      LLink.WatchdogEmergencyKill(LId, AUnresponsiveMs, AKilled);
    end);
end;

procedure TDockWatchdog.PostHeartbeat;
var
  LLink: IProcessDockerLink;
  LId: Integer;
begin
  LLink := FLink;
  LId := FConfig.Id;
  Queue(
    procedure
    begin
      LLink.WatchdogHeartbeat(LId);
    end);
end;

procedure TDockWatchdog.Execute;
var
  LHandles: array[0..1] of THandle;
  LHandleCount: DWORD;
  LWaitResult: DWORD;
  LTitle: string;
  LNewTitle: string;
  LResponding: Boolean;
  LNow: UInt64;
  LUnresponsiveSince: UInt64;
  LHangReported: Boolean;
  LHeartbeatPending: Boolean;
  LHeartbeatSentAt: UInt64;
  LEmergencyDone: Boolean;
  LUnresponsiveMs: Cardinal;
  LKilled: Boolean;
begin
  NameThreadForDebugging('ProcessDocker.Watchdog');

  LHandles[0] := FStopEvent.Handle;
  LHandleCount := 1;
  if FConfig.WaitProcess <> 0 then
  begin
    LHandles[1] := FConfig.WaitProcess;
    LHandleCount := 2;
  end;

  LTitle := FConfig.InitialTitle;
  LUnresponsiveSince := 0;
  LHangReported := False;
  LHeartbeatPending := False;
  LHeartbeatSentAt := 0;
  LEmergencyDone := False;

  while not Terminated do
  begin
    LWaitResult := WaitForMultipleObjects(LHandleCount, @LHandles[0], False, FConfig.PollIntervalMs);

    if Terminated or (LWaitResult = WAIT_OBJECT_0) then
      Break;

    if (LHandleCount = 2) and (LWaitResult = WAIT_OBJECT_0 + 1) then
    begin
      PostSessionEnded;
      Break;
    end;

    if LWaitResult = WAIT_FAILED then
    begin
      // Should not happen, avoid a busy loop
      if FStopEvent.WaitFor(FConfig.PollIntervalMs) = wrSignaled then
        Break;
    end;

    if FConfig.Window = 0 then
      Continue;

    if not IsWindow(FConfig.Window) then
    begin
      PostSessionEnded;
      Break;
    end;

    LNewTitle := GetWindowTextStr(FConfig.Window);
    if LNewTitle <> LTitle then
    begin
      LTitle := LNewTitle;
      PostTitle(LTitle);
    end;

    if not FConfig.HangDetection then
      Continue;

    LResponding := not IsWindowHung(FConfig.Window) and PingWindow(FConfig.Window, FConfig.PingTimeoutMs);
    LNow := GetTickCount64;

    if not LResponding then
    begin
      if LUnresponsiveSince = 0 then
      begin
        // The ping already waited PingTimeoutMs without an answer
        if LNow > FConfig.PingTimeoutMs then
          LUnresponsiveSince := LNow - FConfig.PingTimeoutMs
        else
          LUnresponsiveSince := 1;
      end;

      LUnresponsiveMs := Cardinal(LNow - LUnresponsiveSince);

      if not LHangReported then
      begin
        if LUnresponsiveMs >= FConfig.HangTimeoutMs then
        begin
          LHangReported := True;
          // The hang notification is the first heartbeat
          TInterlocked.Exchange(FHangAcknowledged, 0);
          LHeartbeatPending := True;
          LHeartbeatSentAt := LNow;
          PostHung(LUnresponsiveMs);
        end;
      end
      else if not LEmergencyDone and (FConfig.EmergencyKillTimeoutMs > 0) then
      begin
        // While the docked window is hung the host UI thread can get blocked at any
        // moment (activation / focus messages are sent to the hung window through the
        // shared input queue). Keep sending heartbeats to the main thread for as long
        // as the hang lasts; if one is not processed in time, kill from here.
        if LHeartbeatPending and (TInterlocked.CompareExchange(FHangAcknowledged, 0, 0) <> 0) then
          LHeartbeatPending := False;

        if LHeartbeatPending then
        begin
          if LNow - LHeartbeatSentAt >= FConfig.EmergencyKillTimeoutMs then
          begin
            LEmergencyDone := True;
            LKilled := KillTargets(FConfig.KillTargets, 1);
            PostEmergencyKill(LUnresponsiveMs, LKilled);
          end;
        end
        else
        begin
          TInterlocked.Exchange(FHangAcknowledged, 0);
          LHeartbeatPending := True;
          LHeartbeatSentAt := LNow;
          PostHeartbeat;
        end;
      end;
    end
    else if LUnresponsiveSince <> 0 then
    begin
      if LHangReported then
        PostResponding(Cardinal(LNow - LUnresponsiveSince));

      LUnresponsiveSince := 0;
      LHangReported := False;
      LHeartbeatPending := False;
      LEmergencyDone := False;
    end;
  end;
end;

end.
