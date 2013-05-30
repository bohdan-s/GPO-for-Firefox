' GPO for Firefox
' Version 0.1.0
'
' Author: Bohdan Sanders
'
' GPO for Firefox is a way of allowing centrally managed locked and/or default settings 
' in Firefox via Group Policy and Administrative Templates in Active Directory.
' 
' GPO for Firefox is a continuation of FirefoxADM by Mark Sammons & FirefoxADMX by Nathan Felton.
' 
' This work is licensed under the Creative Commons Attribution 3.0 Unported License. 
' To view a copy of this license, visit http://creativecommons.org/licenses/by/3.0/
'
' Version 0.1.0
'  Initial release

On Error Resume Next

Dim objShell  		:   Set objShell = WScript.CreateObject("WScript.Shell")
Dim objFSO				:	Set objFSO = WScript.CreateObject("Scripting.FileSystemObject")
Dim objEnv				: 	Set objEnv = objShell.Environment("Process")
Dim objWMIService		:	Set objWMIService = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\cimv2")
Dim objArgs				: 	Set objArgs = WScript.Arguments

' File Access Types
Const ForReading = 1, ForWriting = 2, ForAppending = 8

' Script variables
Dim strProgName			:	strProgName 	= "GPO for Firefox"
Dim strVersion			:	strVersion 		= "0.1.0.0"

' Variables required for logging.
Dim fileLog
Dim strLogLocation		:	strLogLocation = objEnv("TEMP") & "\FirefoxADMX.log"

' Global variables used by the various parts of the script.
Dim policiesRegistry	:	policiesRegistry = "HKLM\Software\Policies\Mozilla\Firefox"
Dim baseRegistry		:	baseRegistry = ""
Dim firefoxVersion		:	firefoxVersion = ""
Dim firefoxMajorVersion	:	firefoxMajorVersion = ""
Dim firefoxInstallDir	:	firefoxInstallDir = ""
Dim strMozillaCfgFile	:	strMozillaCfgFile = ""
Dim strAllSettingsFile	:	strAllSettingsFile = ""
Dim strOverrideFile		:	strOverrideFile = ""

' All strings are contained by quotes by default,
' This list are exceptions to that rule
' True and False are never in quotes
Dim arryNoQuotes
arryNoQuotes = Array(	"browser.download.folderList",_
						"network.proxy.type",_
						"network.proxy.http_port",_
						"network.proxy.ssl_port",_
						"network.proxy.ftp_port")

prepareLogFile

'forceCScript
determineArchitecture
locateInstallation

setFileLocations
forceConfigFiles
prepareCfgFile

ApplyPolicies

Sub ApplyPolicies()
	On Error Resume Next

	hDefKey = &H80000002 	' HKEY_LOCAL_MACHINE
	strPolicyKeyPath = "Software\Policies\Mozilla\Firefox"

	Set oReg = GetObject("winmgmts:{impersonationLevel=impersonate}!\\.\root\default:StdRegProv")
	writeLog "Reading GPO Settings from Registry: " + strPolicyKeyPath
	oReg.EnumKey hDefKey, strPolicyKeyPath, arrSubKeys

	For Each strSubkey In arrSubKeys
		strSubKeyPath = strPolicyKeyPath & "\" & strSubkey
		oReg.EnumValues hDefKey, strSubKeyPath, arrValueNames, arrTypes

		For i = LBound(arrValueNames) To UBound(arrValueNames)
			strValueName = arrValueNames(i)
			Select Case arrTypes(i)
				Case 1	' REG_SZ          
					oReg.GetStringValue hDefKey, strSubKeyPath, strValueName, strValue
					If strValue = "true" or strValue = "false" or removeQuotes(strValueName) Then
						writeConfig strValueName,strValue,False, strSubkey
					Else
						writeConfig strValueName,strValue,True, strSubkey
					End If

				Case 4	' REG_DWORD - For future development
					' oReg.GetDWORDValue hDefKey, strSubKeyPath, strValueName, uValue
			End Select
		Next
	Next
End Sub

' Check if we need quotes
Function removeQuotes(strValue)
	removeQuotes = False
	For Each strArrValue in arryNoQuotes
		If strValue = strArrValue Then
			removeQuotes = True
			Exit Function
		End If
	Next
End Function

' ? not used yet ?
Sub setDisableImport()
	Dim keyDisableImport, fileOverride, arrOverrideContents, strEnableProfileMigrator
	keyDisableImport = getRegistryKey(policiesRegistry & "\DisableImport")
	If keyDisableImport <> "" Then
		Select Case keyDisableImport
			Case 0
				writeLog "Enabling Import Wizard"
				strEnableProfileMigrator = "EnableProfileMigrator=true"
			Case 1
				writeLog "Disabling Import Wizard"
				strEnableProfileMigrator = "EnableProfileMigrator=false"
		End Select
		If objFSO.FileExists(strOverrideFile) Then
			Set fileOverride = objFSO.GetFile(strOverrideFile)
			If fileOverride.Size > 0 Then 'If the file already exists but is not empty
				writeLog strOverrideFile & " already exists. Replaceing contents"
				Set fileOverride = objFSO.OpenTextFile(strOverrideFile, ForReading)
				arrOverrideContents = Split(fileOverride.ReadAll, vbCrLf)
				arrOverrideContents = Filter(arrOverrideContents,"[XRE]", False, vbTextCompare)
				arrOverrideContents = Filter(arrOverrideContents,"EnableProfileMigrator", False, vbTextCompare)
				Set fileOverride = objFSO.OpenTextFile(strOverrideFile, ForWriting)
				fileOverride.WriteLine "[XRE]"
				fileOverride.WriteLine strEnableProfileMigrator
				fileOverride.Write Join(arrOverrideContents,vbCrLf)
				fileOverride.Close
			Else 'If the file exists but is Empty
				writeLog strOverrideFile & " exists, but is empty. Adding contents"
				Set fileOverride = objFSO.OpenTextFile(strOverrideFile, ForWriting)
				fileOverride.WriteLine "[XRE]"
				fileOverride.WriteLine strEnableProfileMigrator
				fileOverride.Close
			End If	
		Else 'If the file does not exist at all
			writeLog "Creating " & strOverrideFile
			Set fileOverride = objFSO.OpenTextFile(strOverrideFile, ForWriting, True)
			fileOverride.WriteLine "[XRE]"
			fileOverride.WriteLine strEnableProfileMigrator
			fileOverride.Close	
		End If
	End If
End Sub

' Find if 32 or 64 bit
Sub determineArchitecture()
	Dim colArchitecture	: Set colArchitecture = objWMIService.ExecQuery("Select AddressWidth from Win32_Processor")
	Dim objArch, strArch
	
	For Each objArch In colArchitecture
		strArch = objArch.AddressWidth
	Next
	
	Select Case strArch
		Case "64"
			baseRegistry = "HKLM\Software\Wow6432Node\Mozilla\Mozilla Firefox\"
		Case "32"
			baseRegistry = "HKLM\Software\Mozilla\Mozilla Firefox\"	
	End Select
End Sub

' Finds locations of folders
Sub locateInstallation()
	On Error Resume Next
	firefoxVersion = objShell.RegRead(baseRegistry & "CurrentVersion")
	If Err.Number <> 0 Then
		writeLog "Mozilla Firefox not installed. Exiting."
		Err.Clear
		WScript.Quit(1)
	Else
		firefoxInstallDir = objShell.RegRead(baseRegistry & firefoxVersion & "\Main\Install Directory")
		firefoxVersion = split(firefoxVersion,Chr(32))(0)
		firefoxMajorVersion = split(firefoxVersion,Chr(46))(0)
		
		'If the Firefox installation directory can not be found in the registry, use the default 32-bit OS location
		'(C:\Program Files\Mozilla Firefox) by default.
		If firefoxInstallDir = "" Then
			firefoxInstallDir = objEnv("ProgramFiles") & "\Mozilla Firefox"
			writeLog "Installation Directory Not Found in Registry"
		End If
		writeLog "Firefox Version: " & firefoxVersion
		writeLog "Installation Directory: " & firefoxInstallDir
	End If
End Sub

' Sets locations of folders
Sub setFileLocations()
	strMozillaCfgFile = firefoxInstallDir & "\mozilla.cfg"
	strAllSettingsFile = firefoxInstallDir & "\defaults\pref\all-settings.js"
	strOverrideFile = firefoxInstallDir & "\override.ini"
End Sub

' Enables mozila.cfg being read
Sub forceConfigFiles()
	On Error Resume Next
	Dim strConfigFile, strConfigObscure, fileAllSettings, arrAllSettingsContents
	strConfigFile = "pref(" & Chr(34) & "general.config.filename" & Chr(34) & "," & Chr(34) & "mozilla.cfg" & Chr(34) & ");"
	strConfigObscure = "pref(" & Chr(34) & "general.config.obscure_value" & Chr(34) & "," & "0" & ");"
	If objFSO.FileExists(strAllSettingsFile) Then 'Check if the file exists first.
		Set fileAllSettings = objFSO.GetFile(strAllSettingsFile)
		'If the file does exist, then make sure it's not empty.
		If fileAllSettings.Size > 0 Then 'If the file is NOT empty
			Set fileAllSettings = objFSO.OpenTextFile(strAllSettingsFile, ForReading)
			arrAllSettingsContents = Split(fileAllSettings.ReadAll, vbCrLf)
			arrAllSettingsContents = Filter(arrAllSettingsContents,"general.config.filename", False, vbTextCompare)
			arrAllSettingsContents = Filter(arrAllSettingsContents,"general.config.obscure_value", False, vbTextCompare)
			Set fileAllSettings = objFSO.OpenTextFile(strAllSettingsFile, ForWriting)
			fileAllSettings.WriteLine strConfigFile
			fileAllSettings.WriteLine strConfigObscure
			fileAllSettings.Write Join(arrAllSettingsContents,vbCrLf)
			fileAllSettings.Close
		Else 'If the file IS empty
			Set fileAllSettings = objFSO.OpenTextFile(strAllSettingsFile, ForWriting)
			fileAllSettings.WriteLine strConfigFile
			fileAllSettings.WriteLine strConfigObscure
			fileAllSettings.Close
		End If
	Else
		Set fileAllSettings = objFSO.OpenTextFile(strAllSettingsFile, ForWriting, True)
		fileAllSettings.WriteLine strConfigFile
		fileAllSettings.WriteLine strConfigObscure
		fileAllSettings.Close
	End If
	Dim fileMozillaCfg, arrMozillaCfgContents
	If objFSO.FileExists(strMozillaCfgFile) Then 'Check if the file exists first.
		Set fileMozillaCfg = objFSO.GetFile(strMozillaCfgFile)
		'If the file does exist, then make sure it's not empty.
		If fileMozillaCfg.Size > 0 Then 'If the file is NOT empty
			Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile, ForReading)
			arrMozillaCfgContents = Split(fileMozillaCfg.ReadAll, vbCrLf)
			arrMozillaCfgContents = Filter(arrMozillaCfgContents,"//", False, vbTextCompare)
			Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile, ForWriting)
			fileMozillaCfg.WriteLine "//"
			fileMozillaCfg.Write Join(arrMozillaCfgContents,vbCrLf)
			fileMozillaCfg.Close
		Else 'If the file IS empty
			Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile, ForWriting)
			fileMozillaCfg.WriteLine "//"
			fileMozillaCfg.Close
		End If
	Else
		Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile, ForWriting, True)
		fileMozillaCfg.WriteLine "//"
		fileMozillaCfg.Close
	End If
	On Error GoTo 0
End Sub

' Writes config to mozilla.cfg
Sub writeConfig(strPreference,strValue,boolQuoted,strSubkey)
	Dim fileMozillaCfg, arrMozillaCfgContents
	If boolQuoted Then
		strPreference = "lockPref(" & Chr(34) & strPreference & Chr(34) & ", " & Chr(34) & strValue & Chr(34) & ");"
	Else
		strPreference = "lockPref(" & Chr(34) & strPreference & Chr(34) & ", " & strValue & ");"
	End If
	
	Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile,ForAppending,False)
	fileMozillaCfg.WriteLine strPreference
	fileMozillaCfg.Close
End Sub

' Prepares a blank mozilla.cfg file for writing to
Sub prepareCfgFile()
	On Error Resume Next
	Set fileMozillaCfg = objFSO.OpenTextFile(strMozillaCfgFile,ForWriting,True)
	fileMozillaCfg.WriteLine "//"
	fileMozillaCfg.Close
	
	If Err.Number = 70 Then ' Access Denied
		writeLog "Config File Inaccessable. Please make sure another instance isn't running and that you are an administrator."
		MsgBox "Config File Inaccessable. Please make sure another instance isn't running and that you are an administrator."
		WScript.Quit(1)
	End If
End Sub

' Prepares the log file for access
Sub prepareLogFile()
	On Error Resume Next
	Set fileLog = objFSO.OpenTextFile(strLogLocation,ForAppending,True)
	If Err.Number = 70 Then ' Access Denied
		MsgBox "Log File Inaccessable. Please make sure another instance isn't running and that you are an administrator."
		WScript.Quit(1)
	Else
		writeLog ""
		writeLog "-----------------------------------------------------------------"
		writeLog vbTab & "Starting New Instance"
		writeLog vbTab & strProgName & vbTab & vbTab & "v" & strVersion
		writeLog "-----------------------------------------------------------------"
		writeLog ""
	End If
End Sub

' Writes to the log file
Sub writeLog(strMessage)
	logFormat = "["&time&"]"&" "& strMessage
	fileLog.WriteLine(logFormat)
End Sub

' NEEDED?
' Forces the script to be run using "CScript.exe" rather than the often default "WScript.exe"
Sub forceCScript()
	Dim strArgs	:	strArgs = " "
	Dim i, iWindow
	For i = 0 To objArgs.Count-1
		strArgs = strArgs & objArgs.Item(i) & " "
	Next
	If bQN Then
		iWindow = 0
	ElseIf bQB Then
		iWindow = 1
	Else
		iWindow = 1
	End If
	
	If InStr(WScript.FullName,"cscript") = 0 Then
		objShell.Run "%comspec% /k " & WScript.Path & "\cscript.exe " & Chr(34) & WScript.ScriptFullName & Chr(34) & strArgs,iWindow,False
		WScript.Quit(0)
	End If
End Sub
