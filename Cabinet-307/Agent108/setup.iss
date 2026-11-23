[Setup]
AppId=Agent108
AppName=Agent108
AppVersion=1.3.0
SetupIconFile=assets\agent108.ico
UninstallDisplayIcon={app}\Agent108.exe
DefaultDirName={autopf}\Agent108
DisableDirPage=yes
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
OutputDir=dist
OutputBaseFilename=Agent108-Setup
[Files]
Source: "dist\Agent108.exe"; DestDir: "{app}"; Flags: ignoreversion
[Icons]
Name: "{commonprograms}\Agent108"; Filename: "{app}\Agent108.exe"; IconFilename: "{app}\Agent108.exe"; AppUserModelID: "Edu108.Agent108"
[Code]
var ModePage:TInputOptionWizardPage; IntervalPage:TInputQueryWizardPage; Hint:TNewStaticText;
procedure InitializeWizard;
begin
 ModePage:=CreateInputOptionPage(wpWelcome,'Wi-Fi','Режим на Agent108','Изберете разрешените мрежи.',True,False);
 ModePage.Add('Само Students'); ModePage.Add('Всички мрежи разрешени'); ModePage.SelectedValueIndex:=0;
 IntervalPage:=CreateInputQueryPage(ModePage.ID,'Автоматично свързване','Настройки за Students','DNS се запазва.');
 IntervalPage.Add('Автоматично свързване към Students (през колко секунди)',False); IntervalPage.Values[0]:='60';
 Hint:=TNewStaticText.Create(IntervalPage); Hint.Parent:=IntervalPage.Surface; Hint.AutoSize:=False; Hint.WordWrap:=True;
 Hint.SetBounds(0,IntervalPage.Edits[0].Top+IntervalPage.Edits[0].Height+ScaleY(8),IntervalPage.SurfaceWidth,ScaleY(96));
 Hint.Caption:='Ако Wi-Fi е прекъснат, Agent108 опитва да свърже компютъра към Students. Ако Wi-Fi е изключен от Windows, агентът първо го включва. При работеща връзка не предприема действие. Стойност 0 изключва автоматичните опити.';
end;
function NextButtonClick(PageID:Integer):Boolean;
var N:Integer;
begin
 Result:=True;
 if PageID=IntervalPage.ID then begin N:=StrToIntDef(IntervalPage.Values[0],-1);Result:=(N>=0) and (N<=86400); if not Result then MsgBox('Въведете от 0 до 86400 секунди.',mbError,MB_OK);end;
end;
procedure CurStepChanged(Step:TSetupStep);
var M,S,SavedPolicy:String; N,Code:Integer;
begin
 if Step=ssPostInstall then begin
 if (ExpandConstant('{param:PRESERVE|1}')='1') and RegQueryStringValue(HKLM64,'Software\Agent108','Policy',SavedPolicy) and (Trim(SavedPolicy)<>'') then begin
 if not Exec(ExpandConstant('{app}\Agent108.exe'),'upgrade','',SW_HIDE,ewWaitUntilTerminated,Code) then RaiseException('Agent108 could not start');
 if Code<>0 then RaiseException('Could not restore saved Agent108 workers. Existing settings were preserved.');
 end else begin
 if ModePage.SelectedValueIndex=0 then M:='Students' else M:='All';
 M:=ExpandConstant('{param:MODE|'+M+'}'); S:=ExpandConstant('{param:SECONDS|'+IntervalPage.Values[0]+'}');
 N:=StrToIntDef(S,-1);
 if ((M<>'Students') and (M<>'All')) or (N<0) or (N>86400) then RaiseException('Invalid Agent108 settings');
 if not Exec(ExpandConstant('{app}\Agent108.exe'),'install '+M+' '+IntToStr(N),'',SW_HIDE,ewWaitUntilTerminated,Code) then RaiseException('Agent108 could not start');
 if Code<>0 then RaiseException('Could not configure Wi-Fi. Check the saved Students profile and local policy.');
 end;
 end;
end;
[UninstallRun]
Filename: "{app}\Agent108.exe"; Parameters: "games-off"; Flags: runhidden
Filename: "{app}\Agent108.exe"; Parameters: "browsers-off"; Flags: runhidden
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN Agent108-BrowserGuard"; Flags: runhidden
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN Agent108-BrowserGuard /F"; Flags: runhidden
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN Agent108-Reconnect"; Flags: runhidden
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN Agent108-Reconnect /F"; Flags: runhidden
