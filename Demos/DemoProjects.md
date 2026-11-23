# Demo projects

## ProcessDockerDemo

`ProcessDockerDemo/ProcessDockerDemo.dpr` is a tabbed VCL application. Every tab hosts one
`TProcessDocker`.

Try this:

1. Start a *Classic cmd.exe* tab and press **Send to console**.
2. Start a *Windows Terminal* tab, then **Undock** and **Dock** it again.
3. Choose **On hang: Ask (dialog)**, start a cmd tab and press **Simulate hang (suspend)**.
   After about 5 s (the Windows hung-app timeout) the watchdog reports the hang. If the hung
   window blocks the demo UI, the emergency kill frees it after 10 s.
4. Tick **Auto restart on unexpected exit** and start *Notepad*. The Windows 11 Store Notepad
   crashes when it is docked: you can watch the crash loop protection stop the restarts.
5. Choose *Classic cmd.exe*, set the parameters to
   `cmd.exe /c "echo Working... & ping -n 3 127.0.0.1 >nul & exit 5"` and press
   **Run as app window...**. A modal form that looks like a plain console window appears. It
   closes by itself after about 2 s, and the demo reports exit code 5. Run it again and close the
   window yourself: you get `$C000013A`, the exit code of a console closed by the user.
6. Start *Registry Editor*. It requires elevation and can not be docked into a non-elevated host.
   Use **Restart demo as admin** and try again.
