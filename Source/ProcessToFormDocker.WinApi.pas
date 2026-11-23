unit ProcessToFormDocker.WinApi;

{
  Low level Windows API helpers used by TProcessDocker.

  Everything here is plain Win32 and usable on its own, for example
  KillProcessTree(), GetSystemHungAppTimeout() or RelaunchSelfElevated().

  Functions in this unit are safe to call from any thread unless noted.
}

interface

uses
  Winapi.Windows, System.SysUtils;

type
  TProcessIdArray = TArray<DWORD>;

  TProcessSnapshotEntry = record
    ProcessId: DWORD;
    ParentProcessId: DWORD;
    ExeName: string;
  end;

  /// <summary>
  ///   Everything needed to terminate a docked session. Used both from the main
  ///   thread and from the watchdog thread (which owns its own duplicated handles).
  /// </summary>
  TKillTargets = record
    Job: THandle;
    LaunchedProcess: THandle;
    LaunchedProcessId: DWORD;
    WindowProcess: THandle;
    KillWindowProcess: Boolean;
    procedure Clear;
    /// <summary>Returns a copy with all handles duplicated. Free with CloseHandles.</summary>
    function Duplicate: TKillTargets;
    procedure CloseHandles;
  end;

const
  DEFAULT_HUNG_APP_TIMEOUT_MS = 5000;

{ Hang detection }

/// <summary>
///   Reads HKCU\Control Panel\Desktop\HungAppTimeout, the time Windows waits before
///   it considers a window "Not responding" (ghosting). Defaults to 5000 ms.
/// </summary>
function GetSystemHungAppTimeout: Cardinal;
/// <summary>IsHungAppWindow() - Windows' own opinion, uses the system hung timeout.</summary>
function IsWindowHung(AWnd: HWND): Boolean;
/// <summary>
///   Sends WM_NULL with a timeout. Returns False only when the window did not
///   process the message in time. Errors that are not timeouts (UIPI, invalid
///   window) return True, as those do not mean the window is hung.
/// </summary>
function PingWindow(AWnd: HWND; ATimeoutMs: Cardinal): Boolean;

{ Elevation }

function IsCurrentProcessElevated: Boolean;
/// <summary>
///   Returns True when the elevation state could be determined. Querying an
///   elevated process from a non elevated one usually fails (access denied).
/// </summary>
function TryGetProcessElevation(AProcessId: DWORD; out AElevated: Boolean): Boolean;
/// <summary>
///   Best guess: True when the process is elevated, or when this (non elevated)
///   process is denied access to its token, which almost always means elevated.
/// </summary>
function IsProcessProbablyElevated(AProcessId: DWORD): Boolean;
/// <summary>Starts this executable again with the "runas" verb (UAC prompt).</summary>
function RelaunchSelfElevated(const AParameters: string = ''): Boolean;

{ Processes }

function GetProcessImagePath(AProcessId: DWORD): string;
function GetProcessImageName(AProcessId: DWORD): string;
function GetProcessIdOfHandle(AProcess: THandle): DWORD;
function IsProcessHandleAlive(AProcess: THandle): Boolean;
function GetProcessSnapshot: TArray<TProcessSnapshotEntry>;
/// <summary>
///   Returns the live descendants of ARootIds (and the roots themselves when alive).
///   Roots are used as seeds even when they have already exited, so children of an
///   exited launcher are still found. Hold a handle to a root process to make sure
///   its PID is not reused while you use the result.
/// </summary>
function GetDescendantProcessIds(const ARootIds: array of DWORD): TProcessIdArray;
function ContainsProcessId(const AIds: TProcessIdArray; AId: DWORD): Boolean;

function TerminateProcessById(AProcessId: DWORD; AExitCode: UINT = 1): Boolean;
/// <summary>Terminates AProcessId and all its descendants. Never terminates the calling process.</summary>
function KillProcessTree(AProcessId: DWORD; AExitCode: UINT = 1): Boolean;
function KillTargets(const ATargets: TKillTargets; AExitCode: UINT = 1): Boolean;

/// <summary>Suspends all threads of the process (NtSuspendProcess). Handy for simulating a hang.</summary>
function SuspendProcessById(AProcessId: DWORD): Boolean;
function ResumeProcessById(AProcessId: DWORD): Boolean;

function GetProcessWorkingSetSize(AProcessId: DWORD): UInt64;

{ Job objects }

/// <summary>
///   Creates a job object with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: when the last handle
///   to the job is closed (also when the host crashes) every process in it is killed.
/// </summary>
function CreateKillOnCloseJob: THandle;
/// <summary>Removes the kill on close limit so the processes survive closing the job.</summary>
procedure ReleaseKillOnCloseJob(AJob: THandle);
function AssignProcessToJob(AJob, AProcess: THandle): Boolean;
function TerminateJob(AJob: THandle; AExitCode: UINT = 1): Boolean;

{ Misc }

/// <summary>System32 of the native OS bitness (Sysnative from a 32-bit process on 64-bit Windows).</summary>
function GetNativeSystemDirectory: string;
function GetWindowClassNameStr(AWnd: HWND): string;
/// <summary>Does not send WM_GETTEXT to windows of other processes, so it never hangs.</summary>
function GetWindowTextStr(AWnd: HWND): string;
function GetWindowProcessId(AWnd: HWND): DWORD;
function GetTopLevelWindows: TArray<HWND>;

implementation

uses
  Winapi.Messages, Winapi.TlHelp32, Winapi.PsAPI, Winapi.ShellAPI, System.Win.Registry, System.Generics.Collections;

const
  PROCESS_QUERY_LIMITED_INFORMATION_ = $1000;
  PROCESS_SUSPEND_RESUME_ = $0800;
  TOKEN_ELEVATION_CLASS = 20;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_ = $00002000;
  JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = 9;

type
  TJobBasicLimitInformation = record
    PerProcessUserTimeLimit: Int64;
    PerJobUserTimeLimit: Int64;
    LimitFlags: DWORD;
    MinimumWorkingSetSize: SIZE_T;
    MaximumWorkingSetSize: SIZE_T;
    ActiveProcessLimit: DWORD;
    Affinity: ULONG_PTR;
    PriorityClass: DWORD;
    SchedulingClass: DWORD;
  end;

  TJobIoCounters = record
    ReadOperationCount: UInt64;
    WriteOperationCount: UInt64;
    OtherOperationCount: UInt64;
    ReadTransferCount: UInt64;
    WriteTransferCount: UInt64;
    OtherTransferCount: UInt64;
  end;

  TJobExtendedLimitInformation = record
    BasicLimitInformation: TJobBasicLimitInformation;
    IoInfo: TJobIoCounters;
    ProcessMemoryLimit: SIZE_T;
    JobMemoryLimit: SIZE_T;
    PeakProcessMemoryUsed: SIZE_T;
    PeakJobMemoryUsed: SIZE_T;
  end;

  TNtProcessFunc = function(AProcess: THandle): LongInt; stdcall;

function IsHungAppWindow_(AWnd: HWND): BOOL; stdcall; external user32 name 'IsHungAppWindow';
function QueryFullProcessImageNameW_(AProcess: THandle; AFlags: DWORD; AExeName: PWideChar;
  var ASize: DWORD): BOOL; stdcall; external kernel32 name 'QueryFullProcessImageNameW';
function GetProcessId_(AProcess: THandle): DWORD; stdcall; external kernel32 name 'GetProcessId';
function GetTokenInformation_(AToken: THandle; AInfoClass: DWORD; AInfo: Pointer; AInfoLength: DWORD;
  var AReturnLength: DWORD): BOOL; stdcall; external advapi32 name 'GetTokenInformation';
function CreateJobObjectW_(AAttributes: Pointer; AName: PWideChar): THandle; stdcall;
  external kernel32 name 'CreateJobObjectW';
function AssignProcessToJobObject_(AJob, AProcess: THandle): BOOL; stdcall;
  external kernel32 name 'AssignProcessToJobObject';
function TerminateJobObject_(AJob: THandle; AExitCode: UINT): BOOL; stdcall;
  external kernel32 name 'TerminateJobObject';
function SetInformationJobObject_(AJob: THandle; AInfoClass: Integer; AInfo: Pointer;
  AInfoLength: DWORD): BOOL; stdcall; external kernel32 name 'SetInformationJobObject';
function IsWow64Process_(AProcess: THandle; var AWow64: BOOL): BOOL; stdcall;
  external kernel32 name 'IsWow64Process';

{ TKillTargets }

procedure TKillTargets.Clear;
begin
  Self := Default(TKillTargets);
end;

function DuplicateHandleSafe(AHandle: THandle): THandle;
begin
  Result := 0;
  if AHandle = 0 then
    Exit;

  if not DuplicateHandle(GetCurrentProcess, AHandle, GetCurrentProcess, @Result, 0, False,
    DUPLICATE_SAME_ACCESS) then
    Result := 0;
end;

function TKillTargets.Duplicate: TKillTargets;
begin
  Result := Self;
  Result.Job := DuplicateHandleSafe(Job);
  Result.LaunchedProcess := DuplicateHandleSafe(LaunchedProcess);
  Result.WindowProcess := DuplicateHandleSafe(WindowProcess);
end;

procedure TKillTargets.CloseHandles;
begin
  if Job <> 0 then
    CloseHandle(Job);
  if LaunchedProcess <> 0 then
    CloseHandle(LaunchedProcess);
  if WindowProcess <> 0 then
    CloseHandle(WindowProcess);

  Job := 0;
  LaunchedProcess := 0;
  WindowProcess := 0;
end;

{ Hang detection }

function GetSystemHungAppTimeout: Cardinal;
var
  LRegistry: TRegistry;
begin
  Result := DEFAULT_HUNG_APP_TIMEOUT_MS;

  LRegistry := TRegistry.Create(KEY_READ);
  try
    LRegistry.RootKey := HKEY_CURRENT_USER;
    if LRegistry.OpenKeyReadOnly('Control Panel\Desktop') and LRegistry.ValueExists('HungAppTimeout') then
    try
      case LRegistry.GetDataType('HungAppTimeout') of
        rdInteger:
          Result := Cardinal(LRegistry.ReadInteger('HungAppTimeout'));
      else
        Result := StrToIntDef(LRegistry.ReadString('HungAppTimeout'), DEFAULT_HUNG_APP_TIMEOUT_MS);
      end;
    except
      Result := DEFAULT_HUNG_APP_TIMEOUT_MS;
    end;
  finally
    LRegistry.Free;
  end;

  if Result = 0 then
    Result := DEFAULT_HUNG_APP_TIMEOUT_MS;
end;

function IsWindowHung(AWnd: HWND): Boolean;
begin
  Result := (AWnd <> 0) and IsHungAppWindow_(AWnd);
end;

function PingWindow(AWnd: HWND; ATimeoutMs: Cardinal): Boolean;
var
  LResult: DWORD_PTR;
  LError: DWORD;
begin
  SetLastError(0);
  if SendMessageTimeout(AWnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG or SMTO_BLOCK, ATimeoutMs, @LResult) <> 0 then
    Exit(True);

  LError := GetLastError;
  // Timeout (or "aborted because hung", which reports no error) means not responding.
  // Anything else (UIPI access denied, invalid window...) is not a hang.
  Result := not ((LError = ERROR_TIMEOUT) or (LError = 0));
end;

{ Elevation }

function TokenIsElevated(AToken: THandle; out AElevated: Boolean): Boolean;
var
  LElevation: DWORD;
  LLength: DWORD;
begin
  LElevation := 0;
  LLength := 0;
  Result := GetTokenInformation_(AToken, TOKEN_ELEVATION_CLASS, @LElevation, SizeOf(LElevation), LLength);
  AElevated := Result and (LElevation <> 0);
end;

function IsCurrentProcessElevated: Boolean;
var
  LToken: THandle;
begin
  Result := False;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, LToken) then
  try
    TokenIsElevated(LToken, Result);
  finally
    CloseHandle(LToken);
  end;
end;

function TryGetProcessElevationEx(AProcessId: DWORD; out AElevated: Boolean;
  out ATokenAccessDenied: Boolean): Boolean;
var
  LProcess: THandle;
  LToken: THandle;
begin
  Result := False;
  AElevated := False;
  ATokenAccessDenied := False;

  LProcess := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_, False, AProcessId);
  if LProcess = 0 then
    Exit;
  try
    if OpenProcessToken(LProcess, TOKEN_QUERY, LToken) then
    try
      Result := TokenIsElevated(LToken, AElevated);
    finally
      CloseHandle(LToken);
    end
    else
      ATokenAccessDenied := GetLastError = ERROR_ACCESS_DENIED;
  finally
    CloseHandle(LProcess);
  end;
end;

function TryGetProcessElevation(AProcessId: DWORD; out AElevated: Boolean): Boolean;
var
  LDenied: Boolean;
begin
  Result := TryGetProcessElevationEx(AProcessId, AElevated, LDenied);
end;

function IsProcessProbablyElevated(AProcessId: DWORD): Boolean;
var
  LElevated: Boolean;
  LDenied: Boolean;
begin
  if TryGetProcessElevationEx(AProcessId, LElevated, LDenied) then
    Result := LElevated
  else
    Result := LDenied and not IsCurrentProcessElevated;
end;

function RelaunchSelfElevated(const AParameters: string): Boolean;
var
  LInfo: TShellExecuteInfo;
  LFileName: string;
begin
  LFileName := ParamStr(0);
  LInfo := Default(TShellExecuteInfo);
  LInfo.cbSize := SizeOf(LInfo);
  LInfo.fMask := SEE_MASK_NOASYNC;
  LInfo.lpVerb := 'runas';
  LInfo.lpFile := PChar(LFileName);
  if AParameters <> '' then
    LInfo.lpParameters := PChar(AParameters);
  LInfo.nShow := SW_SHOWNORMAL;
  Result := ShellExecuteEx(@LInfo);
end;

{ Processes }

function GetProcessImagePath(AProcessId: DWORD): string;
var
  LProcess: THandle;
  LBuffer: array[0..MAX_PATH * 2] of WideChar;
  LSize: DWORD;
begin
  Result := '';
  if AProcessId = 0 then
    Exit;

  LProcess := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_, False, AProcessId);
  if LProcess = 0 then
    Exit;
  try
    LSize := Length(LBuffer);
    if QueryFullProcessImageNameW_(LProcess, 0, @LBuffer[0], LSize) then
      SetString(Result, PWideChar(@LBuffer[0]), LSize);
  finally
    CloseHandle(LProcess);
  end;
end;

function GetProcessImageName(AProcessId: DWORD): string;
var
  LEntries: TArray<TProcessSnapshotEntry>;
  LEntry: TProcessSnapshotEntry;
begin
  Result := ExtractFileName(GetProcessImagePath(AProcessId));
  if (Result <> '') or (AProcessId = 0) then
    Exit;

  // Fallback for processes we can not open
  LEntries := GetProcessSnapshot;
  for LEntry in LEntries do
    if LEntry.ProcessId = AProcessId then
      Exit(LEntry.ExeName);
end;

function GetProcessIdOfHandle(AProcess: THandle): DWORD;
begin
  if AProcess = 0 then
    Result := 0
  else
    Result := GetProcessId_(AProcess);
end;

function IsProcessHandleAlive(AProcess: THandle): Boolean;
begin
  Result := (AProcess <> 0) and (WaitForSingleObject(AProcess, 0) = WAIT_TIMEOUT);
end;

function GetProcessSnapshot: TArray<TProcessSnapshotEntry>;
var
  LSnapshot: THandle;
  LEntry: TProcessEntry32;
  LList: TList<TProcessSnapshotEntry>;
  LItem: TProcessSnapshotEntry;
begin
  Result := nil;
  LSnapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if LSnapshot = INVALID_HANDLE_VALUE then
    Exit;
  LList := TList<TProcessSnapshotEntry>.Create;
  try
    LEntry := Default(TProcessEntry32);
    LEntry.dwSize := SizeOf(LEntry);
    if Process32First(LSnapshot, LEntry) then
    repeat
      LItem.ProcessId := LEntry.th32ProcessID;
      LItem.ParentProcessId := LEntry.th32ParentProcessID;
      LItem.ExeName := LEntry.szExeFile;
      LList.Add(LItem);
    until not Process32Next(LSnapshot, LEntry);

    Result := LList.ToArray;
  finally
    LList.Free;
    CloseHandle(LSnapshot);
  end;
end;

function ContainsProcessId(const AIds: TProcessIdArray; AId: DWORD): Boolean;
var
  LId: DWORD;
begin
  for LId in AIds do
    if LId = AId then
      Exit(True);
  Result := False;
end;

function GetDescendantProcessIds(const ARootIds: array of DWORD): TProcessIdArray;
var
  LSnapshot: TArray<TProcessSnapshotEntry>;
  LSeeds: TList<DWORD>;
  LResult: TList<DWORD>;
  LEntry: TProcessSnapshotEntry;
  LRootId: DWORD;
  LAdded: Boolean;
begin
  LSnapshot := GetProcessSnapshot;
  LSeeds := TList<DWORD>.Create;
  LResult := TList<DWORD>.Create;
  try
    for LRootId in ARootIds do
      if (LRootId <> 0) and not LSeeds.Contains(LRootId) then
        LSeeds.Add(LRootId);

    // Roots that are still alive
    for LEntry in LSnapshot do
      if LSeeds.Contains(LEntry.ProcessId) then
        LResult.Add(LEntry.ProcessId);

    repeat
      LAdded := False;
      for LEntry in LSnapshot do
        if (LEntry.ProcessId <> 0) and (LEntry.ProcessId <> LEntry.ParentProcessId)
          and not LSeeds.Contains(LEntry.ProcessId) and LSeeds.Contains(LEntry.ParentProcessId) then
        begin
          LSeeds.Add(LEntry.ProcessId);
          LResult.Add(LEntry.ProcessId);
          LAdded := True;
        end;
    until not LAdded;

    Result := LResult.ToArray;
  finally
    LResult.Free;
    LSeeds.Free;
  end;
end;

function TerminateProcessById(AProcessId: DWORD; AExitCode: UINT): Boolean;
var
  LProcess: THandle;
begin
  Result := False;
  if (AProcessId = 0) or (AProcessId = GetCurrentProcessId) then
    Exit;

  LProcess := OpenProcess(PROCESS_TERMINATE, False, AProcessId);
  if LProcess = 0 then
    Exit;
  try
    Result := TerminateProcess(LProcess, AExitCode);
  finally
    CloseHandle(LProcess);
  end;
end;

function KillProcessTree(AProcessId: DWORD; AExitCode: UINT): Boolean;
var
  LIds: TProcessIdArray;
  LIndex: Integer;
begin
  Result := False;
  LIds := GetDescendantProcessIds([AProcessId]);
  // Kill the root first so it can not spawn new children, then the rest
  for LIndex := 0 to High(LIds) do
    if TerminateProcessById(LIds[LIndex], AExitCode) then
      Result := True;
end;

function KillTargets(const ATargets: TKillTargets; AExitCode: UINT): Boolean;
begin
  Result := False;

  if (ATargets.Job <> 0) and TerminateJobObject_(ATargets.Job, AExitCode) then
    Result := True;

  if (ATargets.LaunchedProcess <> 0) and IsProcessHandleAlive(ATargets.LaunchedProcess) then
    if TerminateProcess(ATargets.LaunchedProcess, AExitCode) then
      Result := True;

  // Only safe when the caller holds a handle to the launched process (PID can not be reused)
  if (ATargets.LaunchedProcessId <> 0) and (ATargets.LaunchedProcess <> 0) then
    if KillProcessTree(ATargets.LaunchedProcessId, AExitCode) then
      Result := True;

  if ATargets.KillWindowProcess and (ATargets.WindowProcess <> 0)
    and IsProcessHandleAlive(ATargets.WindowProcess) then
    if TerminateProcess(ATargets.WindowProcess, AExitCode) then
      Result := True;
end;

function CallNtProcessFunc(const AName: string; AProcessId: DWORD): Boolean;
var
  LFunc: TNtProcessFunc;
  LProcess: THandle;
begin
  Result := False;
  @LFunc := GetProcAddress(GetModuleHandle('ntdll.dll'), PChar(AName));
  if not Assigned(LFunc) then
    Exit;

  LProcess := OpenProcess(PROCESS_SUSPEND_RESUME_, False, AProcessId);
  if LProcess = 0 then
    Exit;
  try
    Result := LFunc(LProcess) >= 0;
  finally
    CloseHandle(LProcess);
  end;
end;

function SuspendProcessById(AProcessId: DWORD): Boolean;
begin
  Result := (AProcessId <> GetCurrentProcessId) and CallNtProcessFunc('NtSuspendProcess', AProcessId);
end;

function ResumeProcessById(AProcessId: DWORD): Boolean;
begin
  Result := CallNtProcessFunc('NtResumeProcess', AProcessId);
end;

function GetProcessWorkingSetSize(AProcessId: DWORD): UInt64;
var
  LProcess: THandle;
  LCounters: TProcessMemoryCounters;
begin
  Result := 0;
  LProcess := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION_, False, AProcessId);
  if LProcess = 0 then
    Exit;
  try
    LCounters := Default(TProcessMemoryCounters);
    LCounters.cb := SizeOf(LCounters);
    if GetProcessMemoryInfo(LProcess, @LCounters, SizeOf(LCounters)) then
      Result := LCounters.WorkingSetSize;
  finally
    CloseHandle(LProcess);
  end;
end;

{ Job objects }

function SetJobLimitFlags(AJob: THandle; AFlags: DWORD): Boolean;
var
  LInfo: TJobExtendedLimitInformation;
begin
  LInfo := Default(TJobExtendedLimitInformation);
  LInfo.BasicLimitInformation.LimitFlags := AFlags;
  Result := SetInformationJobObject_(AJob, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, @LInfo, SizeOf(LInfo));
end;

function CreateKillOnCloseJob: THandle;
begin
  Result := CreateJobObjectW_(nil, nil);
  if Result = 0 then
    Exit;

  if not SetJobLimitFlags(Result, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE_) then
  begin
    CloseHandle(Result);
    Result := 0;
  end;
end;

procedure ReleaseKillOnCloseJob(AJob: THandle);
begin
  if AJob <> 0 then
    SetJobLimitFlags(AJob, 0);
end;

function AssignProcessToJob(AJob, AProcess: THandle): Boolean;
begin
  Result := (AJob <> 0) and (AProcess <> 0) and AssignProcessToJobObject_(AJob, AProcess);
end;

function TerminateJob(AJob: THandle; AExitCode: UINT): Boolean;
begin
  Result := (AJob <> 0) and TerminateJobObject_(AJob, AExitCode);
end;

{ Misc }

function GetNativeSystemDirectory: string;
var
  LBuffer: array[0..MAX_PATH] of Char;
  LWow64: BOOL;
begin
  LWow64 := False;
  if IsWow64Process_(GetCurrentProcess, LWow64) and LWow64 then
  begin
    SetString(Result, LBuffer, GetWindowsDirectory(LBuffer, Length(LBuffer)));
    Result := IncludeTrailingPathDelimiter(Result) + 'Sysnative';
  end
  else
    SetString(Result, LBuffer, GetSystemDirectory(LBuffer, Length(LBuffer)));
end;

function GetWindowClassNameStr(AWnd: HWND): string;
var
  LBuffer: array[0..255] of Char;
begin
  SetString(Result, LBuffer, GetClassName(AWnd, LBuffer, Length(LBuffer)));
end;

function GetWindowTextStr(AWnd: HWND): string;
var
  LBuffer: array[0..511] of Char;
begin
  SetString(Result, LBuffer, GetWindowText(AWnd, LBuffer, Length(LBuffer)));
end;

function GetWindowProcessId(AWnd: HWND): DWORD;
begin
  Result := 0;
  GetWindowThreadProcessId(AWnd, @Result);
end;

function EnumWindowsCallback(AWnd: HWND; AParam: LPARAM): BOOL; stdcall;
begin
  TList<HWND>(Pointer(AParam)).Add(AWnd);
  Result := True;
end;

function GetTopLevelWindows: TArray<HWND>;
var
  LList: TList<HWND>;
begin
  LList := TList<HWND>.Create;
  try
    EnumWindows(@EnumWindowsCallback, LPARAM(Pointer(LList)));
    Result := LList.ToArray;
  finally
    LList.Free;
  end;
end;

end.
