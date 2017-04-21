param([string]$Subdomain="nuget", [string]$SiteName = "NuGet Gallery", [string]$SitePhysicalPath, [string]$AppCmdPath)

function Get-SiteFQDN() {return "$Subdomain.localtest.me"}
function Get-SiteHttpHost() {return "$(Get-SiteFQDN):80"}
function Get-SiteHttpsHost() {return "$(Get-SiteFQDN):443"}

function Get-SiteCertificate([string] $Store, [switch] $UseLocalMachine) {
    [string] $level = if($UseLocalMachine) {'LocalMachine'} else {'CurrentUser'}
    return @(dir -l "Cert:\$level\$Store" | where {$_.Subject -eq "CN=$(Get-SiteFQDN)"})
}

function Initialize-SiteCertificate() {
    Write-Host "Generating a Self-Signed SSL Certificate for $(Get-SiteFQDN)"

    # Create a new self-signed certificate. New-SelfSignedCertificate can only create
    # certificates into the My certificate store.
    $myCert = New-SelfSignedCertificate -DnsName $(Get-SiteFQDN) -CertStoreLocation "Cert:\LocalMachine\My"
    
    # Move the newly created self-signed certificate to the Root store.
    $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $rootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    $rootStore.Add($myCert)
    $rootStore.Close()

    $cert = Get-SiteCertificate "Root" -UseLocalMachine

    if($cert -eq $null) {
        throw "Failed to create an SSL Certificate"
    }

    return $cert
}

function Invoke-Netsh() {
    $argStr = $([String]::Join(" ", $args))
    Write-Verbose "netsh $argStr"
    $result = netsh @args
    $parsed = [Regex]::Match($result, ".*Error: (\d+).*")
    if($parsed.Success) {
        $err = $parsed.Groups[1].Value
        if($err -ne "183") {
            throw $result
        }
    } else {
        Write-Host $result
    }
}

if(!(([Security.Principal.WindowsPrincipal]([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator"))) {
    throw "This script must be run as an admin."
}

if(!$SitePhysicalPath) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path;
    $SitePhysicalPath = Join-Path $ScriptRoot "..\src\NuGetGallery"
}
if(!(Test-Path $SitePhysicalPath)) {
    throw "Could not find site at $SitePhysicalPath. Use -SitePhysicalPath argument to specify the path."
}
$SitePhysicalPath = Convert-Path $SitePhysicalPath

# Check for a cert
$siteCert = Get-SiteCertificate -Store 'Root'
if($siteCert.Length -eq 0) {
    $siteCert = Get-SiteCertificate -Store 'Root' -UseLocalMachine
}

# Find IIS Express
if(!$AppCmdPath) {
    $IISXVersion = dir 'HKLM:\Software\Microsoft\IISExpress' | 
        foreach { New-Object System.Version ($_.PSChildName) } |
        sort -desc |
        select -first 1
    if(!$IISXVersion) {
        throw "Could not find IIS Express. Please install IIS Express before running this script, or use -AppCmdPath to specify the path to appcmd.exe for your IIS environment"
    }
    $IISRegKey = (Get-ItemProperty "HKLM:\Software\Microsoft\IISExpress\$IISXVersion")
    $IISExpressDir = $IISRegKey.InstallPath
    if(!(Test-Path $IISExpressDir)) {
        throw "Can't find IIS Express in $IISExpressDir. Please install IIS Express"
    }
    $AppCmdPath = "$IISExpressDir\appcmd.exe"
}

if(!(Test-Path $AppCmdPath)) {
    throw "Could not find appcmd.exe in $AppCmdPath!"
}

# Enable access to the necessary URLs
# S-1-1-0 is the unlocalized version for: user=Everyone 
Invoke-Netsh http add urlacl "url=http://$(Get-SiteHttpHost)/" "sddl=D:(A;;GX;;;S-1-1-0)"
Invoke-Netsh http add urlacl "url=https://$(Get-SiteHttpsHost)/" "sddl=D:(A;;GX;;;S-1-1-0)"

$SiteFullName = "$SiteName ($(Get-SiteFQDN))"
echo $AppCmdPath list site $SiteFullName
$sites = @(&$AppCmdPath list site $SiteFullName)
if($sites.Length -gt 0) {
    Write-Warning "Site '$SiteFullName' already exists. Deleting and recreating."
    &$AppCmdPath delete site "$SiteFullName"
}

&$AppCmdPath add site /name:"$SiteFullName" /bindings:"http://$(Get-SiteHttpHost),https://$(Get-SiteHttpsHost)" /physicalPath:$SitePhysicalPath

if ($siteCert -eq $null) { 
    # Generate one
    $siteCert = Initialize-SiteCertificate
}

Write-Host "Using SSL Certificate: $($siteCert.Thumbprint)"

# Set the Certificate
Invoke-Netsh http add sslcert hostnameport="$(Get-SiteHttpsHost)" certhash="$($siteCert.Thumbprint)" certstorename=Root appid="{$([Guid]::NewGuid().ToString())}"

Write-Host "Ready! All you have to do now is go to your website project properties and set 'http://$(Get-SiteFQDN)' as your Project URL!"
