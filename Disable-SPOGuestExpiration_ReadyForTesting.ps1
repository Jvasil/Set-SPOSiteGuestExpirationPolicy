<#
.Disclaimer
 The sample scripts are provided AS IS without warranty of any kind. 
    Microsoft further disclaims all implied warranties including, without limitation, 
    any implied warranties of merchantability or of fitness for a particular purpose. 
    The entire risk arising out of the use or performance of the sample scripts and documentation remains with you. 
    In no event shall Microsoft, its authors, or anyone else involved in the creation, 
    production, or delivery of the scripts be liable for any damages whatsoever 
    (including, without limitation, damages for loss of business profits, business interruption, 
    loss of business information, or other pecuniary loss) arising out of the use of or inability 
    to use the sample scripts or documentation, even if Microsoft has been advised of the possibility of such damages.
.SYNOPSIS
    Disables the site-level guest (external user) access expiration override on
    a list of SharePoint Online sites read from a CSV file.

.DESCRIPTION
    - Connects to the SharePoint admin center with the SharePoint Online
      Management Shell using an Entra ID app registration (app-only,
      certificate authentication).
    - Reads site URLs from a CSV file, validates and de-duplicates them.
    - For each site, sets:
          OverrideTenantExternalUserExpirationPolicy = $false
      This removes the site-specific guest expiration policy so the site no
      longer applies its own expiration setting.
    - IMPORTANT: once the override is removed, the site follows the TENANT-level
      guest expiration setting (Set-SPOTenant -ExternalUserExpirationRequired).
      If the tenant setting is ON, guests on these sites will still expire on
      the tenant schedule. The script checks the tenant setting and warns you.
    - Skips sites where the override is already off (fewer write calls = less throttling).
    - Throttling safeguards: request pacing with jitter, batch cool-down pauses,
      exponential back-off retries that honor Retry-After when present,
      automatic re-connect on token/session errors, and a traffic-decorated
      ClientTag as Microsoft recommends.
    - Writes a timestamped results CSV and a transcript log.

.PREREQUISITES
    1. Module: Microsoft.Online.SharePoint.PowerShell (a recent version whose
       Connect-SPOService supports -ClientId/-TenantId/-CertificateThumbprint).
           Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser
           Update-Module  Microsoft.Online.SharePoint.PowerShell
       Windows PowerShell 5.1 is recommended for this module.
    2. Entra ID app registration:
         - API permissions > SharePoint > Application permissions > Sites.FullControl.All
         - Admin consent granted
         - Certificate (.cer public key) uploaded under Certificates & secrets
    3. The matching certificate (with private key) installed in
       Cert:\CurrentUser\My or Cert:\LocalMachine\My on the machine running the script.
    4. CSV file with a header column named "SiteUrl" (configurable below), e.g.:
           SiteUrl
           https://contoso.sharepoint.com/sites/ProjectA
           https://contoso.sharepoint.com/sites/ProjectB

.NOTES
    Run first with $WhatIfMode = $true to preview the changes.
    To turn guest expiration off everywhere, the tenant setting must also be
    off: Set-SPOTenant -ExternalUserExpirationRequired $false
#>

#region ===================== CONFIGURATION (edit these) =====================

# --- App-only authentication ---
$TenantId       = "EnterYourTenantID"   # Entra tenant (directory) ID
$AppId          = "EnterYourAppID"   # App registration (client) ID
$CertThumbprint = "EnterYourCertThumbprint" # Certificate thumbprint

# --- Tenant ---
$AdminUrl       = "https://contoso-admin.sharepoint.com"    # SharePoint admin center URL

# --- Input / output ---
$CsvPath        = "C:\enterYourFilePath\Sites.csv"     # Input CSV
$CsvUrlColumn   = "SiteUrl"                                  # Column holding the site URLs
$OutputFolder   = "C:\enterYourFilePath\Logs"          # Results CSV + transcript

# --- Safety ---
$WhatIfMode     = $true          # $true = preview only (no changes). Set $false to apply.
$SkipIfAlreadyDisabled = $true   # Skip sites where the site-level override is already off

# --- Throttling safeguards ---
$DelayBetweenSitesMs  = 1500     # Base pause between sites (milliseconds)
$JitterMaxMs          = 750      # Random extra delay added to each pause
$BatchSize            = 50       # Sites processed before a longer cool-down
$BatchPauseSeconds    = 60       # Cool-down after every batch
$MaxRetries           = 6        # Retries per call on throttling / transient errors
$InitialBackoffSec    = 10       # First back-off wait; doubles each retry
$MaxBackoffSec        = 300      # Cap for any single back-off wait

# Traffic decoration (Microsoft guidance for avoiding throttling)
#$ClientTag = "NONISV|Contoso|SPOGuestExpirationDisableScript/1.0"

#endregion ==================================================================

#region ===================== HELPER FUNCTIONS ==============================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR","SUCCESS")][string]$Level = "INFO"
    )
    $color = switch ($Level) { "INFO" {"Gray"} "WARN" {"Yellow"} "ERROR" {"Red"} "SUCCESS" {"Green"} }
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message) -ForegroundColor $color
}

function Start-Pacing {
    # Standard pause between requests, with jitter so calls never fire in lock-step
    $ms = $DelayBetweenSitesMs + (Get-Random -Minimum 0 -Maximum ($JitterMaxMs + 1))
    Start-Sleep -Milliseconds $ms
}

function Test-IsThrottleError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $text = ($ErrorRecord.Exception.ToString() + " " + $ErrorRecord.ToString())
    return ($text -match '429|503|Too many requests|throttl|Server Busy|server is busy|temporarily unavailable|timed out|timeout|The operation has timed out|Unable to connect|connection was closed')
}

function Test-IsAuthError {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $text = ($ErrorRecord.Exception.ToString() + " " + $ErrorRecord.ToString())
    return ($text -match '401|Unauthorized|token.*expired|No connection available|Connect-SPOService|session')
}

function Get-RetryAfterSeconds {
    # Honors a Retry-After value if the service included one in the error
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $text = $ErrorRecord.Exception.ToString()
    if ($text -match 'Retry-After\D{0,5}(\d+)') { return [int]$Matches[1] }
    return $null
}

function Connect-SPOAppOnly {
    Write-Log "Connecting to $AdminUrl with app-only certificate authentication..."
    Connect-SPOService -Url $AdminUrl `
                       -ClientId $AppId `
                       -TenantId $TenantId `
                       -CertificateThumbprint $CertThumbprint `
                       -ErrorAction Stop
    Write-Log "Connected." "SUCCESS"
}

function Invoke-WithRetry {
    <#
        Runs a script block with exponential back-off for throttling and
        transient errors, and re-connects once per failure on auth/session errors.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = "Operation"
    )

    $attempt = 0
    $backoff = $InitialBackoffSec

    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            $err = $_
            $attempt++

            if ($attempt -gt $MaxRetries) {
                Write-Log "$OperationName failed after $MaxRetries retries: $($err.Exception.Message)" "ERROR"
                throw
            }

            if (Test-IsThrottleError $err) {
                $retryAfter = Get-RetryAfterSeconds $err
                $wait = if ($retryAfter) { $retryAfter } else { [Math]::Min($backoff, $MaxBackoffSec) }
                $wait += Get-Random -Minimum 1 -Maximum 6   # jitter
                Write-Log "$OperationName throttled / transient error (attempt $attempt of $MaxRetries). Waiting $wait s..." "WARN"
                Start-Sleep -Seconds $wait
                $backoff = [Math]::Min($backoff * 2, $MaxBackoffSec)
            }
            elseif (Test-IsAuthError $err) {
                Write-Log "$OperationName hit an authentication/session error (attempt $attempt). Re-connecting..." "WARN"
                Start-Sleep -Seconds 5
                Connect-SPOAppOnly
            }
            else {
                # Non-transient error (e.g. site not found, invalid value) - do not retry
                throw
            }
        }
    }
}

#endregion ==================================================================

#region ===================== PRE-FLIGHT CHECKS =============================

if (-not (Test-Path $OutputFolder)) { New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null }
$stamp       = Get-Date -Format "yyyyMMdd_HHmmss"
$resultsPath = Join-Path $OutputFolder "GuestExpirationDisable_Results_$stamp.csv"
$logPath     = Join-Path $OutputFolder "GuestExpirationDisable_Transcript_$stamp.log"
Start-Transcript -Path $logPath -Append | Out-Null

try {
    Write-Log "===== SharePoint guest expiration DISABLE script started ====="
    if ($WhatIfMode) { Write-Log "WHATIF MODE: no changes will be made." "WARN" }

    # Validate configured values
    foreach ($pair in @(@{N="TenantId";V=$TenantId}, @{N="AppId";V=$AppId})) {
        $g = [guid]::Empty
        if (-not [guid]::TryParse($pair.V, [ref]$g)) { throw "$($pair.N) is not a valid GUID: $($pair.V)" }
    }

    # Module check
    if (-not (Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell)) {
        throw "Microsoft.Online.SharePoint.PowerShell is not installed. Run: Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser"
    }
    Import-Module Microsoft.Online.SharePoint.PowerShell -DisableNameChecking -ErrorAction Stop
    $connectCmd = Get-Command Connect-SPOService
    if (-not $connectCmd.Parameters.ContainsKey("CertificateThumbprint")) {
        throw "The installed SPO Management Shell does not support app-only certificate sign-in. Run: Update-Module Microsoft.Online.SharePoint.PowerShell"
    }

    # Certificate check (private key must be present)
    $CertThumbprint = ($CertThumbprint -replace '\s','').ToUpper()
    $cert = Get-ChildItem -Path "Cert:\CurrentUser\My\$CertThumbprint","Cert:\LocalMachine\My\$CertThumbprint" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cert)               { throw "Certificate $CertThumbprint not found in CurrentUser\My or LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "Certificate $CertThumbprint has no private key on this machine." }
    if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $CertThumbprint expired on $($cert.NotAfter)." }
    Write-Log "Certificate found: $($cert.Subject) (expires $($cert.NotAfter))"

    # CSV check
    if (-not (Test-Path $CsvPath)) { throw "CSV file not found: $CsvPath" }
    $rows = Import-Csv -Path $CsvPath
    if (-not $rows) { throw "CSV file is empty: $CsvPath" }
    if (-not ($rows[0].PSObject.Properties.Name -contains $CsvUrlColumn)) {
        throw "CSV is missing the required column '$CsvUrlColumn'. Columns found: $($rows[0].PSObject.Properties.Name -join ', ')"
    }

    $siteUrls = $rows |
        ForEach-Object { ($_.$CsvUrlColumn -as [string]).Trim().TrimEnd('/') } |
        Where-Object { $_ } |
        Sort-Object -Unique

    $invalid  = $siteUrls | Where-Object { $_ -notmatch '^https://[a-zA-Z0-9-]+\.sharepoint\.(com|us|de|cn)/' }
    $siteUrls = $siteUrls | Where-Object { $_ -match '^https://[a-zA-Z0-9-]+\.sharepoint\.(com|us|de|cn)/' }
    foreach ($bad in $invalid) { Write-Log "Skipping invalid URL: $bad" "WARN" }

    $total = @($siteUrls).Count
    if ($total -eq 0) { throw "No valid site URLs found in $CsvPath." }
    Write-Log "$total unique, valid site URL(s) loaded from CSV."

#endregion ==================================================================

#region ===================== MAIN PROCESSING ===============================

    Connect-SPOAppOnly

    # Check the tenant-level guest expiration setting the sites will fall back to
    $tenant = Invoke-WithRetry -OperationName "Get-SPOTenant" -ScriptBlock { Get-SPOTenant -ErrorAction Stop }
    if ($tenant.ExternalUserExpirationRequired) {
        Write-Log ("Tenant guest expiration is ON ({0} days). After the site override is removed, these sites will follow the tenant policy and guests will still expire after {0} days." -f $tenant.ExternalUserExpireInDays) "WARN"
        Write-Log "To stop guest expiration entirely, the tenant setting must also be turned off (Set-SPOTenant -ExternalUserExpirationRequired `$false)." "WARN"
    }
    else {
        Write-Log "Tenant guest expiration is OFF. After the site override is removed, guests on these sites will not expire."
    }

    $results = New-Object System.Collections.Generic.List[object]
    $i = 0

    foreach ($url in $siteUrls) {
        $i++
        Write-Progress -Activity "Disabling guest expiration" -Status "$i of ${total}: $url" -PercentComplete (($i / $total) * 100)

        $record = [ordered]@{
            SiteUrl            = $url
            Status             = ""
            PreviousOverride   = ""
            PreviousDays       = ""
            NewOverride        = ""
            TenantPolicyApplies= [bool]$tenant.ExternalUserExpirationRequired
            SharingCapability  = ""
            Message            = ""
            Timestamp          = (Get-Date -Format "s")
        }

        try {
            # 1. Read current state
            $site = Invoke-WithRetry -OperationName "Get-SPOSite $url" -ScriptBlock {
                Get-SPOSite -Identity $url -ErrorAction Stop
            }
            $record.PreviousOverride  = $site.OverrideTenantExternalUserExpirationPolicy
            $record.PreviousDays      = $site.ExternalUserExpirationInDays
            $record.SharingCapability = $site.SharingCapability

            # 2. Skip if the site-level override is already off
            if ($SkipIfAlreadyDisabled -and $site.OverrideTenantExternalUserExpirationPolicy -ne $true) {
                $record.Status  = "Skipped"
                $record.Message = "Site-level guest expiration override already disabled"
                Write-Log "[$i/$total] $url - site-level guest expiration already disabled. Skipped."
            }
            elseif ($WhatIfMode) {
                $record.Status  = "WhatIf"
                $record.Message = "Would set override=False (was $($site.ExternalUserExpirationInDays) days)"
                Write-Log "[$i/$total] $url - WHATIF: would disable site guest expiration (currently $($site.ExternalUserExpirationInDays) days)." "WARN"
            }
            else {
                # 3. Remove the site-level guest expiration override
                Invoke-WithRetry -OperationName "Set-SPOSite $url" -ScriptBlock {
                    Set-SPOSite -Identity $url `
                                -OverrideTenantExternalUserExpirationPolicy $false `
                                -ErrorAction Stop
                } | Out-Null

                # 4. Verify
                Start-Pacing
                $verify = Invoke-WithRetry -OperationName "Verify $url" -ScriptBlock {
                    Get-SPOSite -Identity $url -ErrorAction Stop
                }
                $record.NewOverride = $verify.OverrideTenantExternalUserExpirationPolicy

                if ($verify.OverrideTenantExternalUserExpirationPolicy -ne $true) {
                    $record.Status  = "Success"
                    $record.Message = if ($tenant.ExternalUserExpirationRequired) {
                        "Site override disabled; tenant policy ($($tenant.ExternalUserExpireInDays) days) now applies"
                    } else { "Guest expiration disabled" }
                    Write-Log "[$i/$total] $url - site guest expiration disabled." "SUCCESS"
                }
                else {
                    $record.Status  = "Warning"
                    $record.Message = "Set completed but verification did not match"
                    Write-Log "[$i/$total] $url - set completed but verification did not match." "WARN"
                }
            }
        }
        catch {
            $record.Status  = "Failed"
            $record.Message = $_.Exception.Message
            Write-Log "[$i/$total] $url - FAILED: $($_.Exception.Message)" "ERROR"
        }

        $results.Add([pscustomobject]$record)

        # Save progress after every site so nothing is lost if the run stops
        $results | Export-Csv -Path $resultsPath -NoTypeInformation -Encoding UTF8

        # Throttling safeguards: pace every call, cool down after each batch
        if ($i -lt $total) {
            if ($i % $BatchSize -eq 0) {
                Write-Log "Batch of $BatchSize complete. Cooling down for $BatchPauseSeconds s to avoid throttling..."
                Start-Sleep -Seconds $BatchPauseSeconds
            }
            else {
                Start-Pacing
            }
        }
    }

    Write-Progress -Activity "Disabling guest expiration" -Completed

#endregion ==================================================================

#region ===================== SUMMARY =======================================

    $summary = $results | Group-Object Status | Select-Object Name, Count
    Write-Log "===== Summary ====="
    $summary | ForEach-Object { Write-Log ("{0,-10}: {1}" -f $_.Name, $_.Count) }
    Write-Log "Results saved to: $resultsPath"
}
catch {
    Write-Log "Script stopped: $($_.Exception.Message)" "ERROR"
}
finally {
    try { Disconnect-SPOService -ErrorAction SilentlyContinue } catch { }
    Write-Log "Transcript saved to: $logPath"
    Stop-Transcript | Out-Null
}

#endregion ==================================================================
