unit ProcessToFormDocker.Form;

{
  TProcessDockForm: run an application "as if it was opened normally", but inside a
  form of your own.

  The process is started, its window is docked into a modal form and the form takes
  over the application's caption, icon, size, position and frame style, so the user
  sees what looks like the application's own window. The form is shown only after the
  window has been docked (no empty form flashing). When the process ends the form
  closes, and the exit code is returned to the caller:

    LExitCode := TProcessDockForm.Execute('C:\Tools\Importer.exe', '/batch');
    case LExitCode of
      0: ...
    end;

  Closing the form (X button, Alt+F4) sends WM_CLOSE to the application, which then
  decides itself (e.g. asks to save). The form closes when the process has exited.
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Classes, System.Types,
  Vcl.Controls, Vcl.Forms, Vcl.Graphics,
  ProcessToFormDocker;

type
  TProcessFormPlacement = (
    pfpWindow,          // Where the application placed its own window
    pfpMainFormCenter,  // Centered on the main form
    pfpScreenCenter,    // Centered on the screen
    pfpKeep             // Keep Left / Top as set by you (in the configure callback)
  );

  TProcessFormResult = record
    /// <summary>False: the process could not be started, see ErrorMessage. ExitCode is then meaningless.</summary>
    Started: Boolean;
    ExitCode: DWORD;
    /// <summary>
    ///   False: the window could not be docked (elevated process in a non elevated host,
    ///   no window at all...). The process ran in its own window, or without one.
    /// </summary>
    WasDocked: Boolean;
    /// <summary>The user closed the form, WM_CLOSE was sent to the application.</summary>
    ClosedByUser: Boolean;
    /// <summary>Why it could not be started or docked. Empty when all went well.</summary>
    ErrorMessage: string;
  end;

  TProcessDockForm = class;
  TProcessDockFormProc = reference to procedure(AForm: TProcessDockForm);

  TProcessDockForm = class(TForm)
  private
    FDocker: TProcessDocker;
    FPlacement: TProcessFormPlacement;
    FUseWindowSize: Boolean;
    FMirrorFrame: Boolean;
    FMirrorCaption: Boolean;
    FMirrorIcon: Boolean;
    FShowInTaskbar: Boolean;
    FRunning: Boolean;
    FDockedOnce: Boolean;
    FDockFailed: Boolean;
    FDockError: string;
    FFinished: Boolean;
    FClosedByUser: Boolean;
    FExitCode: DWORD;
    FSmallIcon: HICON;
    procedure DockerDocked(Sender: TObject);
    procedure DockerDockFailed(Sender: TObject; const AReason: string);
    procedure DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo; AExitCode: DWORD;
      AExpected: Boolean);
    procedure DockerTitleChange(Sender: TObject; const AText: string);
    procedure WMProcessFinished(var AMessage: TMessage); message WM_APP + $3A1;
    procedure SetShowInTaskbar(const AValue: Boolean);
    procedure Finish(AExitCode: DWORD);
    function IsWaitingForWindow: Boolean;
    function IsWaitingForExit: Boolean;
    procedure WaitWhile(const ACondition: TFunc<Boolean>);
    procedure ApplyWindowLook;
    procedure ApplyFrame;
    procedure ApplyCaption;
    procedure ApplyIcon;
    procedure ApplyBounds;
    procedure SendSmallIcon;
  protected
    procedure CreateParams(var AParams: TCreateParams); override;
    procedure CreateWnd; override;
    procedure Activate; override;
  public
    /// <summary>Creates the form without a DFM.</summary>
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function CloseQuery: Boolean; override;

    /// <summary>
    ///   Starts Docker.FileName / Parameters, shows the form modally when the window is
    ///   docked and returns when the process has exited. If the window can not be docked
    ///   the form stays hidden and Run still waits for the process (the application's
    ///   other windows are disabled meanwhile, as with any modal form).
    /// </summary>
    function Run: TProcessFormResult;

    /// <summary>
    ///   Runs the application in a modal form and returns its exit code. Raises
    ///   EProcessDocker if the process can not be started. AConfigure is called before
    ///   the start, use it to change Docker / form settings.
    /// </summary>
    class function Execute(const AFileName: string; const AParameters: string = '';
      const AConfigure: TProcessDockFormProc = nil): DWORD;
    /// <summary>Like Execute, but never raises and tells more about what happened.</summary>
    class function ExecuteEx(const AFileName: string; const AParameters: string = '';
      const AConfigure: TProcessDockFormProc = nil): TProcessFormResult;

    /// <summary>The docker. FileName, Parameters, RunElevated, WindowClassName, hang handling...</summary>
    property Docker: TProcessDocker read FDocker;
    property Placement: TProcessFormPlacement read FPlacement write FPlacement;
    /// <summary>Size the form so its client area is as big as the application's was. Default True.</summary>
    property UseWindowSize: Boolean read FUseWindowSize write FUseWindowSize;
    /// <summary>
    ///   Copy the frame of the application's window: not resizable, no minimize / maximize
    ///   button, no caption. Default True.
    /// </summary>
    property MirrorFrame: Boolean read FMirrorFrame write FMirrorFrame;
    /// <summary>Show (and follow) the application's window title as Caption. Default True.</summary>
    property MirrorCaption: Boolean read FMirrorCaption write FMirrorCaption;
    /// <summary>Use the application's window icon. Default True.</summary>
    property MirrorIcon: Boolean read FMirrorIcon write FMirrorIcon;
    /// <summary>Own taskbar button, like a normal application window. Default True.</summary>
    property ShowInTaskbar: Boolean read FShowInTaskbar write SetShowInTaskbar;
  end;

implementation

uses
  Winapi.ShellAPI,
  ProcessToFormDocker.WinApi;

const
  WM_PROCESS_FINISHED = WM_APP + $3A1;
  ICON_QUERY_TIMEOUT_MS = 1000;

function QueryWindowIcon(AWnd: HWND; AType: WPARAM): HICON;
var
  LResult: DWORD_PTR;
begin
  Result := 0;
  LResult := 0;
  if SendMessageTimeout(AWnd, WM_GETICON, AType, 0, SMTO_ABORTIFHUNG, ICON_QUERY_TIMEOUT_MS, @LResult) <> 0 then
    Result := HICON(LResult);
  if Result = 0 then
  begin
    if AType = ICON_BIG then
      Result := HICON(GetClassLongPtr(AWnd, GCL_HICON))
    else
      Result := HICON(GetClassLongPtr(AWnd, GCL_HICONSM));
  end;
end;

{ TProcessDockForm }

constructor TProcessDockForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);

  FPlacement := pfpWindow;
  FUseWindowSize := True;
  FMirrorFrame := True;
  FMirrorCaption := True;
  FMirrorIcon := True;
  FShowInTaskbar := True;

  Caption := '';
  Color := clBtnFace;
  Position := poDesigned;

  FDocker := TProcessDocker.Create(Self);
  FDocker.HostControl := Self;
  FDocker.ShowStatusText := False;
  // The form is hidden while docking, focus is given when it is shown (Activate)
  FDocker.FocusOnDock := False;
  // The application may ask "Save changes?" when it is closed: never kill it for that
  FDocker.KillAfterCloseTimeout := False;
  FDocker.OnDocked := DockerDocked;
  FDocker.OnDockFailed := DockerDockFailed;
  FDocker.OnProcessExit := DockerProcessExit;
  FDocker.OnTitleChange := DockerTitleChange;
end;

destructor TProcessDockForm.Destroy;
begin
  inherited Destroy;
  if FSmallIcon <> 0 then
    DestroyIcon(FSmallIcon);
end;

procedure TProcessDockForm.CreateParams(var AParams: TCreateParams);
begin
  inherited CreateParams(AParams);
  if FShowInTaskbar then
    AParams.ExStyle := AParams.ExStyle or WS_EX_APPWINDOW;
end;

procedure TProcessDockForm.CreateWnd;
begin
  inherited CreateWnd;
  SendSmallIcon;
end;

procedure TProcessDockForm.SetShowInTaskbar(const AValue: Boolean);
begin
  if FShowInTaskbar = AValue then
    Exit;
  FShowInTaskbar := AValue;
  if HandleAllocated then
    RecreateWnd;
end;

procedure TProcessDockForm.Activate;
begin
  inherited Activate;
  if Assigned(FDocker) and FDocker.IsDocked then
    FDocker.FocusDockedWindow;
end;

function TProcessDockForm.CloseQuery: Boolean;
begin
  Result := inherited CloseQuery;
  if not Result or FFinished or not FRunning then
    Exit;

  // Ask the application to close; the form follows when the process has exited
  Result := False;
  if FDocker.IsRunning then
  begin
    FClosedByUser := True;
    FDocker.RequestClose;
  end
  else
    Finish(FDocker.ExitCode);
end;

{ Docker events }

procedure TProcessDockForm.DockerDocked(Sender: TObject);
begin
  FDockedOnce := True;
end;

procedure TProcessDockForm.DockerDockFailed(Sender: TObject; const AReason: string);
begin
  FDockFailed := True;
  FDockError := AReason;
  // Exited before its window appeared, or there was nothing to dock and nothing runs
  if not FDocker.IsRunning then
    Finish(FDocker.ExitCode);
end;

procedure TProcessDockForm.DockerProcessExit(Sender: TObject; const AInfo: TDockedProcessInfo;
  AExitCode: DWORD; AExpected: Boolean);
begin
  Finish(AExitCode);
end;

procedure TProcessDockForm.DockerTitleChange(Sender: TObject; const AText: string);
begin
  if FMirrorCaption and (AText <> '') then
    Caption := AText;
end;

procedure TProcessDockForm.Finish(AExitCode: DWORD);
begin
  if FFinished then
    Exit;
  FFinished := True;
  FExitCode := AExitCode;
  // Posted, so it also works when this happens right before ShowModal resets ModalResult
  if HandleAllocated then
    PostMessage(Handle, WM_PROCESS_FINISHED, 0, 0);
end;

procedure TProcessDockForm.WMProcessFinished(var AMessage: TMessage);
begin
  if fsModal in FormState then
    ModalResult := mrOk;
end;

{ Running }

function TProcessDockForm.IsWaitingForWindow: Boolean;
begin
  Result := not (FDockedOnce or FDockFailed or FFinished);
end;

function TProcessDockForm.IsWaitingForExit: Boolean;
begin
  Result := not FFinished;
end;

procedure TProcessDockForm.WaitWhile(const ACondition: TFunc<Boolean>);
var
  LWindows: TTaskWindowList;
begin
  // Modal without a visible form: the rest of the application is disabled meanwhile
  LWindows := DisableTaskWindows(0);
  try
    while ACondition() and not Application.Terminated do
      Application.HandleMessage;
  finally
    EnableTaskWindows(LWindows);
  end;
end;

function TProcessDockForm.Run: TProcessFormResult;
var
  LSaveCursor: TCursor;
begin
  Result := Default(TProcessFormResult);
  if FRunning or FDocker.IsRunning then
    raise EProcessDocker.Create('TProcessDockForm: already running');

  FDockedOnce := False;
  FDockFailed := False;
  FDockError := '';
  FFinished := False;
  FClosedByUser := False;
  FExitCode := 0;

  FRunning := True;
  try
    try
      FDocker.Start;
    except
      on E: Exception do
      begin
        Result.ErrorMessage := E.Message;
        Exit;
      end;
    end;
    Result.Started := True;

    // Wait (hidden) until the window is docked, so the form appears complete
    LSaveCursor := Screen.Cursor;
    Screen.Cursor := crAppStart;
    try
      WaitWhile(IsWaitingForWindow);
    finally
      Screen.Cursor := LSaveCursor;
    end;

    if not FFinished and not Application.Terminated then
    begin
      if FDockedOnce and FDocker.IsDocked then
      begin
        ApplyWindowLook;
        ShowModal;
      end
      else
        // Runs in its own window (or without one): just wait for it
        WaitWhile(IsWaitingForExit);
    end;

    if not FFinished then
    begin
      // The application is terminating: do not leave the process behind
      FDocker.Stop;
      if not FFinished then
        FExitCode := FDocker.ExitCode;
    end;

    Result.ExitCode := FExitCode;
    Result.WasDocked := FDockedOnce;
    Result.ClosedByUser := FClosedByUser;
    if FDockFailed then
      Result.ErrorMessage := FDockError;
  finally
    FRunning := False;
  end;
end;

{ Looking like the application }

procedure TProcessDockForm.ApplyWindowLook;
begin
  if FMirrorFrame then
    ApplyFrame;
  if FMirrorCaption then
    ApplyCaption;
  if FMirrorIcon then
    ApplyIcon;
  ApplyBounds;
end;

procedure TProcessDockForm.ApplyFrame;
var
  LStyle: NativeInt;
  LIcons: TBorderIcons;
begin
  LStyle := FDocker.OriginalWindowStyle;

  if (LStyle and WS_CAPTION) <> WS_CAPTION then
    BorderStyle := bsNone
  else if (LStyle and WS_THICKFRAME) = 0 then
    BorderStyle := bsSingle
  else
    BorderStyle := bsSizeable;

  LIcons := [];
  if (LStyle and WS_SYSMENU) <> 0 then
    Include(LIcons, biSystemMenu);
  if (LStyle and WS_MINIMIZEBOX) <> 0 then
    Include(LIcons, biMinimize);
  if (LStyle and WS_MAXIMIZEBOX) <> 0 then
    Include(LIcons, biMaximize);
  BorderIcons := LIcons;
end;

procedure TProcessDockForm.ApplyCaption;
var
  LCaption: string;
begin
  LCaption := FDocker.WindowTitle;
  if LCaption = '' then
    LCaption := ChangeFileExt(GetProcessImageName(FDocker.WindowProcessId), '');
  Caption := LCaption;
end;

procedure TProcessDockForm.ApplyIcon;
var
  LWnd: HWND;
  LBig: HICON;
  LSmall: HICON;
  LPath: string;
begin
  LWnd := FDocker.WindowHandle;
  LBig := QueryWindowIcon(LWnd, ICON_BIG);
  LSmall := QueryWindowIcon(LWnd, ICON_SMALL2);

  if (LBig <> 0) or (LSmall <> 0) then
  begin
    // Icons of another process: take copies we own
    if LBig = 0 then
      LBig := LSmall;
    if LSmall = 0 then
      LSmall := LBig;
    LBig := CopyIcon(LBig);
    LSmall := CopyIcon(LSmall);
  end
  else
  begin
    LPath := GetProcessImagePath(FDocker.WindowProcessId);
    if (LPath = '') or (ExtractIconEx(PChar(LPath), 0, LBig, LSmall, 1) = 0) then
      Exit;
  end;

  if LBig <> 0 then
    Icon.Handle := LBig; // TIcon owns it now
  if LSmall <> 0 then
  begin
    if FSmallIcon <> 0 then
      DestroyIcon(FSmallIcon);
    FSmallIcon := LSmall;
    SendSmallIcon;
  end;
end;

procedure TProcessDockForm.SendSmallIcon;
begin
  if HandleAllocated and (FSmallIcon <> 0) then
    SendMessage(Handle, WM_SETICON, ICON_SMALL, LPARAM(FSmallIcon));
end;

procedure TProcessDockForm.ApplyBounds;
var
  LClient: TRect;
  LOrigin: TPoint;
  LBounds: TRect;
  LWorkArea: TRect;
  LStyle: NativeInt;
  LDpi: UINT;
begin
  LClient := FDocker.OriginalClientRect;

  // Without its frame, the docked window still has its scroll bars around its client
  // area (consoles do). Make room for them, so the application keeps its client size.
  LStyle := FDocker.OriginalWindowStyle;
  LDpi := GetDpiForWindow(FDocker.WindowHandle);
  if LDpi = 0 then
    LDpi := Screen.PixelsPerInch;
  if (LStyle and WS_VSCROLL) <> 0 then
    LClient.Right := LClient.Right + GetSystemMetricsForDpi(SM_CXVSCROLL, LDpi);
  if (LStyle and WS_HSCROLL) <> 0 then
    LClient.Bottom := LClient.Bottom + GetSystemMetricsForDpi(SM_CYHSCROLL, LDpi);

  if FUseWindowSize and (LClient.Width > 0) and (LClient.Height > 0) then
  begin
    ClientWidth := LClient.Width;
    ClientHeight := LClient.Height;
  end;

  case FPlacement of
    pfpWindow:
      begin
        Position := poDesigned;
        if (LClient.Width > 0) and (LClient.Height > 0) then
        begin
          // Put our client area exactly where the application's client area was
          LOrigin := ClientOrigin;
          LBounds := BoundsRect;
          LBounds.Offset(LClient.Left - LOrigin.X, LClient.Top - LOrigin.Y);

          // ... but on a monitor, fully visible when possible
          LWorkArea := Screen.MonitorFromRect(LBounds, mdNearest).WorkareaRect;
          if LBounds.Right > LWorkArea.Right then
            LBounds.Offset(LWorkArea.Right - LBounds.Right, 0);
          if LBounds.Bottom > LWorkArea.Bottom then
            LBounds.Offset(0, LWorkArea.Bottom - LBounds.Bottom);
          if LBounds.Left < LWorkArea.Left then
            LBounds.Offset(LWorkArea.Left - LBounds.Left, 0);
          if LBounds.Top < LWorkArea.Top then
            LBounds.Offset(0, LWorkArea.Top - LBounds.Top);

          SetBounds(LBounds.Left, LBounds.Top, LBounds.Width, LBounds.Height);
        end
        else
          Position := poMainFormCenter;
      end;
    pfpMainFormCenter:
      Position := poMainFormCenter;
    pfpScreenCenter:
      Position := poScreenCenter;
    pfpKeep:
      Position := poDesigned;
  end;
end;

{ Shortcuts }

class function TProcessDockForm.ExecuteEx(const AFileName, AParameters: string;
  const AConfigure: TProcessDockFormProc): TProcessFormResult;
var
  LForm: TProcessDockForm;
begin
  LForm := Create(nil);
  try
    LForm.Docker.FileName := AFileName;
    LForm.Docker.Parameters := AParameters;
    if Assigned(AConfigure) then
      AConfigure(LForm);
    Result := LForm.Run;
  finally
    LForm.Free;
  end;
end;

class function TProcessDockForm.Execute(const AFileName, AParameters: string;
  const AConfigure: TProcessDockFormProc): DWORD;
var
  LResult: TProcessFormResult;
begin
  LResult := ExecuteEx(AFileName, AParameters, AConfigure);
  if not LResult.Started then
    raise EProcessDocker.Create(LResult.ErrorMessage);
  Result := LResult.ExitCode;
end;

end.
