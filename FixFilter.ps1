#Requires -Version 7
<#
	.SYNOPSIS 
		Using reference CSV files (SearchRequest and SharePermission), update filter owner and share/edit permissions on the filter IDs provided.
		
	.PARAMETER Domain
		Jira cloud domain, e.g. kcwong.atlassian.net
		
	.PARAMETER Email
		Email address.
		
	.PARAMETER APIToken
		API token.
		
	.PARAMETER Protocol
		https or http. Default https.
		
	.PARAMETER FilterFile
		File containing filter IDs to process, one per line. 
		Specify either FilterFile or FilterIds.

	.PARAMETER FilterIds
		List of filter IDs to process. 
		Specify either FilterFile or FilterIds.
		
	.PARAMETER SearchRequestCsv
		SearchRequest CSV.
		
		Should contain columns: 
		id 		- Filter id
		name 	- Filter name
		jql 	- Filter JQL
		owner 	- Filter owner account id
		
	.PARAMETER SharePermissionCsv
		SharePermission CSV.
		
		Should contain columns: 
		FilterID	- Filter id
		Type		- Permission type, loggedin/project/group/user
		Rights		- 1/2/3 for view/edit/both
		Param1		- Object id
		Param2		- Project role id if type is project
		
	.PARAMETER Csv
		Result CSV. Default is FixFilter.[Timestamp].csv.
#>
Param(
	[Parameter(Mandatory)]
	[string] $Domain,
	
	[string] $Protocol = 'https',
	
	[Parameter(Mandatory)]
	[string] $User,
	
	[string] $Password = '',
	
	[Parameter()]
	[string] $FilterFile = $null,

	[Parameter()]
	[string[]] $FilterIds = $null,

	[Parameter(Mandatory)]
	[string] $SearchRequestCsv,

	[Parameter(Mandatory)]
	[string] $SharePermissionCsv,
	
	[string] $Csv = ''
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

# Convert SearchRequest into a map. Key is filter id, value is object providing name, jql and owner
function ReadSearchRequest {
	Param (
		[string] $Path
	)
	$Result = @{}
	$List = Import-Csv -Path $Path
	foreach ($Item in $List) {
		$Result[$Item.id] = $Item
	}
	$Result
}

# Convert SharePermission data into a map. Key is filter id, value is filter update payload for the filter
function ReadSharePermission {
	Param (
		[string] $Path
	)
	$Result = @{}
	$List = Import-Csv -Path $Path
	foreach ($Item in $List) {
		$id = $Item.FilterID
		$Payload = $null
		if (-not $Result[$id]) {
			$Payload = @{
				sharePermissions = [System.Collections.ArrayList]::new()
				editPermissions = [System.Collections.ArrayList]::new()
			}
		} else {
			$Payload = $Result[$id]
		}
		# Add item's data to payload
		$Data = @{}
		switch ($Item.Type) {
			'group' {
				$Data.type = 'group'
				$Data.group = $Item.Param1
				break
			}
			'project' {
				$Data.type = 'project'
				$Data.project = $Item.Param1
				if ($Item['Param2']) {
					$Data.type = 'projectRole'
					$Data.role = $Item.Param2
				}
				break
			}
			'user' {
				$Data.type = 'user'
				$Data.user = $Item.Param1
				break
			}
			'loggedin' {				
				$Data.type = 'loggedIn'
				break
			}
			'global' {
				# Global no longer supported, permission dropped
				break
			}
		}
		if ($Data.Count -ne 0) {
			switch ($Item.Rights) {
				'1' {
					[void] $Payload.sharePermissions.Add($Data)
					break;
				}
				'2' {
					# Fall-through
				}
				'3' {
					[void] $Payload.editPermissions.Add($Data)
					break;
				}	
			}
		}
		Write-Host "Filter ${id}"
		$Payload.sharePermissions | Format-Table
		$Payload.editPermissions | Format-Table
		$Result[$Id] = $Payload
	}
	$Result
}

# Main body
$Timestamp = Get-Date -Format 'yyyyMMddHHmmss'
if (-not $Csv) {
	$Csv = "FixFilter.${Timestamp}.csv"
}
# Gather filter ids
$FilterList = [System.Collections.ArrayList]::new()
if ($FilterFile) {
	foreach ($Line in Get-Content $FilterFile) {
		[void] $FilterList.Add($Line)
	}
} else {
	if ($FilterIds) {
		foreach ($Id in $FilterIds) {
			[void] $FilterList.Add($Id.Trim())
		}
	} else {
		$FilterIds = (Read-Host 'Enter filter IDs delimited by comma').Split(',')
		foreach ($Id in $FilterIds) {
			[void] $FilterList.Add($Id.Trim())
		}
	}
}
# Read CSV data
$SearchRequest = ReadSearchRequest $SearchRequestCsv
$SharePermission = ReadSharePermission $SharePermissionCsv
# Process each filter
foreach ($FilterId in $FilterList) {
	Write-Host "Processing ${FilterId}..."
	$Result = [ordered]@{}
	$Result['Filter ID'] = $FilterId
	$Result['Filter Name'] = ''
	$Result['Set Owner'] = ''
	$Result['Set Owner Result'] = ''
	$Result['Set Permission'] = ''
	$Result['Set Permission Result'] = ''
	if (-not $SearchRequest[$FilterId]) {
		$Result['Filter Name'] = 'Filter not found'
	} else {
		$Result['Filter Name'] = $SearchRequest[$FilterId].name
		$Result['Set Owner'] = $SearchRequest[$FilterId].owner
		if ($SharePermission[$FilterId]) {
			$Result['Set Permission'] = ($SharePermission[$FilterId] | ConvertFrom-Json)
		} else {
			$Result['Set Permission'] = ''
		}		
	}
	Export-Csv -NoTypeInformation -Append -Path $Csv -InputObject $Result
}