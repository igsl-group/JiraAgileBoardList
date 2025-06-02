#Requires -Version 7
<#
	.SYNOPSIS 
		Exports list of agile boards from Jira Cloud.
		
	.PARAMETER Domain
		Jira Cloud domain, e.g. consoleconnect-sandbox-824.atlassian.net
		
	.PARAMETER Email
		User email.
		
	.PARAMETER Token
		API token.
		
	.PARAMETER Protocol
		https or http. Default https.
		
	.PARAMETER Csv
		Output CSV path. Default AgileBoardList.[Timestamp].csv.
#>
Param(
	[Parameter(Mandatory)]
	[string] $Domain,
	
	[string] $Protocol = 'https',
	
	[Parameter(Mandatory)]
	[string] $Email,
	
	[string] $Token = "",
	
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

function GetAgileBoards {
	Param (
		[hashtable] $Headers
	)
	$Result = [System.Collections.ArrayList]::new()
	$Json = $null
	$page = 0
	$cnt = 0
	Write-Host 'Listing agile boards...'
	do {
		$pageSize = 0
		$Body = @{
			'expand' = 'admins,permissions';
			'includePrivate' = 'true';
			'startAt' = $page;
		}
		$Uri = $Protocol + '://' + $Domain + '/rest/agile/1.0/board'
		$Response = WebRequest $Uri 'GET' $Headers $Body
		$Json = $Response.Content | ConvertFrom-Json
		foreach ($Item in $Json.values) {
			[void] $Result.Add($Item)
			Write-Host "Found board #${cnt} :" $Item.name '(' $Item.id ')'
			$cnt += 1
			$pageSize += 1
		}
		$page += $pageSize
	} while (-not $Json.isLast)	
	Write-Host "Found ${cnt} agile board(s)"
	$Result
}

function GetAgileBoardProjects {
	Param (
		[hashtable] $Headers,
		[PSObject] $Board
	)
	$Result = [System.Collections.ArrayList]::new()
	$Json = $null
	$page = 0
	$cnt = 0
	do {
		$pageSize = 0
		$Body = @{
			'startAt' = $page;
		}
		$Uri = $Protocol + '://' + $Domain + '/rest/agile/1.0/board/' + $Board.id + '/project'
		$Response = WebRequest $Uri 'GET' $Headers $Body
		if ($Response.StatusCode -eq 200) {
			$Json = $Response.Content | ConvertFrom-Json
			foreach ($Item in $Json.values) {
				[void] $Result.Add($Item)
				$pageSize += 1
			}
			$page += $pageSize
		} else {
			break
		}
	} while (-not $Json.isLast)
	Write-Host "Found" $Result.Count "project(s) associated with" $Board.name '=' $Board.id
	$Result
}

function GetFilter {
	Param (
		[hashtable] $Headers,
		[string] $FilterId
	)
	$Body = @{
		'overrideSharePermissions' = 'true';
	}
	$Uri = $Protocol + '://' + $Domain + '/rest/api/latest/filter/' + $FilterId
	$Json = $Null
	$Response = WebRequest $Uri 'GET' $Headers $Body
	if ($Response.StatusCode -eq 200) {
		$Json = $Response.Content | ConvertFrom-Json
		Write-Host 'Filter name: ' $Json.name
		Write-Host 'Filter JQL: ' $Json.jql
	}
	$Json
}

function GetAgileBoardFilter {
	Param (
		[hashtable] $Headers,
		[PSObject] $Board
	)
	$Result = $Null
	$Body = @{}
	$Uri = $Protocol + '://' + $Domain + '/rest/agile/1.0/board/' + $Board.id + '/configuration'
	$Response = WebRequest $Uri 'GET' $Headers $Body
	if ($Response.StatusCode -eq 200) {
		$Json = $Response.Content | ConvertFrom-Json
		if ($Json.filter) {
			Write-Host 'Found filter ' $Json.filter.id
			$Result = GetFilter $Headers $Json.filter.id
		}
	}
	$Result
}

# Main body
if (-not $Token) {
	$pwd = Read-Host "Enter API Token" -AsSecureString
	$Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
}
$AuthHeader = GetAuthHeader $Email $Token

if (-not $Csv) {
	$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'
	$Csv = 'AgileBoardList.' + $Timestamp + '.csv'
}	

$AgileBoardMap = GetAgileBoards $AuthHeader

foreach ($Board in $AgileBoardMap) {
	$Item = [ordered] @{}
	$Item['Board ID'] = $Board.id
	$Item['Board Name'] = $Board.name
	$Item['Board Type'] = $Board.type
	if ($Board.isPrivate) {
		$Item['Private'] = 'Y'
	} else {
		$Item['Private'] = 'N'
	}
	
	# Location, could be user or project
	if ($Board.location.userId) {
		$Item['Location'] = 'User: ' + $Board.location.displayName + ' (' + $Board.location.userAccountId + ')'
	} elseif ($Board.location.projectId) {
		$Item['Location'] = 'Project: ' + $Board.location.displayName
	} else {
		$Item['Location'] = ''
	}
	
	# Admin list
	$AdminList = ''
	foreach ($Admin in $Board.admins.users) {
		$MatchInfo = $Admin.self | Select-String -Pattern '^.+\?accountId=(.+)$'
		$AccountId = $MatchInfo.Matches.Groups[1].Value
		$AdminList += "`nUser: " + $Admin.displayName + ' (' + $AccountId + ')'
	}
	foreach ($Group in $Board.admins.groups) {
		$AdminList += "`nGroup: " + $Group.name
	}
	if ($AdminList) {
		$Item['Administrators'] = $AdminList.SubString(1)
	} else {
		$Item['Administrators'] = ''
	}
	
	# Project list
	$ProjectMap = GetAgileBoardProjects $AuthHeader $Board
	$ProjectList = ''
	$ProjectCount = 0
	foreach($Project in $ProjectMap) {
		$ProjectList += "`n" + $Project.name + ' (' + $Project.key + ') Type: ' + $Project.projectTypeKey
		$ProjectCount++
	}
	if ($ProjectList) {
		$Item['Project List'] = $ProjectList.SubString(1)
	} else {
		$Item['Project List'] = ''
	}
	$Item['Project Count'] = $ProjectCount
	
	# Filter
	$Filter = GetAgileBoardFilter $AuthHeader $Board
	if ($Filter) {
		$Item['Filter ID'] = $Filter.id
		$Item['Filter Name'] = $Filter.name
		$Item['Filter Owner'] = $Filter.owner.displayName + ' (' + $Filter.owner.accountId + ')'
		$Item['Filter JQL'] = $Filter.jql
	} else {
		$Item['Filter ID'] = ''
		$Item['Filter Name'] = ''
		$Item['Filter Owner'] = ''
		$Item['Filter JQL'] = ''
	}
	
	# Output to CSV
	$NewRow = New-Object PsObject -Property $Item
	Export-Csv $Csv -NoTypeInformation -InputObject $NewRow -Append
}