# Set-SPOSiteGuestExpirationPolicy
Powershell scripts for enabling and disabling guest expiration policy for a specific set of sites that are defined in a sites.csv file
What it does
For each site in the CSV, the script sets -OverrideTenantExternalUserExpirationPolicy $true and -ExternalUserExpirationInDays <value>. Both are documented Set-SPOSite parameters. It reads each site's current settings before changing anything and checks them again afterwards. Sites that already have the right value are skipped, so you can run it again safely.

Settings at the top of the script

Setting	Purpose
$TenantId, $AppId, $CertThumbprint	Sign-in details for the app registration
$AdminUrl	Your SharePoint admin center URL
$CsvPath, $CsvUrlColumn	Input file and its column name (default SiteUrl)
$GuestExpirationDays	Days before guest access expires (checked to be between 30 and 730)
$WhatIfMode	Defaults to $true (preview only). Set it to $false to make the changes.
App-only sign-in
The script uses the app-only sign-in option in the SharePoint Online Management Shell: Connect-SPOService [-Url] ... -ClientId <String> -TenantId <String> ... [-CertificateThumbprint <String>]. Before connecting, it checks three things:

The installed module version supports certificate sign-in.
The certificate is in the CurrentUser or LocalMachine store, has its private key and hasn't expired.
The tenant ID and app ID are valid GUIDs.
Throttling safeguards
Pacing: a 1.5-second pause between sites, plus a random extra delay.
Batch pauses: a 60-second pause after every 50 sites.
Retries: up to 6 retries with increasing waits (10s, 20s, 40s and so on, up to 5 minutes) on 429, 503 or "server busy" errors. If the service says how long to wait, the script waits that long instead.
Reconnect: if the sign-in session expires partway through, the script reconnects automatically.
Labelled traffic: a ClientTag (NONISV|Contoso|...) identifies the script's calls, as Microsoft's throttling guidance recommends.
Fewer calls: sites that are already configured are skipped, and a site that fails with a non-temporary error is not retried.
Before you run it
App registration: add the SharePoint application permission Sites.FullControl.All, grant admin consent and upload the certificate's public key.
Certificate: install the certificate, with its private key, on the machine that will run the script.
Module: use a recent version of the SPO Management Shell (Update-Module Microsoft.Online.SharePoint.PowerShell). Windows PowerShell 5.1 is recommended.
First run: keep $WhatIfMode = $true, review the results file, then switch it to $false.
Results and logs
After each site, the script updates a timestamped results file (status, previous and new values, sharing setting) and a full log in $OutputFolder. If a run stops partway, you can see exactly which sites were done. Sites with external sharing turned off are flagged, because the guest-expiration setting has no effect on them until sharing is enabled.
