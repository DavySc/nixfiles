# Installs what kittymax uses on native Windows, with winget, and puts a shortcut
# on the desktop.  Safe to run again: what is installed is skipped.
#
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
#
# Emacs packages are not here: kittymax installs them itself from ELPA and MELPA
# the first time it starts (it takes a few minutes, once).
#
# Every winget id below is checked against microsoft/winget-pkgs.
# Not installed, because winget has no package for them: verilator, iverilog,
# verible (hardware), sqls (SQL language server), souffle (Datalog: build it with
# CMake and MSVC, see https://souffle-lang.github.io/build). See the README.
#
# Visual Studio itself is not installed: kittymax uses its compiler and MSBuild
# when they are there (the "Desktop development with C++" workload, or the much
# smaller Build Tools: winget install Microsoft.VisualStudio.2022.BuildTools).

$ErrorActionPreference = "Continue"

$packages = @(
    @{ Id = "GNU.Emacs";                          What = "Emacs" },
    @{ Id = "Git.Git";                            What = "git (magit needs it)" },
    @{ Id = "BurntSushi.ripgrep.MSVC";            What = "ripgrep (project search)" },
    @{ Id = "sharkdp.fd";                         What = "fd (file search)" },
    @{ Id = "LLVM.LLVM";                          What = "clangd, clang-format, clang (C, C++)" },
    @{ Id = "Kitware.CMake";                      What = "CMake (C projects)" },
    @{ Id = "Ninja-build.Ninja";                  What = "Ninja (CMake builds)" },
    @{ Id = "Microsoft.DotNet.SDK.10";            What = ".NET 10 SDK (C#, C# org blocks, the database client)" },
    @{ Id = "Samsung.NetCoreDbg";                 What = "netcoredbg (C# debugger)" },
    @{ Id = "Microsoft.Sqlcmd";                   What = "sqlcmd (org's sql blocks with :engine mssql)" },
    @{ Id = "JohnMacFarlane.Pandoc";              What = "pandoc (Word export, markdown preview)" },
    @{ Id = "MiKTeX.MiKTeX";                      What = "MiKTeX (org: PDF export and LaTeX previews)" },
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

# winget changed PATH for new processes only; pick it up here for the steps below.
$env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

$data = Join-Path $env:LOCALAPPDATA "kittymax\data"
New-Item -ItemType Directory -Force -Path $data | Out-Null

# C# language server (needs the SDK above)
if (Get-Command dotnet -ErrorAction SilentlyContinue) {
    Write-Host "== csharp-ls" -ForegroundColor Cyan
    dotnet tool install --global csharp-ls 2>$null
    if ($LASTEXITCODE -ne 0) { dotnet tool update --global csharp-ls }
}

# CodeLLDB: the debugger for C built by MSVC (it reads PDBs). Not on winget:
# its release is a VS Code extension, a zip with the adapter inside.
$codelldb = Join-Path $data "debug-adapters\codelldb"
if (-not (Test-Path (Join-Path $codelldb "extension\adapter\codelldb.exe"))) {
    Write-Host "== CodeLLDB (C debugger)" -ForegroundColor Cyan
    $vsix = Join-Path $env:TEMP "codelldb-win32-x64.zip"
    try {
        Invoke-WebRequest -UseBasicParsing -OutFile $vsix `
            "https://github.com/vadimcn/codelldb/releases/latest/download/codelldb-win32-x64.vsix"
        New-Item -ItemType Directory -Force -Path $codelldb | Out-Null
        Expand-Archive -Force -Path $vsix -DestinationPath $codelldb
        Remove-Item $vsix
    } catch {
        Write-Warning "CodeLLDB download failed: $_"
    }
}

# The database client's backend: dbbliss.nvim's, shared with Neovim. When
# Neovim already built it (:Dbbliss build), kittymax uses that one.
$nvimBackend = Join-Path $env:LOCALAPPDATA "nvim-data\site\pack\core\opt\dbbliss.nvim\bin\win-x64\dbbliss-backend.exe"
$dbbliss = Join-Path $data "dbbliss.nvim"
if (-not (Test-Path $nvimBackend) -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Host "== dbbliss backend (the SQL Server / PostgreSQL client)" -ForegroundColor Cyan
    if (Test-Path (Join-Path $dbbliss ".git")) {
        git -C $dbbliss pull --ff-only
    } else {
        git clone https://github.com/DavySc/dbbliss.nvim $dbbliss
    }
    if (Test-Path (Join-Path $dbbliss "scripts\build.ps1")) {
        # Plain build output: each restore error is printed, not only counted.
        $env:MSBUILDTERMINALLOGGER = "off"
        try {
            & (Join-Path $dbbliss "scripts\build.ps1")
        } catch {
            # A failed build must not stop the rest of the install.
            Write-Warning "The dbbliss backend did not build: $_"
            Write-Warning "The error lines above say why (error NU...: a NuGet package problem; NETSDK1045: no .NET 10 SDK yet, open a new terminal)."
            Write-Warning "Everything else in kittymax works without it; M-x kitty-dbbliss-build tries again."
        }
    }
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
Write-Host ""
Write-Host "Databases: put your connections in local.el (kitty-dbbliss-connections; see the README)."
Write-Host "MiKTeX installs LaTeX packages on first use: allow it when it asks."
Write-Host ""
Write-Host "Optional, for SQL: sqldiff (lint and cross-dialect diff) and sqlfluff (T-SQL formatting):"
Write-Host "  winget install Rustlang.Rustup; cargo install --git https://github.com/DavySc/SQLDiff sqldiff-cli"
Write-Host "  pip install sqlfluff"
