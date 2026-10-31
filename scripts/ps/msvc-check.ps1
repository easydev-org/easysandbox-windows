$ErrorActionPreference = "Continue"

Write-Output "=== msvc-check ==="

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
Write-Output ("vswhere exists: " + (Test-Path $vswhere))
if (-not (Test-Path $vswhere)) { Write-Output "NO_VSWHERE"; exit 1 }

$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
Write-Output ("vs path (VC.Tools required): [" + $vs + "]")

if (-not $vs) {
    $any = & $vswhere -latest -products * -property installationPath 2>$null
    Write-Output ("vs path (any product): [" + $any + "]")
    $ver = & $vswhere -latest -products * -property installationVersion 2>$null
    Write-Output ("version: [" + $ver + "]")
    Write-Output "NO_VCTOOLS"
    exit 1
}

$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
Write-Output ("vcvars exists: " + (Test-Path $vcvars) + "  " + $vcvars)
if (-not (Test-Path $vcvars)) { Write-Output "NO_VCVARS"; exit 1 }

$dir = Join-Path $env:USERPROFILE "msvc-check"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$src = Join-Path $dir "hello.c"
$code = "#include <stdio.h>" + [char]10 + "int main(void){printf(`"hello-from-msvc`");return 0;}" + [char]10
Set-Content -Path $src -Value $code -Encoding Ascii
Write-Output ("source written: " + (Test-Path $src))

# Capture both streams and the exit code of the whole cmd line.
$run = "`"`"$vcvars`"`" >nul 2>&1 && cd /d `"$dir`" && cl /nologo `"$src`" && hello.exe"
$out = cmd /c $run 2>&1
Write-Output ("cl exit: " + $LASTEXITCODE)
$out | ForEach-Object { Write-Output ("  " + $_) }

if ($out -match "hello-from-msvc") { Write-Output "COMPILE_OK" } else { Write-Output "COMPILE_FAILED" }
