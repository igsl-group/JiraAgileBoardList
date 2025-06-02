#Requires -Version 7
<#
	.SYNOPSIS 
		Convert from XML to CSV.
		
	.PARAMETER Xml
		XML input file. 
		Remember to check for incomplete close tags if it is not the complete file.
		e.g. Regex replace (?<!/)> with /> and then add a root tag before and after.
		
	.PARAMETER XPath
		XPath to run on XML file.
		
	.PARAMETER Cols
		List of CSV column names.
		
	.PARAMETER Props
		List of XML properties corresponding to the CSV column names.

	.PARAMETER Csv
		Output CSV path. If not specified, defaults to ${Xml}.csv.
#>
Param(
	[Parameter(Mandatory)]
	[string] $Xml,
	
	[Parameter(Mandatory)]
	[string] $XPath,
	
	[Parameter(Mandatory)]
	[string[]] $Cols,
	
	[Parameter(Mandatory)]
	[string[]] $Props,
	
	[Parameter()]
	[string] $Csv
)

# Sanity check
if ($Props.Length -ne $Cols.Length) {
	Write-Host '$Props and $Cols must match in size'
	Exit
}

if (-not $Csv) {
	$Csv = $Xml + '.csv'
}
Clear-Content -Path $Csv

[xml] $XmlData = Get-Content -Path $Xml -Raw
$NodeList = Select-Xml -Xml $XmlData -XPath $XPath
foreach ($Node in $NodeList) {
	$Obj = $Node | Select-Object -Expand Node
	$Row = [ordered]@{}
	for ($idx = 0; $idx -lt $Cols.Length; $idx++) {
		$ColName = $Cols[$idx]
		$Prop = $Props[$idx]
		if ($Obj.$Prop) {
			$Row[$ColName] = $Obj.$Prop
		} else {
			$Row[$ColName] = ''
		}
	}
	Write-Host 'Row: ' $Row
	Export-Csv -NoTypeInformation -Path $Csv -InputObject $Row -Append 
}
