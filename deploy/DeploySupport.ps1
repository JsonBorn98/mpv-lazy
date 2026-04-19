Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [string]$BasePath = (Get-Location).Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path $BasePath -ChildPath $Path))
}

function Get-NormalizedRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path -replace '\\', '/'
    $normalized = $normalized.TrimStart('./')
    return $normalized.TrimStart('/')
}

function Convert-ToPlatformPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return ($Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
}

function Join-NormalizedPath {
    param(
        [string]$Left,
        [string]$Right
    )

    $leftValue = Get-NormalizedRelativePath -Path ($Left | ForEach-Object { $_ })
    $rightValue = Get-NormalizedRelativePath -Path ($Right | ForEach-Object { $_ })

    if ([string]::IsNullOrWhiteSpace($leftValue)) {
        return $rightValue
    }

    if ([string]::IsNullOrWhiteSpace($rightValue)) {
        return $leftValue
    }

    return '{0}/{1}' -f $leftValue.TrimEnd('/'), $rightValue.TrimStart('/')
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullBase = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $baseUri = New-Object System.Uri($fullBase)
    $pathUri = New-Object System.Uri($fullPath)
    $relativeUri = $baseUri.MakeRelativeUri($pathUri).ToString()
    return [System.Uri]::UnescapeDataString($relativeUri).Replace('/', '\')
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $fullParent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    $fullChild = [System.IO.Path]::GetFullPath($ChildPath).TrimEnd('\')

    if ($fullParent.Length -eq 0 -or $fullChild.Length -eq 0) {
        return $false
    }

    if ($fullParent.Equals($fullChild, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $fullParent + '\'
    return $fullChild.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Convert-GlobToRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $normalized = Get-NormalizedRelativePath -Path $Pattern
    $escaped = [Regex]::Escape($normalized)
    $escaped = $escaped -replace '\\\*\\\*', '__DOUBLE_STAR__'
    $escaped = $escaped -replace '\\\*', '[^/]*'
    $escaped = $escaped -replace '\\\?', '[^/]'
    $escaped = $escaped -replace '__DOUBLE_STAR__', '.*'
    return '^{0}$' -f $escaped
}

function Test-PathMatchesPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Pattern
    )

    $normalizedPath = Get-NormalizedRelativePath -Path $Path
    $regex = Convert-GlobToRegex -Pattern $Pattern
    return $normalizedPath -match $regex
}

function Test-PathMatchesAnyPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [object[]]$Patterns
    )

    if (-not $Patterns) {
        return $false
    }

    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace([string]$pattern)) {
            continue
        }

        if (Test-PathMatchesPattern -Path $Path -Pattern ([string]$pattern)) {
            return $true
        }
    }

    return $false
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "JSON file is empty: $Path"
    }

    return $content | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Data
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth 32
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json + "`n", $encoding)
}

function Get-Manifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    $manifest = Read-JsonFile -Path $ManifestPath
    Assert-ManifestValid -Manifest $manifest -ManifestPath $ManifestPath
    return $manifest
}

function Assert-ManifestValid {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    if (-not $Manifest) {
        throw "Manifest is null: $ManifestPath"
    }

    foreach ($property in @('schemaVersion', 'defaultPackage', 'packages', 'sourceLayers', 'cacheRules', 'backupPolicy')) {
        if (-not ($Manifest.PSObject.Properties.Name -contains $property)) {
            throw "Manifest is missing required field '$property': $ManifestPath"
        }
    }

    if (-not $Manifest.packages -or $Manifest.packages.Count -lt 1) {
        throw "Manifest must define at least one package: $ManifestPath"
    }

    if (-not $Manifest.sourceLayers -or $Manifest.sourceLayers.Count -lt 1) {
        throw "Manifest must define at least one source layer: $ManifestPath"
    }

    if (-not $Manifest.backupPolicy.retain -or [int]$Manifest.backupPolicy.retain -lt 1) {
        throw "Manifest backupPolicy.retain must be a positive integer: $ManifestPath"
    }

    $packageIds = @{}
    foreach ($package in $Manifest.packages) {
        foreach ($field in @('id', 'repo', 'tag', 'variant', 'assetName', 'downloadUrl', 'sha256', 'archiveType', 'extractorHint', 'notes')) {
            if (-not ($package.PSObject.Properties.Name -contains $field)) {
                throw "Package entry is missing required field '$field' in manifest: $ManifestPath"
            }
        }

        if ($packageIds.ContainsKey($package.id)) {
            throw "Manifest contains duplicate package id '$($package.id)': $ManifestPath"
        }

        $packageIds[$package.id] = $true

        $supportedArchiveTypes = @('zip', '7z', 'manual')
        if ($supportedArchiveTypes -notcontains [string]$package.archiveType) {
            throw "Unsupported package archiveType '$($package.archiveType)' for '$($package.id)' in manifest: $ManifestPath"
        }

        if ([string]::IsNullOrWhiteSpace([string]$package.id)) {
            throw "Manifest package id cannot be empty: $ManifestPath"
        }
    }

    if (-not $packageIds.ContainsKey([string]$Manifest.defaultPackage)) {
        throw "Manifest defaultPackage '$($Manifest.defaultPackage)' is not defined in packages[]: $ManifestPath"
    }

    foreach ($layer in $Manifest.sourceLayers) {
        foreach ($field in @('id', 'source', 'target', 'exclude')) {
            if (-not ($layer.PSObject.Properties.Name -contains $field)) {
                throw "Source layer entry is missing required field '$field' in manifest: $ManifestPath"
            }
        }
    }
}

function Get-ManifestPackage {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    foreach ($package in $Manifest.packages) {
        if ([string]$package.id -eq $PackageId) {
            return $package
        }
    }

    throw "Package '$PackageId' was not found in manifest."
}

function Get-SourceLayerEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Layer
    )

    $layerSourceRoot = Resolve-AbsolutePath -Path ([string]$Layer.source) -BasePath $SourceRoot
    if (-not (Test-Path -LiteralPath $layerSourceRoot -PathType Container)) {
        throw "Source layer path not found: $layerSourceRoot"
    }

    $entries = @()
    foreach ($file in Get-ChildItem -LiteralPath $layerSourceRoot -Recurse -File -Force) {
        $relativeToLayer = Get-NormalizedRelativePath -Path (Get-RelativePath -BasePath $layerSourceRoot -Path $file.FullName)
        if (Test-PathMatchesAnyPattern -Path $relativeToLayer -Patterns $Layer.exclude) {
            continue
        }

        $entries += [PSCustomObject]@{
            SourcePath         = $file.FullName
            LayerRelativePath  = $relativeToLayer
            TargetRelativePath = Join-NormalizedPath -Left ([string]$Layer.target) -Right $relativeToLayer
        }
    }

    return $entries
}

function New-TempDirectory {
    param(
        [string]$Prefix = 'mpv-lazy'
    )

    $directory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('{0}-{1}' -f $Prefix, [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return $directory
}

function New-UniquePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PreferredPath
    )

    $candidate = [System.IO.Path]::GetFullPath($PreferredPath)
    $index = 0
    while (Test-Path -LiteralPath $candidate) {
        $index += 1
        $candidate = '{0}-{1}' -f $PreferredPath, $index
    }

    return $candidate
}

function Remove-PathIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Copy-DirectoryContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source directory not found: $Source"
    }

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Resolve-ArchiveType {
    param(
        [string]$ArchivePath,
        [string]$DeclaredType
    )

    if (-not [string]::IsNullOrWhiteSpace($DeclaredType) -and $DeclaredType -ne 'manual') {
        return $DeclaredType
    }

    $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()
    switch ($extension) {
        '.zip' { return 'zip' }
        '.7z' { return '7z' }
        default { throw "Unsupported archive extension '$extension'. Pass a .zip/.7z file or use -BaseDirectory." }
    }
}

function Expand-ArchiveWithFallbacks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [string]$ArchiveType,
        [string]$ExtractorHint
    )

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Archive not found: $ArchivePath"
    }

    Remove-PathIfExists -Path $Destination
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $resolvedType = Resolve-ArchiveType -ArchivePath $ArchivePath -DeclaredType $ArchiveType
    $attempted = @()

    $tarCommand = Get-Command -Name 'tar.exe' -ErrorAction SilentlyContinue
    if ($tarCommand) {
        try {
            & $tarCommand.Source -xf $ArchivePath -C $Destination
            if ($LASTEXITCODE -eq 0) {
                return
            }

            $attempted += 'tar.exe'
        }
        catch {
            $attempted += 'tar.exe'
        }
    }

    if ($resolvedType -eq 'zip') {
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force
            return
        }
        catch {
            $attempted += 'Expand-Archive'
        }
    }

    $sevenZipCommand = Get-Command -Name '7z.exe' -ErrorAction SilentlyContinue
    if ($resolvedType -eq '7z' -and $sevenZipCommand) {
        & $sevenZipCommand.Source x "-o$Destination" '-y' $ArchivePath | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        $attempted += '7z.exe'
    }

    $details = if ($attempted.Count -gt 0) { $attempted -join ', ' } else { 'no extractor was available' }
    $hint = if ([string]::IsNullOrWhiteSpace($ExtractorHint)) {
        'Use -BaseDirectory to point at an already extracted base package.'
    }
    else {
        $ExtractorHint
    }

    throw "Failed to extract archive '$ArchivePath'. Attempted: $details. $hint"
}

function Resolve-ExtractedBaseRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidateRoot
    )

    $fullCandidate = Resolve-AbsolutePath -Path $CandidateRoot
    if (-not (Test-Path -LiteralPath $fullCandidate -PathType Container)) {
        throw "Base directory not found: $fullCandidate"
    }

    $expectedExecutables = @('mpv.exe', 'mpv.com')
    foreach ($executable in $expectedExecutables) {
        if (Test-Path -LiteralPath (Join-Path -Path $fullCandidate -ChildPath $executable) -PathType Leaf) {
            return $fullCandidate
        }
    }

    $children = Get-ChildItem -LiteralPath $fullCandidate -Force
    $childDirectories = @($children | Where-Object { $_.PSIsContainer })
    $childFiles = @($children | Where-Object { -not $_.PSIsContainer })
    if ($childDirectories.Count -eq 1 -and $childFiles.Count -eq 0) {
        $nestedCandidate = $childDirectories[0].FullName
        foreach ($executable in $expectedExecutables) {
            if (Test-Path -LiteralPath (Join-Path -Path $nestedCandidate -ChildPath $executable) -PathType Leaf) {
                return $nestedCandidate
            }
        }
    }

    throw "Unable to locate an mpv base root under '$fullCandidate'. Pass -BaseDirectory with the extracted mpv root."
}

function Resolve-OverlayRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidateRoot
    )

    $fullCandidate = Resolve-AbsolutePath -Path $CandidateRoot
    if (-not (Test-Path -LiteralPath $fullCandidate -PathType Container)) {
        throw "Overlay directory not found: $fullCandidate"
    }

    $children = Get-ChildItem -LiteralPath $fullCandidate -Force
    $childDirectories = @($children | Where-Object { $_.PSIsContainer })
    $childFiles = @($children | Where-Object { -not $_.PSIsContainer })
    if ($childDirectories.Count -eq 1 -and $childFiles.Count -eq 0) {
        return $childDirectories[0].FullName
    }

    return $fullCandidate
}

function Get-BackupRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

    return ('{0}._backups' -f (Resolve-AbsolutePath -Path $TargetDir))
}

function Get-BackupDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

    $backupRoot = Get-BackupRoot -TargetDir $TargetDir
    if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $backupRoot -Directory | Sort-Object Name -Descending)
}

function Prune-Backups {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [Parameter(Mandatory = $true)]
        [int]$Retain
    )

    $backups = @(Get-BackupDirectories -TargetDir $TargetDir)
    if ($backups.Count -le $Retain) {
        return
    }

    $toRemove = $backups | Select-Object -Skip $Retain
    foreach ($backup in $toRemove) {
        Remove-PathIfExists -Path $backup.FullName
    }
}

function Read-DeployStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir
    )

    $statePath = Join-Path -Path (Resolve-AbsolutePath -Path $TargetDir) -ChildPath '.deploy-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    return Read-JsonFile -Path $statePath
}

function Write-DeployStateFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$State
    )

    $statePath = Join-Path -Path $TargetDir -ChildPath '.deploy-state.json'
    Write-JsonFile -Path $statePath -Data $State
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Remove-CacheFromTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDir,
        [AllowNull()]
        [object[]]$CacheRules
    )

    $fullTarget = Resolve-AbsolutePath -Path $TargetDir
    if (-not (Test-Path -LiteralPath $fullTarget -PathType Container)) {
        throw "Target directory not found: $fullTarget"
    }

    $removed = @()
    foreach ($rule in $CacheRules) {
        $normalizedRule = Get-NormalizedRelativePath -Path ([string]$rule)
        if ([string]::IsNullOrWhiteSpace($normalizedRule)) {
            continue
        }

        if ($normalizedRule -eq 'portable_config/_cache' -or $normalizedRule -eq 'portable_config/_cache/**') {
            $cacheDir = Join-Path -Path $fullTarget -ChildPath 'portable_config\_cache'
            if (Test-Path -LiteralPath $cacheDir) {
                Remove-PathIfExists -Path $cacheDir
                $removed += 'portable_config/_cache'
            }

            continue
        }

        if ($normalizedRule -eq 'portable_config/saved-props.json') {
            $savedProps = Join-Path -Path $fullTarget -ChildPath 'portable_config\saved-props.json'
            if (Test-Path -LiteralPath $savedProps) {
                Remove-PathIfExists -Path $savedProps
                $removed += 'portable_config/saved-props.json'
            }

            continue
        }

        if ($normalizedRule -like 'vs-plugins/models/*') {
            $modelsRoot = Join-Path -Path $fullTarget -ChildPath 'vs-plugins\models'
            if (-not (Test-Path -LiteralPath $modelsRoot -PathType Container)) {
                continue
            }

            foreach ($file in Get-ChildItem -LiteralPath $modelsRoot -Recurse -File -Force) {
                $relative = Join-NormalizedPath -Left 'vs-plugins/models' -Right (Get-NormalizedRelativePath -Path (Get-RelativePath -BasePath $modelsRoot -Path $file.FullName))
                if (Test-PathMatchesPattern -Path $relative -Pattern $normalizedRule) {
                    Remove-PathIfExists -Path $file.FullName
                    $removed += $relative
                }
            }
        }
    }

    return $removed
}
