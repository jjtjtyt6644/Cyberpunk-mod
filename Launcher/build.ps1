# Builds the Night City Trainer launcher into ..\dist using the C# compiler
# that ships with Windows. No extra tools needed.
#
#   .\build.ps1                         build a launcher that updates from the GitHub repo
#   .\build.ps1 -UpdateUrl ""           build with updates switched off
#
# After a build, dist\ holds everything to publish:
#   NightCityTrainer.exe      send this to friends (once)
#   version.json + init.lua   commit and push these two for every new trainer version

param(
    [string]$UpdateUrl = "https://raw.githubusercontent.com/jjtjtyt6644/Cyberpunk-mod/main/dist/version.json",
    [string]$LauncherVersion = "1.0.0",
    [string]$Lua = "",      # trainer file to bundle (default: ..\NightCityTrainer\init.lua)
    [string]$OutDir = ""    # output folder (default: ..\dist)
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$lua  = if ($Lua) { $Lua } else { Join-Path $root "..\NightCityTrainer\init.lua" }
$dist = if ($OutDir) { $OutDir } else { Join-Path $root "..\dist" }

if ($UpdateUrl -and -not $UpdateUrl.StartsWith("https://")) {
    throw "UpdateUrl must start with https://"
}

$luaText = [IO.File]::ReadAllText($lua)
if ($luaText -notmatch 'version\s*=\s*"(\d+(?:\.\d+){1,3})"') { throw "No version found in init.lua" }
$trainerVersion = $Matches[1]

New-Item -ItemType Directory -Force $dist | Out-Null

# Values baked into this build.
$buildInfo = @"
namespace NightCityTrainer
{
    public static class BuildInfo
    {
        public const string UpdateManifestUrl = "$UpdateUrl";
        public const string LauncherVersion = "$LauncherVersion";
    }
}
"@
$buildInfoFile = Join-Path $root "BuildInfo.cs"
[IO.File]::WriteAllText($buildInfoFile, $buildInfo)

$fw  = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$csc = Join-Path $fw "csc.exe"
$exe = Join-Path $dist "NightCityTrainer.exe"

& $csc /nologo /target:winexe /optimize+ /platform:anycpu "/out:$exe" `
    "/resource:$lua,init.lua" `
    "/resource:$(Join-Path $root 'Launcher.xaml'),Launcher.xaml" `
    /r:System.dll /r:System.Core.dll /r:System.Xaml.dll /r:System.Web.Extensions.dll `
    /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Windows.Forms.dll `
    "/r:$fw\WPF\PresentationCore.dll" "/r:$fw\WPF\PresentationFramework.dll" "/r:$fw\WPF\WindowsBase.dll" `
    (Join-Path $root "Launcher.cs") $buildInfoFile

if ($LASTEXITCODE -ne 0) { throw "Build failed" }

# Files to upload for the auto-updater.
Copy-Item $lua (Join-Path $dist "init.lua") -Force
$luaUrl = ""
if ($UpdateUrl) { $luaUrl = $UpdateUrl.Substring(0, $UpdateUrl.LastIndexOf("/") + 1) + "init.lua" }
$manifest = "{`n  `"version`": `"$trainerVersion`",`n  `"url`": `"$luaUrl`"`n}`n"
[IO.File]::WriteAllText((Join-Path $dist "version.json"), $manifest)

"Built $exe"
"Trainer version $trainerVersion, launcher version $LauncherVersion"
if ($UpdateUrl) { "Updates: $UpdateUrl" } else { "Updates: off (no -UpdateUrl given)" }
