#Requires -Version 7
<#
	.SYNOPSIS 
		Exports list of project roles from jira cloud.
		
	.PARAMETER Domain
		Jira cloud domain, e.g. kcwong.atlassian.net
		
	.PARAMETER Email
		Email address.
		
	.PARAMETER APIToken
		API token.
		
	.PARAMETER Protocol
		https or http. Default https.
		
	.PARAMETER Csv
		Output CSV path. Default CloudUserList.[Timestamp].csv.
#>
Param(
	[Parameter(Mandatory)]
	[string] $Domain,
	
	[string] $Protocol = 'https',
	
	[Parameter(Mandatory)]
	[string] $User,
	
	[string] $Password = "",
	
	[string] $Csv = ""
)

class RestException : Exception {
    RestException($Message) : base($Message) {
    }
}

function GetAuthHeader {
	Param (
		[string] $Email,
		[string] $Token
	)
	[hashtable] $Headers = @{
		"Content-Type" = "application/json"
	}
	$Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($Email + ":" + $Token))
	$Headers.Authorization = "Basic " + $Auth
	$Headers
}

# Call Invoke-WebRequest without throwing exception on 4xx/5xx 
function WebRequest {
	Param (
		[string] $Uri,
		[string] $Method,
		[hashtable] $Headers,
		[object] $Body
	)
	$Response = $null
	try {
		$script:ProgressPreference = 'SilentlyContinue'    # Subsequent calls do not display UI.
		$Response = Invoke-WebRequest -Method $Method -Header $Headers -Uri $Uri -Body $Body
	} catch {
		$Response = @{}
		$Response.StatusCode = $_.Exception.Response.StatusCode.value__
		$Response.content = $_.Exception.Message
	} finally {
		$script:ProgressPreference = 'Continue'            # Subsequent calls do display UI.
	}
	$Response
}

function GetRoles {
	Param (
		[hashtable] $Headers
	)
	$Result = [System.Collections.ArrayList]::new()
	$Json = $null
	$page = 0
	$cnt = 0
	$pageSize = 0
	Write-Host 'Listing roles...'
	$pageSize = 0
	$Body = @{}
	$Uri = $Protocol + '://' + $Domain + '/rest/api/latest/role'
	$Response = WebRequest $Uri 'GET' $Headers $Body
	$Json = $Response.Content | ConvertFrom-Json
	foreach ($Item in $Json) {
		[void] $Result.Add($Item)
		Write-Host "Found role #${cnt} :" $Item.name '(' $Item.id ')'
		$cnt += 1
	}
	Write-Host "Found ${cnt} role(s)"
	$Result
}

# Main body
if (-not $Password) {
	$pwd = Read-Host "Enter password" -AsSecureString
	$Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
}
$AuthHeader = GetAuthHeader $User $Password

if (-not $Csv) {
	$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'
	$Csv = 'CloudRoleList.' + $Timestamp + '.csv'
}	

$UserList = GetRoles $AuthHeader

foreach ($UserObj in $UserList) {
	$Item = [ordered] @{}
	$Item['Id'] = $UserObj.id
	$Item['Name'] = $UserObj.name
	
	# Output to CSV
	$NewRow = New-Object PsObject -Property $Item
	Export-Csv $Csv -NoTypeInformation -InputObject $NewRow -Append
}