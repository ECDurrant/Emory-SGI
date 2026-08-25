<#
.SYNOPSIS
  Mints a fresh Okta bearer token and fires a live GET rates call against one of
  Safe-Guard's OEM rating APIs (VCI/HCI/BMW/Lithia/GM), for Emory's live-fire
  verification step (Check 5 - "API-computed rates" platforms).

.DESCRIPTION
  Token + rates call happen in ONE script invocation because PowerShell shell state
  (including a minted token) does not persist across separate tool calls in this
  environment. Credentials are read from secrets.json next to this script - never
  hardcode them in a call site or paste them into a chat/Teams message.

.PARAMETER Vendor
  One of: VCI_PROD, VCI_UAT, HCI, BMW, LITHIA_PROD, LITHIA_UAT, GM_PROD, GM_UAT
  (must match a top-level key in secrets.json).

.PARAMETER QueryParams
  Hashtable of query-string params for the rates call, e.g.
  @{ saleDate='2026-08-12'; sellerId='AU407A20'; vin='WAU65CFN7TN044730';
     odometer=1; financeType='FINANCE'; vehicleCondition='New'; ... }
  vendorName and channel are filled in from secrets.json's vendorName/defaultChannel
  unless you explicitly include them here to override.

.EXAMPLE
  .\Invoke-EmoryLiveRate.ps1 -Vendor VCI_PROD -QueryParams @{
    saleDate='2026-08-12'; sellerId='AU407A20'; vin='WAU65CFN7TN044730'
    odometer=1; inServiceDate='2026-08-12'; languageCode='en_US'
    financeType='FINANCE'; financeAmount=87722.21; financeTerm=999
    vehicleCondition='New'; vehicleUsage='PERSONAL'; customerState=''
    isAfterSale='FALSE'; vehiclePurchaseDate='2026-08-12'
    vehicleMSRP=77370; vehiclePurchasePrice=77370
  }
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('VCI_PROD','VCI_UAT','HCI','BMW','LITHIA_PROD','LITHIA_UAT','GM_PROD','GM_UAT')]
    [string]$Vendor,

    [Parameter(Mandatory = $true)]
    [hashtable]$QueryParams
)

$ErrorActionPreference = 'Stop'

$secretsPath = Join-Path $PSScriptRoot 'secrets.json'
if (-not (Test-Path $secretsPath)) {
    throw "secrets.json not found at $secretsPath - run the credential-extraction step first."
}
$allSecrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
$cfg = $allSecrets.$Vendor
if (-not $cfg) {
    throw "No config found for vendor '$Vendor' in secrets.json."
}

# --- 1. Mint a fresh bearer token (Okta client_credentials, HTTP Basic auth) ---
$tokenBody = @{
    grant_type = $(if ($cfg.grantType) { $cfg.grantType } else { 'client_credentials' })
}
if ($cfg.scope) { $tokenBody.scope = $cfg.scope }

$basicPair  = "$($cfg.clientId):$($cfg.clientSecret)"
$basicBytes = [System.Text.Encoding]::ASCII.GetBytes($basicPair)
$basicAuth  = [System.Convert]::ToBase64String($basicBytes)

try {
    $tokenResp = Invoke-RestMethod -UseBasicParsing -Method Post -Uri $cfg.tokenUrl `
        -Headers @{ Authorization = "Basic $basicAuth"; Accept = 'application/json' } `
        -Body $tokenBody -ContentType 'application/x-www-form-urlencoded'
}
catch {
    Write-Error "Token mint failed for $Vendor against $($cfg.tokenUrl): $($_.Exception.Message)"
    throw
}

$accessToken = $tokenResp.access_token
if (-not $accessToken) {
    throw "Token endpoint responded but no access_token field was present. Raw response: $($tokenResp | ConvertTo-Json -Compress)"
}

# --- 1b. Decode the JWT locally (structural sanity check - exp/scope/client, no network call) ---
function ConvertFrom-Base64Url {
    param([string]$Value)
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
    }
    [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded))
}

$jwtParts = $accessToken.Split('.')
if ($jwtParts.Count -eq 3) {
    try {
        $claims = ConvertFrom-Base64Url $jwtParts[1] | ConvertFrom-Json
        $expUtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$claims.exp).UtcDateTime
        Write-Host "Token decoded OK - cid=$($claims.cid) scope=$($claims.scp -join ',') expires=$expUtc UTC"
        if ($expUtc -lt (Get-Date).ToUniversalTime()) {
            throw "Minted token's exp claim ($expUtc UTC) is already in the past - Okta clock skew or a stale cached response."
        }
    }
    catch {
        Write-Error "Token decoded but failed the local sanity check: $($_.Exception.Message)"
        throw
    }
}
else {
    Write-Host "Access token is not a 3-part JWT (opaque token) - skipping local decode, relying on introspection only."
}

# --- 1c. Authorize the token with Okta before use (RFC 7662 introspection - the authoritative check) ---
# Same host as the token endpoint, /v1/token -> /v1/introspect.
$introspectUrl = $cfg.tokenUrl -replace '/v1/token$', '/v1/introspect'
try {
    $introspectResp = Invoke-RestMethod -UseBasicParsing -Method Post -Uri $introspectUrl `
        -Headers @{ Authorization = "Basic $basicAuth"; Accept = 'application/json' } `
        -Body @{ token = $accessToken; token_type_hint = 'access_token' } `
        -ContentType 'application/x-www-form-urlencoded'
}
catch {
    Write-Error "Introspection call itself failed against $introspectUrl - $($_.Exception.Message). Proceeding is unsafe; not calling the rates endpoint."
    throw
}

if (-not $introspectResp.active) {
    throw "Okta reports this token is NOT active (introspection returned active=$($introspectResp.active)) - refusing to use it against the rates endpoint. Check client_id/secret/scope in secrets.json for '$Vendor'."
}
Write-Host "Token authorized by Okta introspection - active=true, scope=$($introspectResp.scope)"

# --- 2. Build the rates query string (vendorName/channel default from config, overridable) ---
$finalParams = @{}
if ($cfg.vendorName)     { $finalParams['vendorName'] = $cfg.vendorName }
if ($cfg.defaultChannel) { $finalParams['channel']    = $cfg.defaultChannel }
foreach ($key in $QueryParams.Keys) { $finalParams[$key] = $QueryParams[$key] }

$queryString = ($finalParams.GetEnumerator() | ForEach-Object {
    "$([uri]::EscapeDataString($_.Key))=$([uri]::EscapeDataString([string]$_.Value))"
}) -join '&'

$ratesUrl = "$($cfg.ratesBaseUrl)?$queryString"

# --- 3. Fire the live rates call ---
try {
    $ratesResp = Invoke-RestMethod -UseBasicParsing -Method Get -Uri $ratesUrl `
        -Headers @{ Authorization = "Bearer $accessToken"; Accept = 'application/json' }
}
catch {
    $status = $null
    if ($_.Exception.Response) { $status = $_.Exception.Response.StatusCode.value__ }
    Write-Host "Request URL was: $ratesUrl"
    throw "Rates call failed for $Vendor (HTTP $status): $($_.Exception.Message)"
}

[PSCustomObject]@{
    Vendor    = $Vendor
    Url       = $ratesUrl
    Response  = $ratesResp
} | ConvertTo-Json -Depth 20
