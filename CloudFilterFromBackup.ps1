<#
	.SYNOPSIS 
		Filter reconstruction from Jira Cloud backup.
		
	.PARAMETER Domain
		Jira cloud domain, e.g. kcwong.atlassian.net
		
	.PARAMETER Email
		Email address.
		
	.PARAMETER Token
		API token.
		
	.PARAMETER Protocol
		https or http. Default https.
		
	.PARAMETER FilterCsv
		CSV file containing filters to reconstruct. 
		Must contain the following columns: 
			id - A reference ID between CSV files, not filter Id in Jira.
			name - Name of filter.
			jql - JQL.
			owner - Account ID of filter owner.

	.PARAMETER PermissionCsv
		CSV file containing filter permissions. 
		Must contain the following columns: 
			id - A reference ID between CSV files, not filter Id in Jira.
			type - One of the following: loggedin, project, group, user
			rights - One of the following: 1 (View), 2 (Edit), 3 (View and Edit). 2 is never used in Jira.
			param1 - When type is:
				project - project id. Use /rest/api/latest/project/[ProjectKey] to retrieve project id.
				group - group NAME. Group names can be found in https://admin.atlassian.com/
				user - account id. Account ids can be found in https://admin.atlassian.com/
			param2 - Project role id when type is project. Null for all roles.
				Use /rest/api/latest/role to get full list of project roles.
		This CSV file is in a many-to-one relationship with FilterCsv.
		Note that if you specify loggedin for a rights, you cannot have other types in the same rights. 
		i.e. If you specify loggedin for view, you cannot have project/user/group for view. But you can have project/user/group for Edit.
		
	.PARAMETER PauseAction
		Switch. If specified, pause after each modification action.
		
	.PARAMETER PauseFilter
		Switch. If specified, pause after processing each filter CSV record.
#>
#Requires -version 7
Param(
	[Parameter(Mandatory)]
	[string] $Domain,
	
	[string] $Protocol = 'https',
	
	[Parameter(Mandatory)]
	[string] $Email,
	
	[string] $Token = '',
	
	[Parameter(Mandatory)]
	[string] $FilterCsv,
	
	[Parameter(Mandatory)]
	[string] $PermissionCsv,
	
	[Parameter()]
	[string] $DataCsv,
	
	[Parameter()]
	[switch] $PauseAction,
	
	[Parameter()]
	[switch] $PauseFilter
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
		"Content-Type" = "application/json";
		"Accept" = "application/json";
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
		$Response = Invoke-WebRequest -SkipHttpErrorCheck -Method $Method -Header $Headers -Uri $Uri -Body $Body
	} finally {
		$script:ProgressPreference = 'Continue'            # Subsequent calls do display UI.
	}
	$Response
}

function GetFilterId {
	Param (
		[hashtable] $Headers,
		[boolean] $OverrideSharePermissions,
		[string] $Name,
		[string] $Owner
	)
	$Result = $Null
	$Json = $null
	$Body = @{
		'overrideSharePermissions' = $OverrideSharePermissions;
		'expand' = 'owner,jql,sharePermissions,editPermissions';
		'filterName' = '"' + $Name + '"';
		'accountId' = $Owner;
		'startAt' = 0;
	}
	$Uri = $Protocol + '://' + $Domain + '/rest/api/latest/filter/search'
	$Response = WebRequest $Uri 'GET' $Headers $Body
	$Json = $Response.Content | ConvertFrom-Json
	if ($Json.values.Count -eq 1) {
		$Result = $Json.values[0].id
	}
	$Result
}

function GetFilterDependencies {
	Param(
		[string] $Jql
	)
	$Result = [System.Collections.ArrayList]::new()
	$MatchInfo = Select-String '\s*filter\s*=\s*"([^"]+)"\s*' -Input $Jql -AllMatches
	foreach ($Match in $MatchInfo.Matches) {
		[void] $Result.Add($Match.Groups[1])
	}
	$Result
}

function CreateFilter {
	Param (
		[hashtable] $Header,
		[string] $Name,
		[string] $Jql,
		[PSObject] $Permissions
	)
	$Result = $Null
	$Json = $null
	$Body = @{
		'name' = $Name;
		'jql' = $Jql;
	}
	if ($Permissions) {
		$Body['sharePermissions'] = $Permissions.sharePermissions
		$Body['editPermissions'] = $Permissions.editPermissions
	}
	$Uri = $Protocol + '://' + $Domain + '/rest/api/latest/filter'
	$Response = WebRequest $Uri 'POST' $Header ($Body | ConvertTo-Json -Depth 100)
	if ($Response.StatusCode -eq 200) {
		$Json = $Response.Content | ConvertFrom-Json
		$Result = $Json.id
	} else {
		throw $Response.Content
	}
	$Result
}

function DeleteFilter {
	Param (
		[hashtable] $Header,
		[string] $Id
	)
	$Body = @{
	}
	$Uri = $Protocol + '://' + $Domain + "/rest/api/latest/filter/${Id}"
	$Response = WebRequest $Uri 'DELETE' $Header $Body
	if ($Response.StatusCode -ne 204) {
		throw $Response.Content
	}
}

function ChangeFilterOwner {
	Param (
		[hashtable] $Header,
		[string] $Id,
		[string] $Owner
	)
	$Result = $False
	$Body = @{
		'accountId' = $Owner;
	}
	$Uri = $Protocol + '://' + $Domain + "/rest/api/latest/filter/${Id}/owner"
	$Response = WebRequest $Uri 'PUT' $Header ($Body | ConvertTo-Json -Depth 100)
	if ($Response.StatusCode -ne 204) {
		throw $Response.Content
	}
}

# Convert SearchRequest into a map. Key is filter id, value is object providing name, jql and owner
function ReadSearchRequest {
	Param (
		[string] $Path
	)
	$Result = [ordered]@{}
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
		$id = $Item.id
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
		switch ($Item.type) {
			'group' {
				$Data.type = 'group'
				$Data.group = @{
					'name' = $Item.param1
				}
				break
			}
			'project' {
				$Data.type = 'project'
				$Data.project = @{
					'id' = $Item.param1
				}
				if ($Item.param2) {
					$Data.type = 'projectRole'
					$Data.role = @{
						'id' = $Item.param2
					}
				}
				break
			}
			'user' {
				$Data.type = 'user'
				$Data.user = @{
					'accountId' = $Item.param1
				}
				break
			}
			'loggedin' {				
				$Data.type = 'authenticated'	# Must be authenticated in request, not loggedin as they give you
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
		$Result[$Id] = $Payload
	}
	$Result
}

# Helper. Append message to $Data['Messages'] (with newline) and write to console (with indent).
function Log {
	Param (
		[System.Collections.Specialized.OrderedDictionary] $Data, 
		[string] $Msg
	)
	Write-Host "`t${Msg}"
	$Data['Messages'] += $Msg + "`n"
	$Data
}

function PausePrompt {
	Param (
		[string] $Msg
	)
	if ($Msg) {
		Write-Host "`t${Msg}"
	}
	Write-Host "`t`tEnter to continue / Ctrl-C to exit" -NoNewline
	$Null = $Host.UI.ReadLine()
}

# Main body
if (-not $Token) {
	$pwd = Read-Host "Enter API token" -AsSecureString
	$Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))
}
$AuthHeader = GetAuthHeader $Email $Token
$DataCsv = 'CloudFilterFromBackup.' + (Get-Date -Format 'yyyyMMddHHmmss') + '.csv'

$FilterData = ReadSearchRequest $FilterCsv
$PermissionData = ReadSharePermission $PermissionCsv

foreach ($Filter in $FilterData.GetEnumerator()) {
	$BackupId = $Filter.Value.id
	$Name = $Filter.Value.name
	$Jql = $Filter.Value.jql
	$Owner = $Filter.Value.owner
	$Permission = $PermissionData[$BackupId]
	$View = 'None'
	$Edit = 'None'
	if ($Permission) {
		$View = ($Permission.sharePermissions | ConvertTo-Json -Compress -Depth 100)
		$Edit = ($Permission.editPermissions | ConvertTo-Json -Compress -Depth 100)
	}
	$Data = [ordered]@{}	
	$Data['BackupId'] = $BackupId
	$Data['CurrentId'] = ''
	$Data['Name'] = $Name
	$Data['Jql'] = $Jql
	$Data['Owner'] = $Owner
	$Data['Create'] = ''
	$Data['ChangeOwner'] = ''
	$Data['Messages'] = ''
	Write-Host "Processing filter Id: ${BackupId} Name: ${Name} JQL: ${Jql} Owner: ${Owner} View: ${View} Edit: ${Edit}"
	$Id = GetFilterId $AuthHeader $True $Name $Owner
	if (-not $Id) {
		$Data = Log $Data "Filter does not exist, recreating..."
		if ($PauseAction) { PausePrompt }
		$Error = $False
		$DummyFilterList = [System.Collections.ArrayList]::new()
		$DependencyList = GetFilterDependencies $Jql
		foreach ($Dependency in $DependencyList) {
			$Data = Log $Data "Filter depends on filter ${Dependency}"
			if (-not (GetFilterId $AuthHeader $False $Dependency)) {
				$Data = Log $Data "Dependency filter ${Dependency} is inaccessible, creating dummy..."
				if ($PauseAction) { PausePrompt }
				try {
					$DummyId = CreateFilter $AuthHeader $Dependency 'order by created asc'
					[void] $DummyFilterList.Add($DummyId)
					$Data = Log $Data "Dependency filter ${Dependency} created: ${DummyId}"
					if ($PauseAction) { PausePrompt }
				} catch {
					$Data = Log $Data ("Failed to create dummy filter ${Dependency}" + $_.ToString())
					if ($PauseAction) { PausePrompt }
					$Error = $True
					break
				}
			} else {
				$Data = Log $Data "Dependency filter ${Dependency} exists and is accessible"
				if ($PauseAction) { PausePrompt }
			}
		}
		if (-not $Error) {
			try {
				$Data = Log $Data "Creating filter..."
				$Id = CreateFilter $AuthHeader $Name $Jql $Permission
				$Data = Log $Data "Created filter: ${Id}"
				$Data['CurrentId'] = $Id
				$Data['Create'] = 'Success'
				if ($PauseAction) { PausePrompt }
				try {
					$Data = Log $Data "Changing owner..."
					ChangeFilterOwner $AuthHeader $Id $Owner
					$Data = Log $Data "Owner changed"
					$Data['ChangeOwner'] = 'Success'
				} catch {
					$Data = Log $Data ("Failed to change owner: " + $_.ToString())
					$Data['ChangeOwner'] = 'Failed'
					$Data['Messages'] += $_.ToString() + ';'
				}
				if ($PauseAction) { PausePrompt }
			} catch {
				$Data = Log $Data ("Failed to create filter: " + $_.ToString())
				$Data['Create'] = 'Failed'
				$Data['Messages'] += $_.ToString() + ';'
				if ($PauseAction) { PausePrompt }
			}
		}
		foreach ($DummyId in $DummyFilterList) {
			$Data = Log $Data "Deleting dummy filter: ${DummyId}"
			if ($PauseAction) { PausePrompt }
			try {
				DeleteFilter $AuthHeader $DummyId
				$Data = Log $Data "Deleted dummy filter: ${DummyId}"
			} catch {
				$Data = Log $Data ("Failed to delete dummy filter ${DummyId}: " + $_.ToString())
			}
			if ($PauseAction) { PausePrompt }
		}
	} else {
		$Data = Log $Data "Filter already exists"
		$Data['CurrentId'] = $Id
		$Data['Create'] = 'Filter already exists'
		if ($PauseAction) { PausePrompt }
	}
	$NewRow = New-Object PsObject -Property $Data
	Export-Csv -NoTypeInformation -Path $DataCsv -InputObject $NewRow -Append
	if ($PauseFilter) {
		PausePrompt 'Filter processed'
	}
}