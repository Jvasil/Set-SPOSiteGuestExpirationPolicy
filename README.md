# Set-SPOSiteGuestExpirationPolicy
Powershell scripts for enabling and disabling guest expiration policy for a specific set of sites that are defined in a sites.csv file
#### What it does

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
