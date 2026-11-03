# Installs what kittymax uses on native Windows, with winget, and puts a shortcut
# on the desktop.  Safe to run again: what is installed is skipped.
#
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#
# Emacs packages are not here: kittymax installs them itself from ELPA and MELPA
# the first time it starts (it takes a few minutes, once).
#
# Not installed, because winget has no reliable package for them: verilator,
# iverilog, verible (hardware), sqls (SQL language server). See the README.

$ErrorActionPreference = "Continue"

$packages = @(
    @{ Id = "GNU.Emacs";                          What = "Emacs" },
    @{ Id = "Git.Git";                            What = "git (magit needs it)" },
    @{ Id = "BurntSushi.ripgrep.MSVC";            What = "ripgrep (project search)" },
    @{ Id = "sharkdp.fd";                         What = "fd (file search)" },
    @{ Id = "LLVM.LLVM";                          What = "clangd and clang-format (C, C++)" },
    @{ Id = "Microsoft.DotNet.SDK.9";             What = ".NET SDK (C#)" },
    @{ Id = "JohnMacFarlane.Pandoc";              What = "pandoc (markdown preview and export)" },
    @{ Id = "DEVCOM.JetBrainsMonoNerdFont";       What = "JetBrainsMono Nerd Font (code font and icons)" }
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "winget not found. Install 'App Installer' from the Microsoft Store, then run this again."
    exit 1
}

foreach ($p in $packages) {
    Write-Host "== $($p.What)" -ForegroundColor Cyan
    winget install --id $p.Id --exact --silent --accept-source-agreements --accept-package-agreements
}

# C# language server (needs the SDK above) and a markdown one, when dotnet / npm exist
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Write-Host "== csharp-ls" -ForegroundColor Cyan
    dotnet tool install --global csharp-ls 2>$null
    if ($LASTEXITCODE -ne 0) { dotnet tool update --global csharp-ls }
}

# A desktop shortcut to the launcher
$launcher = Join-Path $PSScriptRoot "kittymax.cmd"
$shortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "kittymax.lnk"
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = $launcher
$link.WorkingDirectory = [Environment]::GetFolderPath("UserProfile")
$link.WindowStyle = 7   # minimized: only the cmd flash, not a console window left open
$link.Description = "kittymax"
$link.Save()

Write-Host ""
Write-Host "Done. Open a new terminal (so PATH is refreshed), then start kittymax from the" -ForegroundColor Green
Write-Host "desktop shortcut or with:  $launcher" -ForegroundColor Green
Write-Host "The first start installs the Emacs packages; give it a few minutes."
