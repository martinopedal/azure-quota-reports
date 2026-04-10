# Azure Quota Reports

PowerShell script that collects Azure compute and network quota usage across all subscriptions and exports the results to CSV.

## What it does

- Queries all enabled Azure subscriptions (or a filtered set)
- Collects VM/compute quotas via `az vm list-usage`
- Collects network quotas via `az network list-usages`
- Exports quota data to a timestamped CSV file
- Logs failed queries to a separate error CSV

## Requirements

- PowerShell 7 or later
- Azure CLI (`az`) installed and available on PATH
- An Azure account with Reader access to the target subscriptions

## Quick start

```powershell
# Default: all subscriptions, norwayeast region, current az login session
.\scripts\Get-AzureQuotas.ps1

# Multiple regions
.\scripts\Get-AzureQuotas.ps1 -Locations norwayeast,westeurope,swedencentral

# Only show quotas that have usage
.\scripts\Get-AzureQuotas.ps1 -OnlyUsed

# Specific subscriptions
.\scripts\Get-AzureQuotas.ps1 -SubscriptionIds "aaaa-bbbb-cccc","dddd-eeee-ffff"

# Scan all available locations (slow but exhaustive)
.\scripts\Get-AzureQuotas.ps1 -AllLocations
```

## Authentication

The script supports four authentication modes via the `-AuthMode` parameter.

### CurrentSession (default)

Uses the existing `az login` session. If no session exists, the script exits with an error.

```powershell
az login
.\scripts\Get-AzureQuotas.ps1
```

### Interactive

Opens a browser window for login. Useful when running from a workstation without an active session.

```powershell
.\scripts\Get-AzureQuotas.ps1 -AuthMode Interactive
```

Optionally pass `-TenantId` to target a specific tenant.

### ServicePrincipal

Non-interactive login with an app registration. Requires `-TenantId`, `-ClientId`, and `-ClientSecret`.

```powershell
.\scripts\Get-AzureQuotas.ps1 `
    -AuthMode ServicePrincipal `
    -TenantId "your-tenant-id" `
    -ClientId "your-client-id" `
    -ClientSecret "your-client-secret"
```

Note: the client secret is passed as a command-line argument to `az login`. In shared environments, consider setting `AZURE_CLIENT_SECRET` as an environment variable and modifying the script accordingly.

### ManagedIdentity

For use on Azure VMs, containers, or other resources with a managed identity assigned.

```powershell
.\scripts\Get-AzureQuotas.ps1 -AuthMode ManagedIdentity
```

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| Locations | string[] | norwayeast | Azure regions to query |
| AllLocations | switch | false | Discover and query all locations per subscription |
| SubscriptionIds | string[] | all enabled | Filter to specific subscription IDs |
| OutputFile | string | AzureQuotas_TIMESTAMP.csv | Path for the output CSV |
| OnlyUsed | switch | false | Exclude quotas with zero usage |
| AuthMode | string | CurrentSession | Authentication method |
| TenantId | string | none | Tenant ID for ServicePrincipal or Interactive |
| ClientId | string | none | App ID for ServicePrincipal |
| ClientSecret | string | none | Secret for ServicePrincipal |

## Output

### Quota CSV columns

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

### Error CSV

If any queries fail, a separate `_errors.csv` file is created alongside the main output. It contains the subscription, location, provider, error message, and exit code for each failed query.

## Examples

Collect quotas from norwayeast for all subscriptions:

```powershell
.\scripts\Get-AzureQuotas.ps1
```

Collect from three Nordic regions and export to a specific file:

```powershell
.\scripts\Get-AzureQuotas.ps1 `
    -Locations norwayeast,norwaywest,swedencentral `
    -OutputFile "C:\reports\nordic-quotas.csv"
```

Collect only quotas with active usage across all locations:

```powershell
.\scripts\Get-AzureQuotas.ps1 -AllLocations -OnlyUsed
```

## Troubleshooting

**"No active session" error**: Run `az login` first, or use `-AuthMode Interactive`.

**Empty results for a region**: The subscription may not have the provider registered in that region. Check the error CSV for details.

**Slow execution with -AllLocations**: Each subscription can have 60+ locations. The script queries compute and network quotas for each one. Use `-Locations` to target specific regions instead.

**Permission errors**: The account needs at least Reader role on the target subscriptions.
