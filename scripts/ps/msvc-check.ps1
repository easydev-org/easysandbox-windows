# Find Visual Studio and its vcvars script, compile a program, and run it.
# vswhere is the supported way to locate VS; vcvars64.bat puts cl.exe, the SDK
# headers and the linker on PATH for this session.
$ErrorActionPreference = 'Stop'

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { Write-Output "NO_VSWHERE"; exit 1 }

$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { Write-Output "NO_VCTOOLS"; exit 1 }

$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvars)) { Write-Output "NO_VCVARS"; exit 1 }

$dir = Join-Path $env:USERPROFILE "msvc-check"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$src = Join-Path $dir "hello.c"

# ASCII, so no BOM gets in the way of cl.exe.
$code = "#include <stdio.h>" + [char]10 + "int main(void){printf(`"hello-from-msvc`");return 0;}" + [char]10
Set-Content -Path $src -Value $code -Encoding Ascii

$run = "`"`"$vcvars`"`" >nul 2>&1 && cd /d `"$dir`" && cl /nologo `"$src`" && hello.exe"
$out = cmd /c $run 2>&1
$out | ForEach-Object { Write-Output $_ }
