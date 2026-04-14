# Azure Quota Reports

Azure has no built-in way to see quota usage across all your subscriptions in one place. The portal shows one subscription at a time, and `az vm list-usage` only covers a single region. If you manage multiple subscriptions, spotting a quota that is about to block a deployment means clicking through dozens of pages or writing your own wrapper.

This script does that for you. It queries compute and network quota usage across all your subscriptions, exports the results to CSV, and flags quotas approaching their limits in the terminal.

## Requirements

- PowerShell 7.0 or later (pwsh)
- Azure CLI (az) installed and available on PATH
- An Azure account with Reader access to the target subscriptions

### Supported platforms

- Windows
- macOS
- Linux

### Installing prerequisites

**PowerShell 7+**

| Platform | Command |
|---|---|
| Windows | `winget install Microsoft.PowerShell` |
| macOS | `brew install powershell` |
| Linux (Debian/Ubuntu) | See https://learn.microsoft.com/en-us/powershell/scripting/install/install-ubuntu |

**Azure CLI**

| Platform | Command |
|---|---|
| Windows | `winget install Microsoft.AzureCLI` |
| macOS | `brew install azure-cli` |
| Linux (Debian/Ubuntu) | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` |
| Other | https://aka.ms/installazurecli |

The script checks for both prerequisites on startup and provides platform-specific install instructions if anything is missing.

## Quick start

```powershell
# Default: all subscriptions, norwayeast region, current az login session
./scripts/Get-AzureQuotas.ps1

# Multiple regions
./scripts/Get-AzureQuotas.ps1 -Locations norwayeast,westeurope,swedencentral

# Only show quotas that have usage
./scripts/Get-AzureQuotas.ps1 -OnlyUsed

# Specific subscriptions
./scripts/Get-AzureQuotas.ps1 -SubscriptionIds "aaaa-bbbb-cccc","dddd-eeee-ffff"

# Scan all available locations (slow but exhaustive)
./scripts/Get-AzureQuotas.ps1 -AllLocations

# Quiet mode (CSV only, no terminal table)
./scripts/Get-AzureQuotas.ps1 -Quiet

# Pipe results for downstream processing
./scripts/Get-AzureQuotas.ps1 | Where-Object { $_.UsagePercent -gt 90 }
```

## Authentication

The script supports four authentication modes via the `-AuthMode` parameter.

### CurrentSession (default)

Uses the existing `az login` session. If no session exists, the script exits with an error.

```powershell
az login
./scripts/Get-AzureQuotas.ps1
```

### Interactive

Opens a browser window for login. Useful when running from a workstation without an active session.

```powershell
./scripts/Get-AzureQuotas.ps1 -AuthMode Interactive
```

Optionally pass `-TenantId` to target a specific tenant.

### ServicePrincipal

Non-interactive login with an app registration. Requires `-TenantId`, `-ClientId`, and `-ClientSecret`.

```powershell
./scripts/Get-AzureQuotas.ps1 `
    -AuthMode ServicePrincipal `
    -TenantId "your-tenant-id" `
    -ClientId "your-client-id" `
    -ClientSecret "your-client-secret"
```

The client secret is passed via an environment variable to reduce process argument exposure. In shared environments, consider using managed identity or certificate-based authentication instead.

### ManagedIdentity

For use on Azure VMs, containers, or other resources with a managed identity assigned.

```powershell
./scripts/Get-AzureQuotas.ps1 -AuthMode ManagedIdentity
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| Locations | string[] | norwayeast | Azure regions to query |
| AllLocations | switch | false | Discover and query all locations per subscription |
| SubscriptionIds | string[] | all enabled | Filter to specific subscription IDs |
| OutputFile | string | AzureQuotas_TIMESTAMP.csv | Path for the output CSV |
| OnlyUsed | switch | false | Exclude quotas with zero usage |
| Quiet | switch | false | Suppress terminal output and info logs |
| HighUsageThreshold | int | 80 | Percentage threshold for the high-usage warning table |
| AuthMode | string | CurrentSession | Authentication method |
| TenantId | string | none | Tenant ID for ServicePrincipal or Interactive |
| ClientId | string | none | App ID for ServicePrincipal |
| ClientSecret | string | none | Secret for ServicePrincipal |

## Output

### Terminal output

By default the script displays two things in the terminal:

1. A high-usage warning table showing quotas at or above the threshold (default 80%). This is sorted by usage percentage, highest first, capped at 25 rows.
2. A full results table sorted by usage percentage, capped at 200 rows. The complete dataset is always in the CSV.

Use `-Quiet` to suppress all terminal output. Use `-HighUsageThreshold 0` to disable the warning table.

The script also emits quota objects to the pipeline, so you can pipe results into `Where-Object`, `Sort-Object`, `Format-Table`, `ConvertTo-Json`, or any other PowerShell command.

### CSV columns

| Column | Description |
|---|---|
| SubscriptionName | Display name of the subscription |
| SubscriptionId | Subscription GUID |
| Location | Azure region |
| Provider | Resource provider (Microsoft.Compute or Microsoft.Network) |
| QuotaName | Human-readable quota name |
| QuotaId | Machine-readable quota identifier |
| CurrentUsage | Current usage count |
| Limit | Quota limit |
| Unit | Unit of measurement |
| UsagePercent | Usage as a percentage of the limit |
| Source | Azure CLI command used to collect the data |
| Status | Success or error indicator |

### Sample CSV output

```
SubscriptionName,SubscriptionId,Location,Provider,QuotaName,QuotaId,CurrentUsage,Limit,Unit,UsagePercent,Source,Status
prod-web,aaaa-1111-2222-3333,norwayeast,Microsoft.Compute,Total Regional vCPUs,cores,88,100,Count,88.00,az vm list-usage,Success
prod-web,aaaa-1111-2222-3333,norwayeast,Microsoft.Compute,Standard Dv3 Family vCPUs,standardDv3Family,64,100,Count,64.00,az vm list-usage,Success
dev-sandbox,bbbb-4444-5555-6666,norwayeast,Microsoft.Network,Load Balancers,LoadBalancers,2,250,Count,0.80,az network list-usages,Success
dev-sandbox,bbbb-4444-5555-6666,westeurope,Microsoft.Compute,Total Regional vCPUs,cores,0,10,Count,0.00,az vm list-usage,Success
```

### Error CSV

If any queries fail, a separate `_errors.csv` file is created alongside the main output. It contains the subscription, location, provider, error message, and exit code for each failed query.

## Examples

Collect quotas from norwayeast for all subscriptions:

```powershell
./scripts/Get-AzureQuotas.ps1
```

Collect from three Nordic regions and export to a specific file:

```powershell
./scripts/Get-AzureQuotas.ps1 `
    -Locations norwayeast,norwaywest,swedencentral `
    -OutputFile "./reports/nordic-quotas.csv"
```

Collect only quotas with active usage across all locations:

```powershell
./scripts/Get-AzureQuotas.ps1 -AllLocations -OnlyUsed
```

Find quotas above 90% usage:

```powershell
./scripts/Get-AzureQuotas.ps1 | Where-Object { $_.UsagePercent -gt 90 } | Format-Table
```

Export to JSON:

```powershell
./scripts/Get-AzureQuotas.ps1 -Quiet | ConvertTo-Json | Set-Content quotas.json
```

## Troubleshooting

**"Azure CLI (az) is not installed"**: Follow the install instructions shown by the script, or visit https://aka.ms/installazurecli.

**"#Requires" error about PowerShell version**: Install PowerShell 7+ from https://aka.ms/powershell.

**"No active session" error**: Run `az login` first, or use `-AuthMode Interactive`.

**Empty results for a region**: The subscription may not have the provider registered in that region. Check the error CSV for details.

**Slow execution with -AllLocations**: Each subscription can have 60+ locations. The script queries compute and network quotas for each one. Use `-Locations` to target specific regions instead.

**Permission errors**: The account needs at least Reader role on the target subscriptions.

**Line ending issues on Linux/macOS**: The repository uses LF line endings via .gitattributes. If the shebang fails, check that the file has not been converted to CRLF.
