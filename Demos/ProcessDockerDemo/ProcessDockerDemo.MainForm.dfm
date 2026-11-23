object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'Process To Form Docker - Demo'
  ClientHeight = 720
  ClientWidth = 1180
  Color = clBtnFace
  Constraints.MinHeight = 400
  Constraints.MinWidth = 700
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  TextHeight = 15
  object FlowPanelLaunch: TFlowPanel
    Left = 0
    Top = 0
    Width = 1180
    Height = 34
    Align = alTop
    AutoSize = True
    BevelOuter = bvNone
    Padding.Left = 4
    Padding.Top = 2
    Padding.Right = 4
    Padding.Bottom = 2
    TabOrder = 0
    object LabelPreset: TLabel
      AlignWithMargins = True
      Left = 7
      Top = 9
      Width = 38
      Height = 15
      Margins.Top = 7
      Caption = 'Preset:'
    end
    object ComboBoxPreset: TComboBox
      AlignWithMargins = True
      Left = 51
      Top = 5
      Width = 300
      Height = 23
      Style = csDropDownList
      TabOrder = 0
      OnChange = ComboBoxPresetChange
    end
    object LabelFileName: TLabel
      AlignWithMargins = True
      Left = 357
      Top = 9
      Width = 21
      Height = 15
      Margins.Top = 7
      Caption = 'File:'
    end
    object EditFileName: TEdit
      AlignWithMargins = True
      Left = 384
      Top = 5
      Width = 250
      Height = 23
      TabOrder = 1
    end
    object LabelParameters: TLabel
      AlignWithMargins = True
      Left = 640
      Top = 9
      Width = 62
      Height = 15
      Margins.Top = 7
      Caption = 'Parameters:'
    end
    object EditParameters: TEdit
      AlignWithMargins = True
      Left = 708
      Top = 5
      Width = 150
      Height = 23
      TabOrder = 2
    end
    object CheckBoxElevated: TCheckBox
      AlignWithMargins = True
      Left = 864
      Top = 7
      Width = 95
      Height = 19
      Margins.Top = 5
      Caption = 'Run elevated'
      TabOrder = 3
    end
    object ButtonStart: TButton
      AlignWithMargins = True
      Left = 965
      Top = 5
      Width = 120
      Height = 25
      Caption = 'Start in new tab'
      Default = True
      TabOrder = 4
      OnClick = ButtonStartClick
    end
    object ButtonRelaunchAsAdmin: TButton
      AlignWithMargins = True
      Left = 1091
      Top = 5
      Width = 150
      Height = 25
      Hint = 'Elevated windows can only be docked by an elevated host (UIPI)'
      Caption = 'Restart demo as admin'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 5
      OnClick = ButtonRelaunchAsAdminClick
    end
  end
  object FlowPanelActions: TFlowPanel
    Left = 0
    Top = 34
    Width = 1180
    Height = 34
    Align = alTop
    AutoSize = True
    BevelOuter = bvNone
    Padding.Left = 4
    Padding.Top = 2
    Padding.Right = 4
    Padding.Bottom = 2
    TabOrder = 1
    object ButtonClose: TButton
      AlignWithMargins = True
      Left = 7
      Top = 5
      Width = 110
      Height = 25
      Hint = 'Posts WM_CLOSE, kills after CloseTimeoutMs if the app does not close'
      Caption = 'Close (WM_CLOSE)'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 0
      OnClick = ButtonCloseClick
    end
    object ButtonKill: TButton
      AlignWithMargins = True
      Left = 123
      Top = 5
      Width = 75
      Height = 25
      Caption = 'Kill'
      TabOrder = 1
      OnClick = ButtonKillClick
    end
    object ButtonRestart: TButton
      AlignWithMargins = True
      Left = 204
      Top = 5
      Width = 75
      Height = 25
      Caption = 'Restart'
      TabOrder = 2
      OnClick = ButtonRestartClick
    end
    object ButtonUndock: TButton
      AlignWithMargins = True
      Left = 285
      Top = 5
      Width = 75
      Height = 25
      Caption = 'Undock'
      TabOrder = 3
      OnClick = ButtonUndockClick
    end
    object ButtonSimulateHang: TButton
      AlignWithMargins = True
      Left = 366
      Top = 5
      Width = 150
      Height = 25
      Hint = 'Suspends the process so it stops processing messages'
      Caption = 'Simulate hang (suspend)'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 4
      OnClick = ButtonSimulateHangClick
    end
    object ButtonResume: TButton
      AlignWithMargins = True
      Left = 522
      Top = 5
      Width = 75
      Height = 25
      Caption = 'Resume'
      TabOrder = 5
      OnClick = ButtonResumeClick
    end
    object ButtonCloseTab: TButton
      AlignWithMargins = True
      Left = 603
      Top = 5
      Width = 75
      Height = 25
      Caption = 'Close tab'
      TabOrder = 6
      OnClick = ButtonCloseTabClick
    end
    object EditSendText: TEdit
      AlignWithMargins = True
      Left = 684
      Top = 5
      Width = 200
      Height = 23
      Hint = 'Posted as WM_CHAR + Enter, works with classic console windows'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 7
      Text = 'echo Hello from the host & ver'
    end
    object ButtonSendText: TButton
      AlignWithMargins = True
      Left = 890
      Top = 5
      Width = 110
      Height = 25
      Caption = 'Send to console'
      TabOrder = 8
      OnClick = ButtonSendTextClick
    end
  end
  object FlowPanelWatchdog: TFlowPanel
    Left = 0
    Top = 68
    Width = 1180
    Height = 34
    Align = alTop
    AutoSize = True
    BevelOuter = bvNone
    Padding.Left = 4
    Padding.Top = 2
    Padding.Right = 4
    Padding.Bottom = 2
    TabOrder = 2
    object LabelHangAction: TLabel
      AlignWithMargins = True
      Left = 7
      Top = 9
      Width = 52
      Height = 15
      Margins.Top = 7
      Caption = 'On hang:'
    end
    object ComboBoxHangAction: TComboBox
      AlignWithMargins = True
      Left = 65
      Top = 5
      Width = 140
      Height = 23
      Style = csDropDownList
      TabOrder = 0
      OnChange = WatchdogOptionChange
      Items.Strings = (
        'Notify only'
        'Kill'
        'Restart'
        'Ask (dialog)')
    end
    object LabelHangTimeout: TLabel
      AlignWithMargins = True
      Left = 211
      Top = 9
      Width = 200
      Height = 15
      Margins.Top = 7
      Caption = 'Hang timeout ms (0 = Windows default):'
    end
    object EditHangTimeout: TEdit
      AlignWithMargins = True
      Left = 417
      Top = 5
      Width = 60
      Height = 23
      TabOrder = 1
      Text = '0'
      OnChange = WatchdogOptionChange
    end
    object CheckBoxRestartOnExit: TCheckBox
      AlignWithMargins = True
      Left = 483
      Top = 7
      Width = 200
      Height = 19
      Margins.Top = 5
      Hint = 'Crash loop protection: max 3 automatic restarts per minute'
      Caption = 'Auto restart on unexpected exit'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 2
      OnClick = WatchdogOptionChange
    end
    object CheckBoxConfirm: TCheckBox
      AlignWithMargins = True
      Left = 689
      Top = 7
      Width = 140
      Height = 19
      Margins.Top = 5
      Hint = 'Uses OnBeforeKill / OnBeforeRestart (var AAllow)'
      Caption = 'Confirm kill / restart'
      ParentShowHint = False
      ShowHint = True
      TabOrder = 3
    end
    object CheckBoxEmergencyKill: TCheckBox
      AlignWithMargins = True
      Left = 835
      Top = 7
      Width = 250
      Height = 19
      Margins.Top = 5
      Hint =
        'If the host UI is blocked by the hung window for 10 s after the ' +
        'hang was reported, the watchdog thread kills the process'
      Caption = 'Emergency kill if this UI is blocked (10 s)'
      Checked = True
      ParentShowHint = False
      ShowHint = True
      State = cbChecked
      TabOrder = 4
      OnClick = WatchdogOptionChange
    end
  end
  object PageControlSessions: TPageControl
    Left = 0
    Top = 102
    Width = 1180
    Height = 452
    Align = alClient
    TabOrder = 3
    OnChange = PageControlSessionsChange
  end
  object SplitterLog: TSplitter
    Left = 0
    Top = 554
    Width = 1180
    Height = 4
    Cursor = crVSplit
    Align = alBottom
  end
  object MemoLog: TMemo
    Left = 0
    Top = 558
    Width = 1180
    Height = 140
    Align = alBottom
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 4
    WordWrap = False
  end
  object StatusBar: TStatusBar
    Left = 0
    Top = 698
    Width = 1180
    Height = 22
    Panels = <
      item
        Width = 300
      end
      item
        Width = 300
      end
      item
        Width = 220
      end
      item
        Width = 50
      end>
  end
  object TimerStatus: TTimer
    OnTimer = TimerStatusTimer
    Left = 1096
    Top = 120
  end
end
