#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fetches Azure compute and network quotas across subscriptions and locations.

.DESCRIPTION
    Iterates Azure subscriptions and locations, collects VM (compute) and network
    quota/usage data via Azure CLI, and exports results to CSV.
    Supports interactive login, service principal, and managed identity authentication.

.PARAMETER Locations
    Azure regions to query. Defaults to 'norwayeast'.
    Pass multiple: -Locations norwayeast,westeurope,swedencentral

.PARAMETER AllLocations
    Discover and query all available locations per subscription (exhaustive but slow).

.PARAMETER SubscriptionIds
    Limit scan to specific subscription IDs. Defaults to all enabled subscriptions.

.PARAMETER OutputFile
    CSV output path. Defaults to 'AzureQuotas_TIMESTAMP.csv' in current directory.

.PARAMETER OnlyUsed
    Only include quotas where current usage is greater than zero.

.PARAMETER AuthMode
    Authentication method:
      CurrentSession   - Use existing 'az login' session (default)
      Interactive      - Launch browser-based interactive login
      ServicePrincipal - Non-interactive login with app credentials
      ManagedIdentity  - Non-interactive login via Azure managed identity

.PARAMETER TenantId
    Tenant ID (required for ServicePrincipal, optional for Interactive).

.PARAMETER ClientId
    Application/client ID (required for ServicePrincipal).

.PARAMETER ClientSecret
    Client secret (required for ServicePrincipal).
    Note: passed via environment variable to avoid process argument exposure.

.EXAMPLE
    .\Get-AzureQuotas.ps1
    # Uses current session, queries norwayeast across all enabled subscriptions.

.EXAMPLE
    .\Get-AzureQuotas.ps1 -Locations norwayeast,westeurope,swedencentral -OnlyUsed
    # Queries three regions, only exports quotas with usage > 0.

.EXAMPLE
    .\Get-AzureQuotas.ps1 -AuthMode Interactive -AllLocations
    # Interactive login, exhaustive scan of all locations.

.EXAMPLE
    .\Get-AzureQuotas.ps1 -AuthMode ServicePrincipal -TenantId <tid> -ClientId <cid> -ClientSecret <secret>
    # Non-interactive service principal authentication.

.EXAMPLE
    .\Get-AzureQuotas.ps1 -AuthMode ManagedIdentity -SubscriptionIds "aaaa-bbbb","cccc-dddd"
    # Managed identity auth, limited to two subscriptions.
#>

[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string[]]$Locations = @('norwayeast'),

    [switch]$AllLocations,

    [string[]]$SubscriptionIds,

    [string]$OutputFile,

    [switch]$OnlyUsed,

    [ValidateSet('CurrentSession', 'Interactive', 'ServicePrincipal', 'ManagedIdentity')]
    [string]$AuthMode = 'CurrentSession',

    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warn','Error','Success')]
        [string]$Level = 'Info'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $formatted = "[$ts] $($Level.ToUpper().PadRight(7)) $Message"
    switch ($Level) {
        'Info'    { Write-Information $formatted -InformationAction Continue }
        'Warn'    { Write-Warning $formatted }
        'Error'   { Write-Error $formatted -ErrorAction Continue }
        'Success' { Write-Information $formatted -InformationAction Continue }
    }
}

function Invoke-AzCli {
    <#
    .SYNOPSIS
        Wraps az CLI calls with proper exit-code and stderr handling.
        Returns a hashtable: @{ Success; Data; Error; ExitCode }
    #>
    param([Parameter(Mandatory)][string[]]$Arguments)

    # Prevent $ErrorActionPreference from interfering with native command stderr
    $previousNativePref = $null
    if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
        $previousNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    $stdOut = $null
    $stdErr = ''

    try {
        $stdOut = & az @Arguments --only-show-errors 2>&1 |
            ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) {
                    $stdErr += $_.ToString() + "`n"
                } else {
                    $_
                }
            }
    } catch {
        return @{
            Success  = $false
            Data     = $null
            Error    = $_.Exception.Message
            ExitCode = -1
        }
    } finally {
        if ($null -ne $previousNativePref) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePref
        }
    }

    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }

    if ($code -ne 0) {
        $errMsg = if ($stdErr) { $stdErr.Trim() } else { ($stdOut | Out-String).Trim() }
        return @{
            Success  = $false
            Data     = $null
            Error    = $errMsg
            ExitCode = $code
        }
    }

    # Parse JSON output
    $raw = ($stdOut -join "`n").Trim()
    if (-not $raw) {
        return @{ Success = $true; Data = $null; Error = $null; ExitCode = 0 }
    }

    try {
        $parsed = $raw | ConvertFrom-Json
        return @{ Success = $true; Data = $parsed; Error = $null; ExitCode = 0 }
    } catch {
        return @{
            Success  = $false
            Data     = $null
            Error    = "JSON parse failed: $($_.Exception.Message)"
            ExitCode = 0
        }
    }
}

function ConvertTo-SafeLong {
    param([object]$Value, [long]$Default = 0)
    if ($null -eq $Value) { return $Default }
    [long]$parsed = 0
    if ([long]::TryParse("$Value", [ref]$parsed)) { return $parsed }
    return $Default
}

function Get-SafeString {
    param([object]$Value, [string]$Default = '')
    if ($null -eq $Value) { return $Default }
    return "$Value"
}

function Limit-String {
    param([string]$Value, [int]$MaxLength = 200)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'No details available' }
    if ($Value.Length -le $MaxLength) { return $Value }
    return $Value.Substring(0, $MaxLength)
}

#endregion Helpers

#region Authentication

Write-Log "Authentication mode: $AuthMode"

switch ($AuthMode) {
    'Interactive' {
        Write-Log 'Launching interactive browser login...'
        $loginArgs = @('login')
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) { $loginArgs += '--tenant', $TenantId }
        $result = Invoke-AzCli -Arguments $loginArgs
        if (-not $result.Success) {
            Write-Log "Interactive login failed: $($result.Error)" -Level Error
            exit 1
        }
        Write-Log 'Interactive login successful' -Level Success
    }

    'ServicePrincipal' {
        if ([string]::IsNullOrWhiteSpace($TenantId) -or
            [string]::IsNullOrWhiteSpace($ClientId) -or
            [string]::IsNullOrWhiteSpace($ClientSecret)) {
            Write-Log 'ServicePrincipal requires -TenantId, -ClientId, and -ClientSecret' -Level Error
            exit 1
        }
        Write-Log "Logging in as service principal $ClientId..."
        try {
            $env:AZURE_CLIENT_SECRET = $ClientSecret
            $result = Invoke-AzCli -Arguments @(
                'login', '--service-principal',
                '--username', $ClientId,
                '--password', $env:AZURE_CLIENT_SECRET,
                '--tenant', $TenantId
            )
        } finally {
            Remove-Item Env:\AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue
        }
        if (-not $result.Success) {
            Write-Log "Service principal login failed: $($result.Error)" -Level Error
            exit 1
        }
        Write-Log 'Service principal login successful' -Level Success
    }

    'ManagedIdentity' {
        Write-Log 'Logging in with managed identity...'
        $result = Invoke-AzCli -Arguments @('login', '--identity')
        if (-not $result.Success) {
            Write-Log "Managed identity login failed: $($result.Error)" -Level Error
            exit 1
        }
        Write-Log 'Managed identity login successful' -Level Success
    }

    'CurrentSession' {
        Write-Log 'Verifying existing Azure CLI session...'
        $result = Invoke-AzCli -Arguments @('account', 'show', '--output', 'json')
        if (-not $result.Success) {
            Write-Log "No active session. Run 'az login' first, or use -AuthMode Interactive." -Level Error
            exit 1
        }
        $signedInAs = 'unknown'
        if ($null -ne $result.Data -and $result.Data -is [PSCustomObject]) {
            if ($null -ne $result.Data.PSObject.Properties['user'] -and
                $null -ne $result.Data.user -and
                $null -ne $result.Data.user.PSObject.Properties['name']) {
                $signedInAs = $result.Data.user.name
            }
        }
        Write-Log "Session active, signed in as: $signedInAs" -Level Success
    }
}

#endregion Authentication

#region Subscription discovery

Write-Log 'Fetching subscriptions...'

$subscriptions = [System.Collections.Generic.List[object]]::new()

if ($SubscriptionIds -and $SubscriptionIds.Count -gt 0) {
    foreach ($sid in $SubscriptionIds) {
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        $r = Invoke-AzCli -Arguments @('account', 'show', '--subscription', $sid, '--output', 'json')
        if ($r.Success -and $null -ne $r.Data) {
            $subscriptions.Add($r.Data)
        } else {
            Write-Log "Subscription not found or no access: $sid - $($r.Error)" -Level Warn
        }
    }
} else {
    $r = Invoke-AzCli -Arguments @('account', 'list', '--query', "[?state=='Enabled']", '--output', 'json')
    if (-not $r.Success) {
        Write-Log "Failed to list subscriptions: $($r.Error)" -Level Error
        exit 1
    }
    if ($null -ne $r.Data) {
        foreach ($s in @($r.Data)) {
            if ($null -ne $s) { $subscriptions.Add($s) }
        }
    }
}

if ($subscriptions.Count -eq 0) {
    Write-Log 'No accessible subscriptions found.' -Level Error
    exit 1
}

Write-Log "Found $($subscriptions.Count) subscription(s)" -Level Success

#endregion Subscription discovery

#region Output file setup

if (-not $OutputFile) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputFile = Join-Path (Get-Location) "AzureQuotas_$ts.csv"
}

# Validate output directory exists before running a long scan
$outputDir = [System.IO.Path]::GetDirectoryName($OutputFile)
if ($outputDir -and -not (Test-Path $outputDir)) {
    Write-Log "Output directory does not exist: $outputDir" -Level Error
    exit 1
}

# Derive error file path safely using Path APIs (not regex)
$outputBase = [System.IO.Path]::GetFileNameWithoutExtension($OutputFile)
if (-not $outputDir) { $outputDir = Get-Location }
$errorFile = Join-Path $outputDir "${outputBase}_errors.csv"

$scanMode = if ($AllLocations) { 'Exhaustive (all locations)' } else { "Targeted ($($Locations -join ', '))" }
Write-Log "Scan mode: $scanMode"
Write-Log "Output file: $OutputFile"

#endregion Output file setup

#region Main quota collection

$allResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$allErrors  = [System.Collections.Generic.List[PSCustomObject]]::new()
$totalSubs  = $subscriptions.Count
$subIdx     = 0

foreach ($sub in $subscriptions) {
    $subIdx++
    $subName = Get-SafeString $sub.name 'Unknown'
    $subId   = Get-SafeString $sub.id   'Unknown'
    Write-Log "[$subIdx/$totalSubs] $subName ($subId)"

    # Resolve locations
    if ($AllLocations) {
        $locResult = Invoke-AzCli -Arguments @(
            'account', 'list-locations',
            '--subscription', $subId,
            '--query', '[].name',
            '--output', 'json'
        )
        if ($locResult.Success -and $null -ne $locResult.Data) {
            $queryLocations = @($locResult.Data) | Where-Object { $null -ne $_ }
            if ($queryLocations.Count -eq 0) {
                Write-Log '  No locations returned, falling back to defaults' -Level Warn
                $queryLocations = $Locations
            } else {
                Write-Log "  Discovered $($queryLocations.Count) locations"
            }
        } else {
            Write-Log "  Location discovery failed, falling back to defaults: $($locResult.Error)" -Level Warn
            $queryLocations = $Locations
        }
    } else {
        $queryLocations = $Locations
    }

    $locTotal = $queryLocations.Count
    $locIdx   = 0

    foreach ($loc in $queryLocations) {
        $locIdx++

        # ---- Compute quotas (az vm list-usage) ----
        $computeResult = Invoke-AzCli -Arguments @(
            'vm', 'list-usage',
            '--location', $loc,
            '--subscription', $subId,
            '--output', 'json'
        )

        if ($computeResult.Success) {
            $count = 0
            foreach ($item in @($computeResult.Data)) {
                if ($null -eq $item) { continue }
                try {
                    $usage = ConvertTo-SafeLong $item.currentValue
                    $limit = ConvertTo-SafeLong $item.limit

                    if ($OnlyUsed -and $usage -eq 0) { continue }

                    $quotaName = Get-SafeString $item.name.localizedValue 'Unknown'
                    $quotaId   = Get-SafeString $item.name.value 'Unknown'

                    $allResults.Add([PSCustomObject]@{
                        SubscriptionName = $subName
                        SubscriptionId   = $subId
                        Location         = $loc
                        Provider         = 'Microsoft.Compute'
                        QuotaName        = $quotaName
                        QuotaId          = $quotaId
                        CurrentUsage     = $usage
                        Limit            = $limit
                        Unit             = 'Count'
                        UsagePercent     = if ($limit -gt 0) { [math]::Round(($usage / $limit) * 100, 1) } else { 0 }
                        Source           = 'az vm list-usage'
                        Status           = 'Success'
                    })
                    $count++
                } catch {
                    $allErrors.Add([PSCustomObject]@{
                        SubscriptionName = $subName
                        SubscriptionId   = $subId
                        Location         = $loc
                        Provider         = 'Microsoft.Compute'
                        Source           = 'az vm list-usage'
                        ErrorMessage     = "Item parse error: $($_.Exception.Message)"
                        ExitCode         = 0
                    })
                }
            }
            Write-Log "  [$locIdx/$locTotal] $loc - Compute: $count records" -Level Success
        } else {
            $errMsg = Limit-String $computeResult.Error
            Write-Log "  [$locIdx/$locTotal] $loc - Compute: FAILED ($errMsg)" -Level Warn
            $allErrors.Add([PSCustomObject]@{
                SubscriptionName = $subName
                SubscriptionId   = $subId
                Location         = $loc
                Provider         = 'Microsoft.Compute'
                Source           = 'az vm list-usage'
                ErrorMessage     = $computeResult.Error
                ExitCode         = $computeResult.ExitCode
            })
        }

        # ---- Network quotas (az network list-usages) ----
        $networkResult = Invoke-AzCli -Arguments @(
            'network', 'list-usages',
            '--location', $loc,
            '--subscription', $subId,
            '--output', 'json'
        )

        if ($networkResult.Success) {
            $count = 0
            foreach ($item in @($networkResult.Data)) {
                if ($null -eq $item) { continue }
                try {
                    $usage = ConvertTo-SafeLong $item.currentValue
                    $limit = ConvertTo-SafeLong $item.limit

                    if ($OnlyUsed -and $usage -eq 0) { continue }

                    $quotaName = Get-SafeString $item.name.localizedValue 'Unknown'
                    $quotaId   = Get-SafeString $item.name.value 'Unknown'
                    $unit      = Get-SafeString $item.unit 'Count'

                    $allResults.Add([PSCustomObject]@{
                        SubscriptionName = $subName
                        SubscriptionId   = $subId
                        Location         = $loc
                        Provider         = 'Microsoft.Network'
                        QuotaName        = $quotaName
                        QuotaId          = $quotaId
                        CurrentUsage     = $usage
                        Limit            = $limit
                        Unit             = $unit
                        UsagePercent     = if ($limit -gt 0) { [math]::Round(($usage / $limit) * 100, 1) } else { 0 }
                        Source           = 'az network list-usages'
                        Status           = 'Success'
                    })
                    $count++
                } catch {
                    $allErrors.Add([PSCustomObject]@{
                        SubscriptionName = $subName
                        SubscriptionId   = $subId
                        Location         = $loc
                        Provider         = 'Microsoft.Network'
                        Source           = 'az network list-usages'
                        ErrorMessage     = "Item parse error: $($_.Exception.Message)"
                        ExitCode         = 0
                    })
                }
            }
            Write-Log "  [$locIdx/$locTotal] $loc - Network: $count records" -Level Success
        } else {
            $errMsg = Limit-String $networkResult.Error
            Write-Log "  [$locIdx/$locTotal] $loc - Network: FAILED ($errMsg)" -Level Warn
            $allErrors.Add([PSCustomObject]@{
                SubscriptionName = $subName
                SubscriptionId   = $subId
                Location         = $loc
                Provider         = 'Microsoft.Network'
                Source           = 'az network list-usages'
                ErrorMessage     = $networkResult.Error
                ExitCode         = $networkResult.ExitCode
            })
        }
    }
}

#endregion Main quota collection

#region Export

if ($allResults.Count -gt 0) {
    $allResults | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding utf8BOM
    Write-Log "Exported $($allResults.Count) quota records to: $OutputFile" -Level Success
} else {
    Write-Log 'No quota data was collected.' -Level Warn
}

if ($allErrors.Count -gt 0) {
    $allErrors | Export-Csv -Path $errorFile -NoTypeInformation -Encoding utf8BOM
    Write-Log "Logged $($allErrors.Count) failed queries to: $errorFile" -Level Warn
}

#endregion Export

#region Summary

Write-Information '' -InformationAction Continue
Write-Log '========== SUMMARY =========='
Write-Log "Scan mode             : $scanMode"
Write-Log "Subscriptions scanned : $($subscriptions.Count)"
Write-Log "Total quota records   : $($allResults.Count)"
Write-Log "Failed queries        : $($allErrors.Count)"
Write-Log "Output                : $OutputFile"
if ($allErrors.Count -gt 0) {
    Write-Log "Error log             : $errorFile"
}
Write-Log 'Done.' -Level Success

#endregion Summary
