function Get-CpuName {
    if ($IsWindows) {
        # Windows : CIM Win32_Processor
        return (Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1).Name.Trim()
    }
    if ($IsLinux) {
        # Linux : /proc/cpuinfo ("model name" absent sur certains ARM)
        $line = Get-Content -Path /proc/cpuinfo | Where-Object { $_ -cmatch '^(model name|Model|Hardware)\s*:' } | Select-Object -First 1
        if ($line) { return ($line -replace '^[^:]*:\s*', '').Trim() }
    }
    throw 'Processeur introuvable'
}

function Get-ModuleData {
    $items = [ordered]@{}
    $sections = @()

    try {
        $items['Processeur'] = Get-CpuName
    }
    catch {
        $sections += [PSCustomObject]@{
            Title = 'Erreur'
            Type  = 'KeyValue'
            Items = [ordered]@{ Processeur = $_.Exception.Message }
        }
    }

    [PSCustomObject]@{
        Sections = @(
            [PSCustomObject]@{
                Title = 'Général'
                Type  = 'KeyValue'
                Items = $items
            }
        ) + $sections
    }
}

Export-ModuleMember -Function Get-ModuleData
