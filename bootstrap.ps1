[CmdletBinding()]
param(
    [string]$TargetDir,
    [string]$ScoopApp,
    [string]$ManifestPath = 'deploy/manifest.json',
    [string]$ConfigRepoUrl,
    [string]$ConfigRef = 'main',
    [string]$ConfigCheckoutDir,
    [string]$PackageId,
    [string]$BaseArchive,
    [string]$BaseDirectory,
    [string]$BaseUrl,
    [string]$DownloadCacheDir,
    [string[]]$AddonIds,
    [string[]]$AddonArchive,
    [string[]]$AddonDirectory,
    [string[]]$AddonUrl,
    [switch]$Force,
    [switch]$NoChecksum
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'deploy\DeploySupport.ps1')

function Get-DefaultCachePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LeafName
    )

    $base = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $env:LOCALAPPDATA
    }
    else {
        [System.IO.Path]::GetTempPath()
    }

    return Join-Path -Path $base -ChildPath ("mpv-lazy-bootstrap\{0}" -f $LeafName)
}

function Resolve-TargetRuntimeRoot {
    param(
        [string]$ExplicitTargetDir,
        [string]$ResolvedScoopApp
    )

    if (-not [string]::IsNullOrWhiteSpace($ResolvedScoopApp)) {
        $scoopCommand = Get-Command -Name 'scoop' -ErrorAction SilentlyContinue
        if (-not $scoopCommand) {
            throw "Scoop was not found in PATH. Install Scoop first or pass -TargetDir explicitly."
        }

        $prefix = & $scoopCommand.Source prefix $ResolvedScoopApp 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($prefix)) {
            throw "Unable to resolve Scoop app '$ResolvedScoopApp'. Install it first or pass -TargetDir explicitly."
        }

        return Resolve-AbsolutePath -Path ([string]$prefix)
    }

    if ([string]::IsNullOrWhiteSpace($ExplicitTargetDir)) {
        throw "Specify either -TargetDir or -ScoopApp."
    }

    return Resolve-AbsolutePath -Path $ExplicitTargetDir
}

function Sync-ConfigRepoCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRef,
        [Parameter(Mandatory = $true)]
        [string]$CheckoutDir,
        [switch]$ResetCheckout
    )

    $gitCommand = Get-Command -Name 'git' -ErrorAction SilentlyContinue
    if (-not $gitCommand) {
        throw "Git is required to pull a remote config repository."
    }

    $resolvedCheckoutDir = Resolve-AbsolutePath -Path $CheckoutDir
    $checkoutParent = Split-Path -Parent $resolvedCheckoutDir
    if (-not (Test-Path -LiteralPath $checkoutParent -PathType Container)) {
        New-Item -ItemType Directory -Path $checkoutParent -Force | Out-Null
    }

    if ($ResetCheckout -and (Test-Path -LiteralPath $resolvedCheckoutDir)) {
        Remove-PathIfExists -Path $resolvedCheckoutDir
    }

    if (-not (Test-Path -LiteralPath $resolvedCheckoutDir -PathType Container)) {
        & $gitCommand.Source clone --depth 1 --branch $RepositoryRef $RepositoryUrl $resolvedCheckoutDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clone config repository '$RepositoryUrl'."
        }

        return $resolvedCheckoutDir
    }

    $gitDir = Join-Path -Path $resolvedCheckoutDir -ChildPath '.git'
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) {
        throw "Config checkout directory exists but is not a git repository: $resolvedCheckoutDir"
    }

    & $gitCommand.Source -C $resolvedCheckoutDir fetch --depth 1 origin $RepositoryRef | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch '$RepositoryRef' from '$RepositoryUrl'."
    }

    & $gitCommand.Source -C $resolvedCheckoutDir checkout --force FETCH_HEAD | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check out the fetched config repository state."
    }

    return $resolvedCheckoutDir
}

function Resolve-ConfigSourceRoot {
    param(
        [string]$RepositoryUrl,
        [string]$RepositoryRef,
        [string]$CheckoutDir,
        [Parameter(Mandatory = $true)]
        [string]$FallbackRoot,
        [switch]$ResetCheckout
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        return Resolve-AbsolutePath -Path $FallbackRoot
    }

    $effectiveCheckoutDir = if ([string]::IsNullOrWhiteSpace($CheckoutDir)) {
        Get-DefaultCachePath -LeafName 'config-repo'
    }
    else {
        $CheckoutDir
    }

    return Sync-ConfigRepoCheckout -RepositoryUrl $RepositoryUrl -RepositoryRef $RepositoryRef -CheckoutDir $effectiveCheckoutDir -ResetCheckout:$ResetCheckout
}

function Download-RemoteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,
        [string]$PreferredFileName
    )

    $resolvedDestinationDirectory = Resolve-AbsolutePath -Path $DestinationDirectory
    if (-not (Test-Path -LiteralPath $resolvedDestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedDestinationDirectory -Force | Out-Null
    }

    $fileName = if (-not [string]::IsNullOrWhiteSpace($PreferredFileName)) {
        $PreferredFileName
    }
    else {
        try {
            [System.IO.Path]::GetFileName(([System.Uri]$Url).AbsolutePath)
        }
        catch {
            ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($fileName)) {
        $fileName = 'download-{0}.bin' -f [Guid]::NewGuid().ToString('N')
    }

    $destinationPath = Join-Path -Path $resolvedDestinationDirectory -ChildPath $fileName
    Invoke-WebRequest -Uri $Url -OutFile $destinationPath -MaximumRedirection 10
    return $destinationPath
}

function Get-ManifestAddon {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [Parameter(Mandatory = $true)]
        [string]$AddonId
    )

    if (-not ($Manifest.PSObject.Properties.Name -contains 'addons')) {
        throw "Manifest does not define addons, so addon '$AddonId' cannot be resolved."
    }

    foreach ($addon in @($Manifest.addons)) {
        if ([string]$addon.id -eq $AddonId) {
            return $addon
        }
    }

    throw "Addon '$AddonId' was not found in manifest."
}

function Assert-ChecksumIfAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [string]$ExpectedSha256,
        [switch]$SkipChecksum
    )

    if ($SkipChecksum) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        Write-Warning "No SHA256 was configured for '$ArchivePath'; checksum verification was skipped."
        return
    }

    $normalizedExpectedSha = $ExpectedSha256.ToLowerInvariant()
    $actualSha = Get-FileSha256 -Path $ArchivePath
    if ($actualSha -ne $normalizedExpectedSha) {
        throw "SHA256 mismatch for '$ArchivePath'. Expected '$normalizedExpectedSha', got '$actualSha'."
    }
}

function Resolve-BasePackageRoot {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [string]$SelectedPackageId,
        [string]$ExplicitBaseArchive,
        [string]$ExplicitBaseDirectory,
        [string]$ExplicitBaseUrl,
        [string]$EffectiveDownloadCacheDir,
        [switch]$SkipChecksum
    )

    $packageId = if (-not [string]::IsNullOrWhiteSpace($SelectedPackageId)) { $SelectedPackageId } else { [string]$Manifest.defaultPackage }
    $package = Get-ManifestPackage -Manifest $Manifest -PackageId $packageId

    if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseDirectory)) {
        return [PSCustomObject]@{
            Package = $package
            Root    = Resolve-ExtractedBaseRoot -CandidateRoot $ExplicitBaseDirectory
            Source  = 'directory'
        }
    }

    $archivePath = $null
    if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseArchive)) {
        $archivePath = Resolve-AbsolutePath -Path $ExplicitBaseArchive
    }
    else {
        $effectiveUrl = if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseUrl)) { $ExplicitBaseUrl } else { [string]$package.downloadUrl }
        if ([string]::IsNullOrWhiteSpace($effectiveUrl) -or [string]$package.archiveType -eq 'manual') {
            $releaseHint = if ($package.PSObject.Properties.Name -contains 'downloadPageUrl') { [string]$package.downloadPageUrl } else { [string]$package.notes }
            throw "The selected base package '$packageId' does not have a direct archive URL configured. Download it manually from '$releaseHint' and rerun with -BaseArchive or -BaseDirectory."
        }

        $preferredName = if (-not [string]::IsNullOrWhiteSpace([string]$package.assetName)) { [string]$package.assetName } else { $null }
        $archivePath = Download-RemoteFile -Url $effectiveUrl -DestinationDirectory $EffectiveDownloadCacheDir -PreferredFileName $preferredName
        Assert-ChecksumIfAvailable -ArchivePath $archivePath -ExpectedSha256 ([string]$package.sha256) -SkipChecksum:$SkipChecksum
    }

    $extractRoot = New-TempDirectory -Prefix 'mpv-lazy-base'
    Expand-ArchiveWithFallbacks -ArchivePath $archivePath -Destination $extractRoot -ArchiveType ([string]$package.archiveType) -ExtractorHint ([string]$package.extractorHint)

    return [PSCustomObject]@{
        Package = $package
        Root    = Resolve-ExtractedBaseRoot -CandidateRoot $extractRoot
        Source  = if (-not [string]::IsNullOrWhiteSpace($ExplicitBaseArchive)) { 'archive' } else { 'download' }
    }
}

function Resolve-AddonOverlayRoots {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,
        [string[]]$SelectedAddonIds,
        [string[]]$ExplicitAddonArchives,
        [string[]]$ExplicitAddonDirectories,
        [string[]]$ExplicitAddonUrls,
        [string]$EffectiveDownloadCacheDir,
        [switch]$SkipChecksum
    )

    $overlayRoots = @()

    foreach ($directory in @($ExplicitAddonDirectories)) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            continue
        }

        $overlayRoots += Resolve-OverlayRoot -CandidateRoot $directory
    }

    foreach ($archive in @($ExplicitAddonArchives)) {
        if ([string]::IsNullOrWhiteSpace($archive)) {
            continue
        }

        $extractRoot = New-TempDirectory -Prefix 'mpv-lazy-addon'
        $resolvedArchive = Resolve-AbsolutePath -Path $archive
        Expand-ArchiveWithFallbacks -ArchivePath $resolvedArchive -Destination $extractRoot -ArchiveType $null -ExtractorHint 'Pass -AddonDirectory if your add-on is already extracted.'
        $overlayRoots += Resolve-OverlayRoot -CandidateRoot $extractRoot
    }

    foreach ($url in @($ExplicitAddonUrls)) {
        if ([string]::IsNullOrWhiteSpace($url)) {
            continue
        }

        $archivePath = Download-RemoteFile -Url $url -DestinationDirectory $EffectiveDownloadCacheDir
        Assert-ChecksumIfAvailable -ArchivePath $archivePath -ExpectedSha256 '' -SkipChecksum:$SkipChecksum

        $extractRoot = New-TempDirectory -Prefix 'mpv-lazy-addon'
        Expand-ArchiveWithFallbacks -ArchivePath $archivePath -Destination $extractRoot -ArchiveType $null -ExtractorHint 'Pass -AddonDirectory if your add-on is already extracted.'
        $overlayRoots += Resolve-OverlayRoot -CandidateRoot $extractRoot
    }

    foreach ($addonId in @($SelectedAddonIds)) {
        if ([string]::IsNullOrWhiteSpace($addonId)) {
            continue
        }

        $addon = Get-ManifestAddon -Manifest $Manifest -AddonId $addonId
        if ([string]$addon.archiveType -eq 'manual' -or [string]::IsNullOrWhiteSpace([string]$addon.downloadUrl)) {
            $hint = if ($addon.PSObject.Properties.Name -contains 'downloadPageUrl') { [string]$addon.downloadPageUrl } else { [string]$addon.notes }
            throw "Addon '$addonId' does not yet have a direct archive URL configured. Download it from '$hint' and rerun with -AddonArchive."
        }

        $preferredName = if (-not [string]::IsNullOrWhiteSpace([string]$addon.assetName)) { [string]$addon.assetName } else { $null }
        $archivePath = Download-RemoteFile -Url ([string]$addon.downloadUrl) -DestinationDirectory $EffectiveDownloadCacheDir -PreferredFileName $preferredName
        Assert-ChecksumIfAvailable -ArchivePath $archivePath -ExpectedSha256 ([string]$addon.sha256) -SkipChecksum:$SkipChecksum

        $extractRoot = New-TempDirectory -Prefix 'mpv-lazy-addon'
        Expand-ArchiveWithFallbacks -ArchivePath $archivePath -Destination $extractRoot -ArchiveType ([string]$addon.archiveType) -ExtractorHint ([string]$addon.extractorHint)
        $overlayRoots += Resolve-OverlayRoot -CandidateRoot $extractRoot
    }

    return @($overlayRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$scriptRepoRoot = Resolve-AbsolutePath -Path $PSScriptRoot
$configSourceRoot = Resolve-ConfigSourceRoot -RepositoryUrl $ConfigRepoUrl -RepositoryRef $ConfigRef -CheckoutDir $ConfigCheckoutDir -FallbackRoot $scriptRepoRoot -ResetCheckout:$Force
$manifestFullPath = Resolve-AbsolutePath -Path $ManifestPath -BasePath $configSourceRoot
$manifest = Get-Manifest -ManifestPath $manifestFullPath
$effectiveDownloadCacheDir = if ([string]::IsNullOrWhiteSpace($DownloadCacheDir)) { Get-DefaultCachePath -LeafName 'downloads' } else { Resolve-AbsolutePath -Path $DownloadCacheDir }
$targetRuntimeRoot = Resolve-TargetRuntimeRoot -ExplicitTargetDir $TargetDir -ResolvedScoopApp $ScoopApp
$overlayRoots = Resolve-AddonOverlayRoots -Manifest $manifest -SelectedAddonIds $AddonIds -ExplicitAddonArchives $AddonArchive -ExplicitAddonDirectories $AddonDirectory -ExplicitAddonUrls $AddonUrl -EffectiveDownloadCacheDir $effectiveDownloadCacheDir -SkipChecksum:$NoChecksum

$deployScript = Join-Path -Path $scriptRepoRoot -ChildPath 'deploy.ps1'
$usesBasePackageFlow = -not [string]::IsNullOrWhiteSpace($BaseArchive) -or -not [string]::IsNullOrWhiteSpace($BaseDirectory) -or -not [string]::IsNullOrWhiteSpace($BaseUrl)

if ($usesBasePackageFlow) {
    $resolvedBase = Resolve-BasePackageRoot -Manifest $manifest -SelectedPackageId $PackageId -ExplicitBaseArchive $BaseArchive -ExplicitBaseDirectory $BaseDirectory -ExplicitBaseUrl $BaseUrl -EffectiveDownloadCacheDir $effectiveDownloadCacheDir -SkipChecksum:$NoChecksum
    if ([string]$resolvedBase.Package.variant -match '^(?i)noVS$') {
        Write-Warning "The selected base package is noVS. Your tracked VS scripts and models will need an additional VS-capable runtime or add-on pack to work."
    }

    & $deployScript `
        -Action Install `
        -TargetDir $targetRuntimeRoot `
        -ManifestPath $manifestFullPath `
        -SourceRoot $configSourceRoot `
        -StagingDir $resolvedBase.Root `
        -OverlayDirectories $overlayRoots `
        -ResolvedPackageId ([string]$resolvedBase.Package.id) `
        -ResolvedPackageRepo ([string]$resolvedBase.Package.repo) `
        -ResolvedPackageTag ([string]$resolvedBase.Package.tag) `
        -ResolvedPackageVariant ([string]$resolvedBase.Package.variant) `
        -ResolvedSourceType ([string]$resolvedBase.Source)
    return
}

if (-not (Test-Path -LiteralPath $targetRuntimeRoot -PathType Container)) {
    throw "Target runtime directory '$targetRuntimeRoot' does not exist. Install the runtime first with Scoop or rerun bootstrap with -BaseArchive / -BaseDirectory."
}

$resolvedRuntimeSourceType = if (-not [string]::IsNullOrWhiteSpace($ScoopApp)) { 'scoop-runtime' } else { 'existing-runtime' }

& $deployScript `
    -Action Update `
    -TargetDir $targetRuntimeRoot `
    -ManifestPath $manifestFullPath `
    -SourceRoot $configSourceRoot `
    -OverlayDirectories $overlayRoots `
    -ResolvedSourceType $resolvedRuntimeSourceType
