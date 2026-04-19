[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Update', 'ClearCache', 'Rollback', 'Status')]
    [string]$Action,
    [Parameter(Mandatory = $true)]
    [string]$TargetDir,
    [string]$ManifestPath = (Join-Path -Path $PSScriptRoot -ChildPath 'deploy\manifest.json'),
    [string]$StagingDir,
    [string]$BackupId,
    [string]$SourceRoot = $PSScriptRoot,
    [string[]]$OverlayDirectories,
    [string]$ResolvedPackageId,
    [string]$ResolvedPackageRepo,
    [string]$ResolvedPackageTag,
    [string]$ResolvedPackageVariant,
    [string]$ResolvedSourceType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'deploy\DeploySupport.ps1')

function Assert-TargetDirIsSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    if (Test-PathWithin -ParentPath $RepoRoot -ChildPath $TargetPath) {
        throw "Target directory '$TargetPath' cannot be the repository root or a path inside it."
    }
}

function New-UniqueSiblingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $resolvedBase = Resolve-AbsolutePath -Path $BasePath
    $candidate = '{0}.{1}' -f $resolvedBase, $Label
    $index = 0
    while (Test-Path -LiteralPath $candidate) {
        $index += 1
        $candidate = '{0}.{1}-{2}' -f $resolvedBase, $Label, $index
    }

    return $candidate
}

function Get-ResolvedPackageInfo {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [AllowNull()]
        [object]$ExistingState,
        [string]$PackageId,
        [string]$PackageRepo,
        [string]$PackageTag,
        [string]$PackageVariant,
        [string]$SourceType
    )

    $effectivePackageId = if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
        $PackageId
    }
    elseif ($ExistingState -and $ExistingState.package -and -not [string]::IsNullOrWhiteSpace([string]$ExistingState.package.id)) {
        [string]$ExistingState.package.id
    }
    else {
        [string]$Manifest.defaultPackage
    }

    $manifestPackage = Get-ManifestPackage -Manifest $Manifest -PackageId $effectivePackageId

    return [PSCustomObject]@{
        id         = $effectivePackageId
        repo       = if (-not [string]::IsNullOrWhiteSpace($PackageRepo)) { $PackageRepo } elseif ($ExistingState -and $ExistingState.package) { [string]$ExistingState.package.repo } else { [string]$manifestPackage.repo }
        tag        = if (-not [string]::IsNullOrWhiteSpace($PackageTag)) { $PackageTag } elseif ($ExistingState -and $ExistingState.package) { [string]$ExistingState.package.tag } else { [string]$manifestPackage.tag }
        variant    = if (-not [string]::IsNullOrWhiteSpace($PackageVariant)) { $PackageVariant } elseif ($ExistingState -and $ExistingState.package) { [string]$ExistingState.package.variant } else { [string]$manifestPackage.variant }
        sourceType = if (-not [string]::IsNullOrWhiteSpace($SourceType)) { $SourceType } elseif ($ExistingState -and $ExistingState.package) { [string]$ExistingState.package.sourceType } else { 'manifest-default' }
    }
}

function Sync-LayerIntoIncomingRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$IncomingRoot,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Layer,
        [AllowNull()]
        [object[]]$CacheRules
    )

    $entries = @(Get-SourceLayerEntries -SourceRoot $SourceRoot -Layer $Layer)
    $desiredFiles = @{}
    foreach ($entry in $entries) {
        $desiredFiles[[string]$entry.TargetRelativePath] = $true
    }

    $layerTargetRoot = Join-Path -Path $IncomingRoot -ChildPath (Convert-ToPlatformPath -Path ([string]$Layer.target))
    New-Item -ItemType Directory -Path $layerTargetRoot -Force | Out-Null

    $existingFiles = @(Get-ChildItem -LiteralPath $layerTargetRoot -Recurse -File -Force)
    foreach ($existingFile in $existingFiles) {
        $layerRelativePath = Get-NormalizedRelativePath -Path (Get-RelativePath -BasePath $layerTargetRoot -Path $existingFile.FullName)
        $targetRelativePath = Join-NormalizedPath -Left ([string]$Layer.target) -Right $layerRelativePath
        if ($desiredFiles.ContainsKey($targetRelativePath)) {
            continue
        }

        if (Test-PathMatchesAnyPattern -Path $targetRelativePath -Patterns $CacheRules) {
            continue
        }

        Remove-PathIfExists -Path $existingFile.FullName
    }

    foreach ($entry in $entries) {
        $destinationPath = Join-Path -Path $IncomingRoot -ChildPath (Convert-ToPlatformPath -Path ([string]$entry.TargetRelativePath))
        $destinationDir = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        }

        Copy-Item -LiteralPath $entry.SourcePath -Destination $destinationPath -Force
    }

    return $entries
}

function Get-StatusObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest
    )

    $fullTarget = Resolve-AbsolutePath -Path $TargetPath
    $state = if (Test-Path -LiteralPath $fullTarget -PathType Container) { Read-DeployStateFile -TargetDir $fullTarget } else { $null }
    $backups = @(Get-BackupDirectories -TargetDir $fullTarget)

    return [PSCustomObject]@{
        TargetDir       = $fullTarget
        Exists          = (Test-Path -LiteralPath $fullTarget -PathType Container)
        PackageId       = if ($state -and $state.package) { [string]$state.package.id } else { $null }
        PackageTag      = if ($state -and $state.package) { [string]$state.package.tag } else { $null }
        PackageVariant  = if ($state -and $state.package) { [string]$state.package.variant } else { $null }
        PackageSource   = if ($state -and $state.package) { [string]$state.package.sourceType } else { $null }
        LastDeployedAt  = if ($state) { [string]$state.deployedAt } else { $null }
        BackupRoot      = Get-BackupRoot -TargetDir $fullTarget
        Backups         = @($backups | ForEach-Object { $_.Name })
        CacheRules      = @($Manifest.cacheRules | ForEach-Object { [string]$_ })
        ManagedFileCount = if ($state -and $state.managedFiles) { @($state.managedFiles).Count } else { 0 }
    }
}

function Invoke-InstallOrUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,
        [Parameter(Mandatory = $true)]
        [string]$ConfigSourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [string]$ManifestFilePath,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [string]$BaseSourcePath,
        [string[]]$OverlayRoots
    )

    $fullTarget = Resolve-AbsolutePath -Path $TargetPath
    $targetParent = Split-Path -Parent $fullTarget
    if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
    }

    $existingState = if (Test-Path -LiteralPath $fullTarget -PathType Container) { Read-DeployStateFile -TargetDir $fullTarget } else { $null }
    if ($Mode -eq 'Update' -and -not (Test-Path -LiteralPath $fullTarget -PathType Container)) {
        throw "Target directory does not exist. Run Install first or use bootstrap.ps1."
    }

    $resolvedPackageInfo = Get-ResolvedPackageInfo -Manifest $Manifest -ExistingState $existingState -PackageId $ResolvedPackageId -PackageRepo $ResolvedPackageRepo -PackageTag $ResolvedPackageTag -PackageVariant $ResolvedPackageVariant -SourceType $ResolvedSourceType
    $incomingLabel = 'incoming-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
    $incomingRoot = New-UniqueSiblingPath -BasePath $fullTarget -Label $incomingLabel

    $sourceForIncoming = if ($Mode -eq 'Install') {
        if ([string]::IsNullOrWhiteSpace($BaseSourcePath)) {
            throw "Install requires -StagingDir pointing to an extracted base package root."
        }

        Resolve-ExtractedBaseRoot -CandidateRoot $BaseSourcePath
    }
    else {
        $fullTarget
    }

    $managedFiles = @()
    $backupRoot = Get-BackupRoot -TargetDir $fullTarget
    $newBackupId = Get-Date -Format 'yyyyMMdd-HHmmss'

    if ($PSCmdlet.ShouldProcess($fullTarget, '{0} deployment' -f $Mode)) {
        try {
            Remove-PathIfExists -Path $incomingRoot
            Copy-DirectoryContent -Source $sourceForIncoming -Destination $incomingRoot

            foreach ($overlayRoot in @($OverlayRoots)) {
                if ([string]::IsNullOrWhiteSpace($overlayRoot)) {
                    continue
                }

                $resolvedOverlayRoot = Resolve-AbsolutePath -Path $overlayRoot
                if (-not (Test-Path -LiteralPath $resolvedOverlayRoot -PathType Container)) {
                    throw "Overlay directory not found: $resolvedOverlayRoot"
                }

                Copy-DirectoryContent -Source $resolvedOverlayRoot -Destination $incomingRoot
            }

            foreach ($layer in $Manifest.sourceLayers) {
                $layerEntries = @(Sync-LayerIntoIncomingRoot -SourceRoot $ConfigSourceRoot -IncomingRoot $incomingRoot -Layer $layer -CacheRules $Manifest.cacheRules)
                $managedFiles += @($layerEntries | ForEach-Object { [string]$_.TargetRelativePath })
            }

            $deployState = [ordered]@{
                schemaVersion = 1
                deployedAt    = (Get-Date).ToString('s')
                manifest      = [ordered]@{
                    path          = $ManifestFilePath
                    schemaVersion = [int]$Manifest.schemaVersion
                }
                package       = [ordered]@{
                    id         = [string]$resolvedPackageInfo.id
                    repo       = [string]$resolvedPackageInfo.repo
                    tag        = [string]$resolvedPackageInfo.tag
                    variant    = [string]$resolvedPackageInfo.variant
                    sourceType = [string]$resolvedPackageInfo.sourceType
                }
                managedFiles  = @($managedFiles | Sort-Object -Unique)
                cacheRules    = @($Manifest.cacheRules | ForEach-Object { [string]$_ })
            }

            Write-DeployStateFile -TargetDir $incomingRoot -State $deployState

            if (Test-Path -LiteralPath $fullTarget -PathType Container) {
                New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
                $backupPath = Join-Path -Path $backupRoot -ChildPath $newBackupId
                $backupPath = New-UniquePath -PreferredPath $backupPath
                Move-Item -LiteralPath $fullTarget -Destination $backupPath
            }

            Move-Item -LiteralPath $incomingRoot -Destination $fullTarget
            Prune-Backups -TargetDir $fullTarget -Retain ([int]$Manifest.backupPolicy.retain)
            return Get-StatusObject -TargetPath $fullTarget -Manifest $Manifest
        }
        finally {
            if (Test-Path -LiteralPath $incomingRoot) {
                Remove-PathIfExists -Path $incomingRoot
            }
        }
    }
}

function Invoke-Rollback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [string]$RequestedBackupId
    )

    $fullTarget = Resolve-AbsolutePath -Path $TargetPath
    $backupRoot = Get-BackupRoot -TargetDir $fullTarget
    $backups = @(Get-BackupDirectories -TargetDir $fullTarget)
    if ($backups.Count -eq 0) {
        throw "No backups were found for target '$fullTarget'."
    }

    $selectedBackup = if (-not [string]::IsNullOrWhiteSpace($RequestedBackupId)) {
        $candidate = Join-Path -Path $backupRoot -ChildPath $RequestedBackupId
        if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
            throw "Backup '$RequestedBackupId' was not found under '$backupRoot'."
        }

        Get-Item -LiteralPath $candidate
    }
    else {
        $backups[0]
    }

    if ($PSCmdlet.ShouldProcess($fullTarget, "Rollback to backup '$($selectedBackup.Name)'")) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        if (Test-Path -LiteralPath $fullTarget -PathType Container) {
            $currentBackupPath = Join-Path -Path $backupRoot -ChildPath (Get-Date -Format 'yyyyMMdd-HHmmss')
            $currentBackupPath = New-UniquePath -PreferredPath $currentBackupPath
            Move-Item -LiteralPath $fullTarget -Destination $currentBackupPath
        }

        Move-Item -LiteralPath $selectedBackup.FullName -Destination $fullTarget
        Prune-Backups -TargetDir $fullTarget -Retain ([int]$Manifest.backupPolicy.retain)
        return Get-StatusObject -TargetPath $fullTarget -Manifest $Manifest
    }
}

$repoRoot = Resolve-AbsolutePath -Path $PSScriptRoot
$configSourceRoot = Resolve-AbsolutePath -Path $SourceRoot -BasePath (Get-Location).Path
$manifestFullPath = Resolve-AbsolutePath -Path $ManifestPath -BasePath $configSourceRoot
$manifest = Get-Manifest -ManifestPath $manifestFullPath
$targetFullPath = Resolve-AbsolutePath -Path $TargetDir

Assert-TargetDirIsSafe -RepoRoot $repoRoot -TargetPath $targetFullPath
if (-not $configSourceRoot.Equals($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    Assert-TargetDirIsSafe -RepoRoot $configSourceRoot -TargetPath $targetFullPath
}

switch ($Action) {
    'Install' {
        Invoke-InstallOrUpdate -Mode 'Install' -ConfigSourceRoot $configSourceRoot -TargetPath $targetFullPath -ManifestFilePath $manifestFullPath -Manifest $manifest -BaseSourcePath $StagingDir -OverlayRoots $OverlayDirectories
    }
    'Update' {
        Invoke-InstallOrUpdate -Mode 'Update' -ConfigSourceRoot $configSourceRoot -TargetPath $targetFullPath -ManifestFilePath $manifestFullPath -Manifest $manifest -OverlayRoots $OverlayDirectories
    }
    'ClearCache' {
        if ($PSCmdlet.ShouldProcess($targetFullPath, 'Clear runtime cache')) {
            $removed = @(Remove-CacheFromTarget -TargetDir $targetFullPath -CacheRules $manifest.cacheRules | Sort-Object -Unique)
            [PSCustomObject]@{
                TargetDir    = $targetFullPath
                RemovedCount = $removed.Count
                Removed      = $removed
            }
        }
    }
    'Rollback' {
        Invoke-Rollback -TargetPath $targetFullPath -Manifest $manifest -RequestedBackupId $BackupId
    }
    'Status' {
        Get-StatusObject -TargetPath $targetFullPath -Manifest $manifest
    }
}
