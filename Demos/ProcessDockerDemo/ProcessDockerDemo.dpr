program ProcessDockerDemo;

uses
  Vcl.Forms,
  ProcessToFormDocker.WinApi in '..\..\Source\ProcessToFormDocker.WinApi.pas',
  ProcessToFormDocker.Watchdog in '..\..\Source\ProcessToFormDocker.Watchdog.pas',
  ProcessToFormDocker in '..\..\Source\ProcessToFormDocker.pas',
  ProcessDockerDemo.MainForm in 'ProcessDockerDemo.MainForm.pas' {MainForm};

{$R *.res}

begin
  ReportMemoryLeaksOnShutdown := True;
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
