# Builds VectorContourSetup.exe on Windows with the C# compiler that ships with .NET Framework.
# Run from the project folder:  powershell -ExecutionPolicy Bypass -File .\launcher\build.ps1
$root = Split-Path -Parent $PSScriptRoot
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
New-Item -ItemType Directory -Path "$root\dist" -Force | Out-Null
& $csc /nologo /target:winexe /platform:anycpu /r:System.Windows.Forms.dll `
    "/resource:$root\winsetup.ps1,winsetup.ps1" "/out:$root\dist\VectorContourSetup.exe" "$PSScriptRoot\Launcher.cs"
exit $LASTEXITCODE
