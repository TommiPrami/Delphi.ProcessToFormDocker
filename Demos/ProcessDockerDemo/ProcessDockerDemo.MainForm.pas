unit ProcessDockerDemo.MainForm;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, System.UITypes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  ProcessToFormDocker;

type
  /// <summary>One tab = one docked process</summary>
  TDockSheet = class(TTabSheet)
  public
    Docker: TProcessDocker;
    BaseCaption: string;
    SessionNo: Integer;
  end;

  TDemoEntry = record
    Caption: string;
    IsPreset: Boolean;
    Preset: TDockPreset;
    FileName: string;
    Parameters: string;
    Elevated: Boolean;
    DarkBackground: Boolean;
  end;

  TMainForm = class(TForm)
    FlowPanelLaunch: TFlowPanel;
    LabelPreset: TLabel;
    ComboBoxPreset: TComboBox;
    LabelFileName: TLabel;
    EditFileName: TEdit;
    LabelParameters: TLabel;
    EditParameters: TEdit;
    CheckBoxElevated: TCheckBox;
    ButtonStart: TButton;
    ButtonRunAsWindow: TButton;
    ButtonRelaunchAsAdmin: TButton;
    FlowPanelActions: TFlowPanel;
    ButtonClose: TButton;
    ButtonKill: TButton;
    ButtonRestart: TButton;
    ButtonUndock: TButton;
    ButtonSimulateHang: TButton;
    ButtonResume: TButton;
    ButtonCloseTab: TButton;
    EditSendText: TEdit;
    ButtonSendText: TButton;
    FlowPanelWatchdog: TFlowPanel;
    LabelHangAction: TLabel;
    ComboBoxHangAction: TComboBox;
    LabelHangTimeout: TLabel;
    EditHangTimeout: TEdit;
    CheckBoxRestartOnExit: TCheckBox;
    CheckBoxConfirm: TCheckBox;
    CheckBoxEmergencyKill: TCheckBox;
    PageControlSessions: TPageControl;
    SplitterLog: TSplitter;
    MemoLog: TMemo;
    StatusBar: TStatusBar;
    TimerStatus: TTimer;
    procedure FormCreate(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure ComboBoxPresetChange(Sender: TObject);
    procedure ButtonStartClick(Sender: TObject);
    procedure ButtonRunAsWindowClick(Sender: TObject);
    procedure ButtonRelaunchAsAdminClick(Sender: TObject);
    procedure ButtonCloseClick(Sender: TObject);
    procedure ButtonKillClick(Sender: TObject);
    procedure ButtonRestartClick(Sender: TObject);
    procedure ButtonUndockClick(Sender: TObject);
    procedure ButtonSimulateHangClick(Sender: TObject);
    procedure ButtonResumeClick(Sender: TObject);
    procedure ButtonCloseTabClick(Sender: TObject);
    procedure ButtonSendTextClick(Sender: TObject);
    procedure WatchdogOptionChange(Sender: TObject);
    procedure PageControlSessionsChange(Sender: TObject);
    procedure TimerStatusTimer(Sender: TObject);
  private
    FEntries: TArray<TDemoEntry>;
    FSessionCounter: Integer;
    FAppWindowSource: string;
    procedure BuildEntries;
    procedure AppWindowLog(Sender: TObject; const AText: string);
    function ActiveSheet: TDockSheet;
    function ActiveDocker: TProcessDocker;
    function SheetOf(ASender: TObject): TDockSheet;
    procedure ApplyWatchdogOptions(ADocker: TProcessDocker);
    procedure UpdateControls;
    procedure UpdateSheetCaption(ASheet: TDockSheet);
    procedure AddLog(const ASource, AText: string);
    // Docker events
    procedure DockerLog(Sender: TObject; const AText: string);
    procedure DockerStateChange(Sender: TObject);
    procedure DockerTitleChange(Sender: TObject; const AText: string);
    procedure DockerDockChanged(Sender: TObject);
    procedure DockerDockFailed(Sender: TObject; const AReason: string);
    procedure DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
    procedure DockerResponding(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
    procedure DockerEmergencyKill(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
    procedure DockerBeforeKill(Sender: TObject; const AInfo: TDockedProcessInfo; AReason: TDockKillReason;
      var AAllow: Boolean);
    procedure DockerBeforeRestart(Sender: TObject; const AInfo: TDockedProcessInfo; AReason: TDockRestartReason;
      var AAllow: Boolean);
    procedure DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD;
      AExpected: Boolean);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

uses
  System.StrUtils, ProcessToFormDocker.WinApi, ProcessToFormDocker.Form;

const
  HANG_ACTION_NOTIFY = 0;
  HANG_ACTION_KILL = 1;
  HANG_ACTION_RESTART = 2;
  HANG_ACTION_ASK = 3;
  EMERGENCY_KILL_MS = 10000;

  KillReasonNames: array[TDockKillReason] of string = ('manual', 'hung', 'close timeout');
  RestartReasonNames: array[TDockRestartReason] of string = ('manual', 'hung', 'unexpected exit');

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
var
  LEntry: TDemoEntry;
begin
  if TProcessDocker.IsHostElevated then
  begin
    Caption := Caption + '  [Administrator]';
    ButtonRelaunchAsAdmin.Enabled := False;
  end;

  BuildEntries;
  ComboBoxPreset.Items.Clear;
  for LEntry in FEntries do
    ComboBoxPreset.Items.Add(LEntry.Caption);
  ComboBoxPreset.ItemIndex := 0;
  ComboBoxPresetChange(nil);

  ComboBoxHangAction.ItemIndex := HANG_ACTION_NOTIFY;
  EditHangTimeout.Text := '0';
  LabelHangTimeout.Caption := Format('Hang timeout ms (0 = Windows default, %d):',
    [TProcessDocker.SystemHungAppTimeoutMs]);

  AddLog('Demo', 'Pick a preset and press "Start in new tab". Every tab hosts one TProcessDocker.');
  AddLog('Demo', '"Simulate hang" suspends the process: the watchdog reports it as not responding '
    + 'after the hang timeout. Choose the "On hang" action to kill / restart / ask.');
  UpdateControls;
end;

procedure TMainForm.BuildEntries;

  procedure AddPreset(APreset: TDockPreset; ADark: Boolean; const ACaption: string = '');
  var
    LEntry: TDemoEntry;
    LInfo: TDockPresetInfo;
  begin
    LInfo := TProcessDocker.PresetInfo(APreset);
    LEntry := Default(TDemoEntry);
    LEntry.Caption := LInfo.Caption;
    if ACaption <> '' then
      LEntry.Caption := ACaption;
    LEntry.IsPreset := True;
    LEntry.Preset := APreset;
    LEntry.FileName := LInfo.FileName;
    LEntry.Parameters := LInfo.Parameters;
    LEntry.DarkBackground := ADark;
    FEntries := FEntries + [LEntry];
  end;

  procedure AddCustom(const ACaption, AFileName, AParameters: string; AElevated: Boolean);
  var
    LEntry: TDemoEntry;
  begin
    LEntry := Default(TDemoEntry);
    LEntry.Caption := ACaption;
    LEntry.FileName := AFileName;
    LEntry.Parameters := AParameters;
    LEntry.Elevated := AElevated;
    FEntries := FEntries + [LEntry];
  end;

begin
  FEntries := nil;
  AddPreset(dpClassicCmd, True);
  AddPreset(dpClassicPowerShell, True);
  AddPreset(dpPowerShell7, True);
  AddPreset(dpWindowsTerminal, True);
  AddCustom('Character Map (classic Win32 app)', 'charmap.exe', '', False);
  AddPreset(dpNotepad, False, 'Notepad (Win 11 Store version crashes when docked!)');
  AddCustom('Registry Editor (requires elevation)', 'regedit.exe', '', True);
  AddCustom('Custom', '', '', False);
end;

procedure TMainForm.ComboBoxPresetChange(Sender: TObject);
var
  LEntry: TDemoEntry;
begin
  if ComboBoxPreset.ItemIndex < 0 then
    Exit;

  LEntry := FEntries[ComboBoxPreset.ItemIndex];
  EditFileName.Text := LEntry.FileName;
  EditParameters.Text := LEntry.Parameters;
  CheckBoxElevated.Checked := LEntry.Elevated;
end;

function TMainForm.ActiveSheet: TDockSheet;
begin
  if PageControlSessions.ActivePage is TDockSheet then
    Result := TDockSheet(PageControlSessions.ActivePage)
  else
    Result := nil;
end;

function TMainForm.ActiveDocker: TProcessDocker;
var
  LSheet: TDockSheet;
begin
  LSheet := ActiveSheet;
  if Assigned(LSheet) then
    Result := LSheet.Docker
  else
    Result := nil;
end;

function TMainForm.SheetOf(ASender: TObject): TDockSheet;
begin
  Result := nil;
  if (ASender is TProcessDocker) and (TProcessDocker(ASender).HostControl is TDockSheet) then
    Result := TDockSheet(TProcessDocker(ASender).HostControl);
end;

procedure TMainForm.ApplyWatchdogOptions(ADocker: TProcessDocker);
begin
  case ComboBoxHangAction.ItemIndex of
    HANG_ACTION_KILL:
      ADocker.HangAction := dhaKill;
    HANG_ACTION_RESTART:
      ADocker.HangAction := dhaRestart;
  else
    ADocker.HangAction := dhaNone; // Notify and Ask (Ask is handled in OnHung)
  end;

  ADocker.HangTimeoutMs := StrToIntDef(EditHangTimeout.Text, 0);
  ADocker.RestartOnUnexpectedExit := CheckBoxRestartOnExit.Checked;
  if CheckBoxEmergencyKill.Checked then
    ADocker.EmergencyKillTimeoutMs := EMERGENCY_KILL_MS
  else
    ADocker.EmergencyKillTimeoutMs := 0;
end;

procedure TMainForm.WatchdogOptionChange(Sender: TObject);
var
  LIndex: Integer;
begin
  // Watchdog settings are applied live to every session
  for LIndex := 0 to PageControlSessions.PageCount - 1 do
    if PageControlSessions.Pages[LIndex] is TDockSheet then
      ApplyWatchdogOptions(TDockSheet(PageControlSessions.Pages[LIndex]).Docker);
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
var
  LEntry: TDemoEntry;
  LSheet: TDockSheet;
  LDocker: TProcessDocker;
begin
  if ComboBoxPreset.ItemIndex < 0 then
    Exit;
  LEntry := FEntries[ComboBoxPreset.ItemIndex];

  Inc(FSessionCounter);
  LSheet := TDockSheet.Create(Self);
  LSheet.PageControl := PageControlSessions;
  LSheet.SessionNo := FSessionCounter;
  LSheet.BaseCaption := Format('#%d %s', [FSessionCounter, ExtractFileName(EditFileName.Text)]);
  LSheet.Caption := LSheet.BaseCaption;

  // Owned by the sheet: closing the tab destroys the docker, which closes / kills the process
  LDocker := TProcessDocker.Create(LSheet);
  LSheet.Docker := LDocker;
  LDocker.HostControl := LSheet;

  if LEntry.IsPreset then
    LDocker.ApplyPreset(LEntry.Preset);
  // The edits may have been changed by the user
  LDocker.FileName := EditFileName.Text;
  LDocker.Parameters := EditParameters.Text;
  LDocker.RunElevated := CheckBoxElevated.Checked;
  if LEntry.DarkBackground then
    LDocker.Color := RGB(12, 12, 12);

  ApplyWatchdogOptions(LDocker);

  LDocker.OnLog := DockerLog;
  LDocker.OnStateChange := DockerStateChange;
  LDocker.OnTitleChange := DockerTitleChange;
  LDocker.OnDocked := DockerDockChanged;
  LDocker.OnUndocked := DockerDockChanged;
  LDocker.OnDockFailed := DockerDockFailed;
  LDocker.OnHung := DockerHung;
  LDocker.OnResponding := DockerResponding;
  LDocker.OnEmergencyKill := DockerEmergencyKill;
  LDocker.OnBeforeKill := DockerBeforeKill;
  LDocker.OnBeforeRestart := DockerBeforeRestart;
  LDocker.OnProcessExit := DockerProcessExit;

  PageControlSessions.ActivePage := LSheet;
  try
    LDocker.Start;
  except
    on E: Exception do
      AddLog(LSheet.BaseCaption, 'Start failed: ' + E.Message);
  end;
  UpdateControls;
end;

procedure TMainForm.ButtonRunAsWindowClick(Sender: TObject);
var
  LEntry: TDemoEntry;
  LResult: TProcessFormResult;
  LSource: string;
begin
  if ComboBoxPreset.ItemIndex < 0 then
    Exit;
  LEntry := FEntries[ComboBoxPreset.ItemIndex];
  LSource := 'App window ' + ExtractFileName(EditFileName.Text);
  FAppWindowSource := LSource;

  // Blocks like ShowModal: the form appears when the window is docked, closes when the
  // process exits, and the exit code comes back.
  LResult := TProcessDockForm.ExecuteEx(EditFileName.Text, EditParameters.Text,
    procedure(AForm: TProcessDockForm)
    begin
      if LEntry.IsPreset then
      begin
        // Window search options of the preset (Windows Terminal needs them)
        AForm.Docker.ApplyPreset(LEntry.Preset);
        AForm.Docker.FileName := EditFileName.Text;
        AForm.Docker.Parameters := EditParameters.Text;
      end;
      AForm.Docker.RunElevated := CheckBoxElevated.Checked;
      if CheckBoxEmergencyKill.Checked then
        AForm.Docker.EmergencyKillTimeoutMs := EMERGENCY_KILL_MS;
      AForm.Docker.OnLog := AppWindowLog;
    end);

  if not LResult.Started then
  begin
    AddLog(LSource, 'Could not start: ' + LResult.ErrorMessage);
    MessageDlg('Could not start:' + sLineBreak + LResult.ErrorMessage, mtError, [mbOK], 0);
    Exit;
  end;

  AddLog(LSource, Format('Finished: exit code %u / $%x, docked: %s, closed by user: %s',
    [LResult.ExitCode, LResult.ExitCode, BoolToStr(LResult.WasDocked, True), BoolToStr(LResult.ClosedByUser, True)]));
  if LResult.ErrorMessage <> '' then
    AddLog(LSource, LResult.ErrorMessage);

  // This is where the calling code reacts to the exit code
  if LResult.ExitCode = 0 then
    MessageDlg('The application finished successfully (exit code 0).', mtInformation, [mbOK], 0)
  else
    MessageDlg(Format('The application finished with exit code %u ($%x).', [LResult.ExitCode, LResult.ExitCode]),
      mtWarning, [mbOK], 0);
end;

procedure TMainForm.AppWindowLog(Sender: TObject; const AText: string);
begin
  AddLog(FAppWindowSource, AText);
end;

procedure TMainForm.ButtonRelaunchAsAdminClick(Sender: TObject);
begin
  if RelaunchSelfElevated then
    Close;
end;

procedure TMainForm.ButtonCloseClick(Sender: TObject);
begin
  // Asynchronous: posts WM_CLOSE, kills after CloseTimeoutMs if the app does not close
  if (ActiveDocker <> nil) then
    ActiveDocker.RequestClose;
end;

procedure TMainForm.ButtonKillClick(Sender: TObject);
begin
  if (ActiveDocker <> nil) then
    ActiveDocker.Kill;
end;

procedure TMainForm.ButtonRestartClick(Sender: TObject);
begin
  if not (ActiveDocker <> nil) then
    Exit;
  try
    ActiveDocker.Restart;
  except
    on E: Exception do
      AddLog(ActiveSheet.BaseCaption, 'Restart failed: ' + E.Message);
  end;
end;

procedure TMainForm.ButtonUndockClick(Sender: TObject);
var
  LDocker: TProcessDocker;
begin
  LDocker := ActiveDocker;
  if not Assigned(LDocker) then
    Exit;

  if LDocker.IsDocked then
    LDocker.Undock
  else
    LDocker.Dock;
  UpdateControls;
end;

procedure TMainForm.ButtonSimulateHangClick(Sender: TObject);
begin
  if (ActiveDocker <> nil) then
  begin
    ActiveDocker.SuspendProcess;
    AddLog(ActiveSheet.BaseCaption, Format('Process suspended, expect a hang report in about %d ms',
      [ActiveDocker.EffectiveHangTimeoutMs]));
  end;
  UpdateControls;
end;

procedure TMainForm.ButtonResumeClick(Sender: TObject);
begin
  if (ActiveDocker <> nil) then
    ActiveDocker.ResumeProcess;
  UpdateControls;
end;

procedure TMainForm.ButtonCloseTabClick(Sender: TObject);
var
  LSheet: TDockSheet;
begin
  LSheet := ActiveSheet;
  if not Assigned(LSheet) then
    Exit;

  LSheet.Docker.Stop; // Graceful close, kill after CloseTimeoutMs
  LSheet.Free;
  UpdateControls;
end;

procedure TMainForm.ButtonSendTextClick(Sender: TObject);
begin
  if (ActiveDocker <> nil) then
  begin
    ActiveDocker.SendTextInput(EditSendText.Text, True);
    ActiveDocker.FocusDockedWindow;
  end;
end;

procedure TMainForm.PageControlSessionsChange(Sender: TObject);
begin
  UpdateControls;
  if (ActiveDocker <> nil) then
    ActiveDocker.FocusDockedWindow;
end;

procedure TMainForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  LIndex: Integer;
begin
  // Not strictly needed (ShutdownAction does the same when the dockers are destroyed),
  // but this way the events and log still work.
  for LIndex := PageControlSessions.PageCount - 1 downto 0 do
    if PageControlSessions.Pages[LIndex] is TDockSheet then
      TDockSheet(PageControlSessions.Pages[LIndex]).Docker.Stop;
end;

procedure TMainForm.UpdateControls;
var
  LDocker: TProcessDocker;
  LRunning: Boolean;
begin
  LDocker := ActiveDocker;
  LRunning := Assigned(LDocker) and LDocker.IsRunning;

  ButtonClose.Enabled := LRunning;
  ButtonKill.Enabled := LRunning;
  ButtonRestart.Enabled := Assigned(LDocker) and (LDocker.State <> pdsIdle);
  ButtonUndock.Enabled := LRunning and (LDocker.WindowHandle <> 0);
  if Assigned(LDocker) and LDocker.IsDocked then
    ButtonUndock.Caption := 'Undock'
  else
    ButtonUndock.Caption := 'Dock';
  ButtonSimulateHang.Enabled := LRunning and not LDocker.IsSuspended;
  ButtonResume.Enabled := LRunning and LDocker.IsSuspended;
  ButtonCloseTab.Enabled := Assigned(LDocker);
  ButtonSendText.Enabled := LRunning and (LDocker.WindowHandle <> 0);
  TimerStatusTimer(nil);
end;

procedure TMainForm.UpdateSheetCaption(ASheet: TDockSheet);
var
  LDocker: TProcessDocker;
  LCaption: string;
begin
  if not Assigned(ASheet) then
    Exit;

  LDocker := ASheet.Docker;
  LCaption := ASheet.BaseCaption;
  if LDocker.WindowTitle <> '' then
    LCaption := Format('#%d %s', [ASheet.SessionNo, LDocker.WindowTitle]);
  if Length(LCaption) > 40 then
    LCaption := Copy(LCaption, 1, 37) + '...';

  case LDocker.State of
    pdsStarting:
      LCaption := LCaption + ' (starting)';
    pdsClosing:
      LCaption := LCaption + ' (closing)';
    pdsExited:
      LCaption := LCaption + ' (exited)';
    pdsFailed:
      LCaption := LCaption + ' (failed)';
  else
    if not LDocker.IsResponding then
      LCaption := LCaption + ' (NOT RESPONDING)';
  end;

  ASheet.Caption := LCaption;
end;

procedure TMainForm.TimerStatusTimer(Sender: TObject);
var
  LDocker: TProcessDocker;
  LInfo: TDockedProcessInfo;
  LResponding: string;
begin
  LDocker := ActiveDocker;
  if not Assigned(LDocker) then
  begin
    StatusBar.Panels[0].Text := 'No session';
    StatusBar.Panels[1].Text := '';
    StatusBar.Panels[2].Text := '';
    StatusBar.Panels[3].Text := '';
  end
  else
  begin
    LInfo := LDocker.GetInfo;
    if LInfo.Suspended then
      LResponding := 'SUSPENDED'
    else if LInfo.Responding then
      LResponding := 'Responding'
    else
      LResponding := Format('NOT RESPONDING (%d ms)', [LInfo.UnresponsiveMs]);

    StatusBar.Panels[0].Text := Format('%s, %s, %s', [DockerStateNames[LInfo.State],
      IfThen(LInfo.Docked, 'docked', 'not docked'), LResponding]);
    StatusBar.Panels[1].Text := Format('PID %d (window: %d %s%s)', [LInfo.LaunchedProcessId,
      LInfo.WindowProcessId, LInfo.WindowProcessName, IfThen(LInfo.WindowIsForeign, ', foreign', '')]);
    StatusBar.Panels[2].Text := Format('Memory %.1f MB, restarts %d', [LInfo.WorkingSetBytes / (1024 * 1024),
      LInfo.RestartCount]);
    StatusBar.Panels[3].Text := Format('Class %s, hang timeout %d ms', [LInfo.WindowClassName,
      LDocker.EffectiveHangTimeoutMs]);
  end;
end;

procedure TMainForm.AddLog(const ASource, AText: string);
begin
  MemoLog.Lines.Add(Format('%s  %-18s %s', [FormatDateTime('hh:nn:ss.zzz', Now), ASource, AText]));
end;

{ Docker events }

procedure TMainForm.DockerLog(Sender: TObject; const AText: string);
var
  LSheet: TDockSheet;
begin
  LSheet := SheetOf(Sender);
  if Assigned(LSheet) then
    AddLog(LSheet.BaseCaption, AText);
end;

procedure TMainForm.DockerStateChange(Sender: TObject);
begin
  UpdateSheetCaption(SheetOf(Sender));
  UpdateControls;
end;

procedure TMainForm.DockerTitleChange(Sender: TObject; const AText: string);
begin
  UpdateSheetCaption(SheetOf(Sender));
end;

procedure TMainForm.DockerDockChanged(Sender: TObject);
begin
  UpdateSheetCaption(SheetOf(Sender));
  UpdateControls;
end;

procedure TMainForm.DockerDockFailed(Sender: TObject; const AReason: string);
begin
  UpdateControls;
end;

procedure TMainForm.DockerHung(Sender: TObject; const AInfo: TDockedProcessInfo; var AAction: TDockHangAction);
begin
  UpdateSheetCaption(SheetOf(Sender));
  UpdateControls;

  if ComboBoxHangAction.ItemIndex <> HANG_ACTION_ASK then
    Exit;

  // Note: a modal dialog while a docked window is hung can block, as the docked window
  // shares the input queue with us. EmergencyKillTimeoutMs is the safety net for that.
  case MessageDlg(Format('"%s" (pid %d) has not responded for %d ms.' + sLineBreak + sLineBreak +
    'Yes = kill it, Retry = restart it, Ignore = wait.', [AInfo.WindowTitle, AInfo.WindowProcessId,
    AInfo.UnresponsiveMs]), mtWarning, [mbYes, mbRetry, mbIgnore], 0) of
    mrYes:
      AAction := dhaKill;
    mrRetry:
      AAction := dhaRestart;
  else
    AAction := dhaNone;
  end;
end;

procedure TMainForm.DockerResponding(Sender: TObject; const AInfo: TDockedProcessInfo; AUnresponsiveMs: Cardinal);
begin
  UpdateSheetCaption(SheetOf(Sender));
  UpdateControls;
end;

procedure TMainForm.DockerEmergencyKill(Sender: TObject; const AInfo: TDockedProcessInfo;
  AUnresponsiveMs: Cardinal);
begin
  UpdateControls;
end;

procedure TMainForm.DockerBeforeKill(Sender: TObject; const AInfo: TDockedProcessInfo; AReason: TDockKillReason;
  var AAllow: Boolean);
begin
  if CheckBoxConfirm.Checked then
    AAllow := MessageDlg(Format('Kill "%s" (pid %d)? Reason: %s', [AInfo.WindowTitle, AInfo.LaunchedProcessId,
      KillReasonNames[AReason]]), mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

procedure TMainForm.DockerBeforeRestart(Sender: TObject; const AInfo: TDockedProcessInfo;
  AReason: TDockRestartReason; var AAllow: Boolean);
begin
  if not AAllow then
    AddLog(SheetOf(Sender).BaseCaption, 'Crash loop protection: restart not allowed by default');

  if CheckBoxConfirm.Checked then
    AAllow := MessageDlg(Format('Restart "%s"? Reason: %s, restarts so far: %d', [AInfo.FileName,
      RestartReasonNames[AReason], AInfo.RestartCount]), mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

procedure TMainForm.DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD;
  AExpected: Boolean);
begin
  UpdateSheetCaption(SheetOf(Sender));
  UpdateControls;
end;

end.
