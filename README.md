# Enable-SPOGuestExpiration_ReadyforTesting.ps1
Powershell scripts for enabling and disabling guest expiration policy for a specific set of sites that are defined in a sites.csv file
#### What it does

For each site in the CSV, the script sets `-OverrideTenantExternalUserExpirationPolicy $true` and `-ExternalUserExpirationInDays <value>`. Both are documented Set-SPOSite parameters. It reads each site's current settings before changing anything and checks them again afterwards. Sites that already have the right value are skipped, so you can run it again safely.

#### Settings at the top of the script

| Setting | Purpose |
|---------|---------|
| `$TenantId`, `$AppId`, `$CertThumbprint` | Sign-in details for the app registration |
| `$AdminUrl` | Your SharePoint admin center URL |
| `$CsvPath`, `$CsvUrlColumn` | Input file and its column name (default `SiteUrl`) |
| `$GuestExpirationDays` | Days before guest access expires (checked to be between 30 and 730) |
| `$WhatIfMode` | **Defaults to `$true`** (preview only). Set it to `$false` to make the changes. |

#### App-only sign-in

The script uses the app-only sign-in option in the SharePoint Online Management Shell: `Connect-SPOService [-Url] ... -ClientId <String> -TenantId <String> ... [-CertificateThumbprint <String>]`. Before connecting, it checks three things:

- The installed module version supports certificate sign-in.
- The certificate is in the CurrentUser or LocalMachine store, has its private key and hasn't expired.
- The tenant ID and app ID are valid GUIDs.

#### Throttling safeguards

- **Pacing:** a 1.5-second pause between sites, plus a random extra delay.
- **Batch pauses:** a 60-second pause after every 50 sites.
- **Retries:** up to 6 retries with increasing waits (10s, 20s, 40s and so on, up to 5 minutes) on 429, 503 or "server busy" errors. If the service says how long to wait, the script waits that long instead.
- **Reconnect:** if the sign-in session expires partway through, the script reconnects automatically.
- **Labelled traffic:** a `ClientTag` (`NONISV|Contoso|...`) identifies the script's calls, as Microsoft's throttling guidance recommends.
- **Fewer calls:** sites that are already configured are skipped, and a site that fails with a non-temporary error is not retried.

#### Before you run it

1. **App registration:** add the SharePoint application permission **Sites.FullControl.All**, grant admin consent and upload the certificate's public key.
2. **Certificate:** install the certificate, with its private key, on the machine that will run the script.
3. **Module:** use a recent version of the SPO Management Shell (`Update-Module Microsoft.Online.SharePoint.PowerShell`). Windows PowerShell 5.1 is recommended.
4. **First run:** keep `$WhatIfMode = $true`, review the results file, then switch it to `$false`.

#### Results and logs

After each site, the script updates a timestamped results file (status, previous and new values, sharing setting) and a full log in `$OutputFolder`. If a run stops partway, you can see exactly which sites were done. Sites with external sharing turned off are flagged, because the guest-expiration setting has no effect on them until sharing is enabled.





# Disable-SPOGuestExpiration_ReadyForTesting.ps1

#### What the it does

For each site in the CSV, it sets `-OverrideTenantExternalUserExpirationPolicy $false`. That removes the site's own guest expiration policy. It reads each site's settings before changing anything and checks them again afterwards. Sites where the override is already off are skipped, so you can run it again safely.

**Important:** turning off the site override doesn't stop guests from expiring if your tenant-wide guest expiration setting is on. In that case the site goes back to following the tenant setting. The script checks the tenant setting when it starts:

- **Tenant setting on:** it warns you that guests will still expire on the tenant schedule. Each site's result says the tenant policy now applies.
- **Tenant setting off:** guests on these sites will no longer expire.

To stop guest expiration everywhere, you'd also need to run `Set-SPOTenant -ExternalUserExpirationRequired $false`. The script doesn't do this.

#### Settings at the top of the script

| Setting | Purpose |
|---------|---------|
| `$TenantId`, `$AppId`, `$CertThumbprint` | Sign-in details for the app registration (certificate sign-in, no user account) |
| `$AdminUrl` | Your SharePoint admin center URL |
| `$CsvPath`, `$CsvUrlColumn` | Input file and its column name |
| `$WhatIfMode` | **Defaults to `$true`** (preview only). Set it to `$false` to make the changes. |
| `$SkipIfAlreadyDisabled` | Skips sites where the override is already off |

#### Throttling safeguards

These are the same as in the enable script:

- **Pacing:** a 1.5-second pause between sites, plus a random extra delay.
- **Batch pauses:** a 60-second pause after every 50 sites.
- **Retries:** up to 6 retries with increasing waits, up to 5 minutes, on 429, 503 or "server busy" errors. If the service says how long to wait, the script waits that long instead.
- **Reconnect:** if the sign-in session expires partway through, the script reconnects automatically.
- **Labelled traffic:** a `ClientTag` identifies the script's calls, as Microsoft's throttling guidance recommends.

#### Before you run it

The same setup as the enable script applies: the app registration needs **Sites.FullControl.All** with admin consent, the certificate must be installed with its private key, and you need a recent version of the SPO Management Shell.

#### Results and logs

Results and a full log go to `C:\Scripts\GuestExpirationDisable\Logs`. The results file records each site's previous override and number of days, so you can turn expiration back on later with the enable script if you need to.
