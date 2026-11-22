Unicode True

!ifndef VERSION
  !define VERSION "1.1.4"
!endif
!ifndef SRCDIR
  !define SRCDIR "..\build\win-unpacked"
!endif
!ifndef OUTFILE
  !define OUTFILE "..\成品\GravityBox-Setup-1.1.4-x64.exe"
!endif
!ifndef ICON
  !define ICON "..\assets\icons\app.ico"
!endif

!include "MUI2.nsh"

Name "GravityBox ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\GravityBox"
InstallDirRegKey HKCU "Software\GravityBox" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32

!define MUI_ABORTWARNING
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_FINISHPAGE_RUN "$INSTDIR\GravityBox.exe"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

Section "GravityBox" SecMain
  SetOutPath "$INSTDIR"

  ; Stop running instance (and child node.exe) before overwriting files during upgrade
  nsExec::ExecToLog 'taskkill /IM GravityBox.exe /T /F'
  Sleep 600

  File /r "${SRCDIR}\*.*"

  WriteRegStr HKCU "Software\GravityBox" "InstallDir" "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\GravityBox"
  CreateShortcut "$SMPROGRAMS\GravityBox\GravityBox.lnk" "$INSTDIR\GravityBox.exe" "" "$INSTDIR\GravityBox.exe" 0
  CreateShortcut "$SMPROGRAMS\GravityBox\Uninstall GravityBox.lnk" "$INSTDIR\Uninstall.exe" "" "$INSTDIR\Uninstall.exe" 0
  CreateShortcut "$DESKTOP\GravityBox.lnk" "$INSTDIR\GravityBox.exe" "" "$INSTDIR\GravityBox.exe" 0

  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "DisplayName" "GravityBox"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "Publisher" "GravityBox"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "DisplayIcon" "$INSTDIR\GravityBox.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox" "NoRepair" 1
SectionEnd

Section "Uninstall"
  nsExec::ExecToLog 'taskkill /IM GravityBox.exe /T /F'
  Sleep 600

  Delete "$DESKTOP\GravityBox.lnk"
  RMDir /r "$SMPROGRAMS\GravityBox"
  RMDir /r "$INSTDIR"

  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "GravityBox"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GravityBox"
  DeleteRegKey HKCU "Software\GravityBox"
SectionEnd
