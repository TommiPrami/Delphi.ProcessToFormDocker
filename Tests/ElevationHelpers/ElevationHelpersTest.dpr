program ElevationHelpersTest;

{
  Tests the elevation helpers of ProcessToFormDocker.WinApi:
  StartElevated, StartNonElevated, RestartSelfElevated, RestartSelfNonElevated,
  GetElevationType, GetCommandLineParameters, WaitForProcess.

    ElevationHelpersTest.exe          full test: ONE UAC prompt, then elevated -> normal user
    ElevationHelpersTest.exe /local   only what needs no UAC prompt
}

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.SysUtils, System.StrUtils, System.IOUtils,
  ProcessToFormDocker.WinApi in '..\..\Source\ProcessToFormDocker.WinApi.pas';

const
  ElevationTypeNames: array[TProcessElevationType] of string = (
    'unknown', 'default (no split token)', 'FULL (elevated)', 'limited (admin, not elevated)');

var
  LogFile: string;
  Failures: Integer;

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
        $4000: Result := 'SYSTEM';
      end;
    end;
  finally
    CloseHandle(LToken);
  end;
end;

function WhoAmI: string;
begin
  Result := Format('pid %d, integrity %s, elevated %s, elevation type %s', [GetCurrentProcessId, IntegrityName,
    BoolToStr(IsCurrentProcessElevated, True), ElevationTypeNames[GetElevationType]]);
end;

procedure Log(const AText: string);
var
  LLine: string;
  LTry: Integer;
begin
  LLine := Format('[%s] %s', [FormatDateTime('nn:ss.zzz', Now), AText]);
  Writeln(LLine);
  if LogFile = '' then
    Exit;
  // Several processes append to the same file
  for LTry := 1 to 20 do
    try
      TFile.AppendAllText(LogFile, LLine + sLineBreak);
      Break;
    except
      Sleep(50);
    end;
end;

procedure Check(const AWhat: string; AOk: Boolean; const ADetails: string = '');
begin
  if AOk then
    Log('PASS ' + AWhat + IfThen(ADetails <> '', ' (' + ADetails + ')', ''))
  else
  begin
    Inc(Failures);
    Log('FAIL ' + AWhat + IfThen(ADetails <> '', ' (' + ADetails + ')', ''));
  end;
end;

function LogContains(const AText: string): Boolean;
begin
  Result := FileExists(LogFile) and (Pos(AText, TFile.ReadAllText(LogFile)) > 0);
end;

/// <summary>True when the log line starting with AMarker contains AText.</summary>
function LogLineContains(const AMarker, AText: string): Boolean;
var
  LLine: string;
begin
  Result := False;
  if FileExists(LogFile) then
    for LLine in TFile.ReadAllLines(LogFile) do
      if (Pos(AMarker, LLine) > 0) and (Pos(AText, LLine) > 0) then
        Exit(True);
end;

function WaitForLog(const AText: string; ATimeoutMs: Cardinal): Boolean;
var
  LEnd: UInt64;
begin
  LEnd := GetTickCount64 + ATimeoutMs;
  repeat
    try
      if LogContains(AText) then
        Exit(True);
    except
      // being written
    end;
    Sleep(200);
  until GetTickCount64 > LEnd;
  Result := False;
end;

function Quoted(const AText: string): string;
begin
  Result := '"' + AText + '"';
end;

{ Child: reports who it is and exits with 7 }

procedure RunChild;
begin
  LogFile := ParamStr(2);
  Log(Format('child "%s": %s', [ParamStr(3), WhoAmI]));
  Log(Format('child "%s": parameters [%s]', [ParamStr(3), GetCommandLineParameters]));
  ExitCode := 7;
end;

{ Tests that need no UAC prompt }

procedure RunLocalTests;
var
  LProcess: THandle;
  LCode: DWORD;
begin
  Log('== local tests, this process: ' + WhoAmI);

  LProcess := StartNonElevated(ParamStr(0), Format('/child %s "medium child" "a b" c', [Quoted(LogFile)]));
  Check('StartNonElevated returns a process handle', LProcess <> 0, SysErrorMessage(GetLastError));
  if LProcess <> 0 then
  begin
    Check('WaitForProcess gives the exit code 7', WaitForProcess(LProcess, LCode, 10000) and (LCode = 7),
      'exit code ' + IntToStr(LCode));
    CloseHandle(LProcess);
  end;
  Check('child runs at MEDIUM integrity', LogLineContains('child "medium child": pid', 'integrity MEDIUM'));
  Check('GetCommandLineParameters keeps the quoting', LogContains(Format('parameters [/child %s "medium child" "a b" c]',
    [Quoted(LogFile)])));

  LProcess := StartNonElevated(ParamStr(0), '/sleep');
  Check('WaitForProcess times out on a running process', (LProcess <> 0) and not WaitForProcess(LProcess, LCode, 300));
  if LProcess <> 0 then
  begin
    TerminateProcess(LProcess, 0);
    CloseHandle(LProcess);
  end;

  SetLastError(0);
  LProcess := StartNonElevated('C:\does\not\exist.exe');
  Check('StartNonElevated fails cleanly for a missing exe', (LProcess = 0) and (GetLastError <> 0),
    SysErrorMessage(GetLastError));
end;

{ Elevated part, started with RestartSelfElevated }

procedure RunElevatedPart;
var
  LProcess: THandle;
  LCode: DWORD;
begin
  LogFile := ParamStr(2);
  Log('== elevated part: ' + WhoAmI);
  Check('RestartSelfElevated gave an elevated process', IsCurrentProcessElevated);
  Check('elevation type is FULL', GetElevationType = petFull);
  Check('parameters passed on (+ extra)', GetCommandLineParameters = '/elevated ' + Quoted(LogFile),
    GetCommandLineParameters);

  // Elevated -> normal user
  LProcess := StartNonElevated(ParamStr(0), Format('/child %s "from elevated, non elevated"', [Quoted(LogFile)]));
  Check('StartNonElevated from an elevated process', LProcess <> 0, SysErrorMessage(GetLastError));
  if LProcess <> 0 then
  begin
    Check('... exit code 7', WaitForProcess(LProcess, LCode, 15000) and (LCode = 7), IntToStr(LCode));
    CloseHandle(LProcess);
    Check('... child runs NOT elevated (MEDIUM)',
      LogLineContains('child "from elevated, non elevated": pid', 'integrity MEDIUM'));
  end;

  // Elevated -> elevated: no prompt
  LProcess := StartElevated(ParamStr(0), Format('/child %s "from elevated, elevated"', [Quoted(LogFile)]));
  Check('StartElevated from an elevated process (no prompt)', LProcess <> 0, SysErrorMessage(GetLastError));
  if LProcess <> 0 then
  begin
    Check('... exit code 7', WaitForProcess(LProcess, LCode, 15000) and (LCode = 7), IntToStr(LCode));
    CloseHandle(LProcess);
    Check('... child is elevated (HIGH)', LogLineContains('child "from elevated, elevated": pid', 'integrity HIGH'));
  end;

  // Restart this elevated process as the normal user
  Check('RestartSelfNonElevated', RestartSelfNonElevated('/restarted'), SysErrorMessage(GetLastError));
  Check('... the restarted copy runs NOT elevated', WaitForLog('restarted copy: ', 15000) and
    LogLineContains('restarted copy: ', 'integrity MEDIUM'));

  Log(Format('ELEVATED PART DONE, %d failures', [Failures]));
end;

procedure RunRestartedCopy;
begin
  LogFile := ParamStr(2);
  Log('restarted copy: ' + WhoAmI + ', parameters [' + GetCommandLineParameters + ']');
end;

procedure RunFullTest;
begin
  RunLocalTests;

  Log('== RestartSelfElevated: answer the UAC prompt (Yes)');
  if not RestartSelfElevated('/elevated ' + Quoted(LogFile)) then
  begin
    Check('RestartSelfElevated', False, SysErrorMessage(GetLastError));
    Exit;
  end;
  // A real application would close itself here. The test waits for the elevated copy.
  if not WaitForLog('ELEVATED PART DONE', 120000) then
    Check('elevated part finished', False, 'no answer within 120 s');
  Sleep(500);

  Writeln;
  Writeln('---- log written by all processes: ', LogFile);
  Writeln(TFile.ReadAllText(LogFile));
  if Pos('FAIL', TFile.ReadAllText(LogFile)) > 0 then
    Writeln('RESULT: there were failures')
  else
    Writeln('RESULT: all passed');
end;

begin
  try
    if FindCmdLineSwitch('child') then
      RunChild
    else if FindCmdLineSwitch('sleep') then
      Sleep(30000)
    else if FindCmdLineSwitch('restarted') then
      RunRestartedCopy
    else if FindCmdLineSwitch('elevated') then
    begin
      RunElevatedPart;
      Sleep(3000); // let the user see the console of the elevated copy
    end
    else
    begin
      LogFile := TPath.Combine(TPath.GetTempPath, 'ElevationHelpersTest.log');
      TFile.WriteAllText(LogFile, '');
      if FindCmdLineSwitch('local') then
      begin
        RunLocalTests;
        Writeln(Format('RESULT: %d failures', [Failures]));
      end
      else
        RunFullTest;
    end;
  except
    on E: Exception do
      Log('EXCEPTION ' + E.ClassName + ': ' + E.Message);
  end;
end.
