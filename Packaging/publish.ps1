<#
.SYNOPSIS
    Builds SysInfo for distribution: self-contained build per OS (no .NET to install), archived with its installer.
.DESCRIPTION
    For each runtime: dotnet publish (Release, self-contained, not single-file), then
      artifacts/SysInfo-<version>-<runtime>/          the application folder
      artifacts/SysInfo-<version>-<runtime>.zip       Windows (install.ps1 inside)
      artifacts/SysInfo-<version>-<runtime>.tar.gz    Linux (install.sh, icon and .desktop inside)
    Runs on Windows and Linux (pwsh 7); builds for both OSes from either.
.EXAMPLE
    pwsh Packaging/publish.ps1
    pwsh Packaging/publish.ps1 -Runtime linux-x64
#>
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64', 'linux-x64', 'linux-arm64')]
    [string[]]$Runtime = @('win-x64', 'linux-x64'),
    [string]$Output = (Join-Path $PSScriptRoot '..' 'artifacts')
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$project = Join-Path $root 'SysInfo.csproj'
$version = ([xml](Get-Content $project -Raw)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { $version = '0.0.0' }
$null = New-Item -ItemType Directory -Force $Output
$Output = Resolve-Path $Output

foreach ($rid in $Runtime) {
    $windows = $rid -like 'win-*'
    $name = "SysInfo-$version-$rid"
    $dir = Join-Path $Output $name
    Write-Host "== $name"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }

    dotnet publish $project -c Release -r $rid --self-contained -p:DebugType=None -p:DebugSymbols=false -o $dir --nologo -v quiet
    if ($LASTEXITCODE) { throw "dotnet publish $rid : code $LASTEXITCODE" }

    # PowerShell's built-in modules ship for both OSes; keep those of the target only.
    $other = Join-Path $dir 'runtimes' ($windows ? 'unix' : 'win')
    if (Test-Path $other) { Remove-Item $other -Recurse -Force }
    # Debug symbols of the native libraries (libSkiaSharp.pdb alone: 81 MiB), not removed by DebugType=None.
    Get-ChildItem $dir -Filter *.pdb -Recurse | Remove-Item -Force

    if ($windows) {
        Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $dir
        $archive = "$dir.zip"
        if (Test-Path $archive) { Remove-Item $archive -Force }
        Compress-Archive -Path $dir -DestinationPath $archive -CompressionLevel Optimal
    }
    else {
        Copy-Item (Join-Path $PSScriptRoot 'install.sh'), (Join-Path $PSScriptRoot 'sysinfo.png'), (Join-Path $PSScriptRoot 'sysinfo.desktop') $dir
        if (-not $IsWindows) { chmod +x (Join-Path $dir 'SysInfo') (Join-Path $dir 'install.sh') }
        $archive = "$dir.tar.gz"
        # tar keeps the executable bits (Windows 10+ has tar too, but the bits are then lost: build Linux archives on Linux).
        tar -czf $archive -C $Output $name
        if ($LASTEXITCODE) { throw "tar $rid : code $LASTEXITCODE" }
    }

    $size = (Get-ChildItem $dir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
    Write-Host ("   {0:N0} Mio installés, archive {1:N0} Mio : {2}" -f $size, ((Get-Item $archive).Length / 1MB), $archive)
}
