<#
	.SYNOPSIS
		The script initiates disk volume recovery process (using "diskpart") utility.
	.DESCRIPTION
		The script verifies the disk volumes status. If one of volumes is "Failed", it generates an error message and try to recover the volume.
		The script is made mostly to recover software RAID volumes.
		It was found that Windows 7 does not generate any events when built-in software RAID disk is failed.
		The script waits until rebuilding process has finished. It verifies volume's status periodicly and generates the events.
		If the rebuild has not completed successfully, the error event will be generated.
		All events could monitored by creating a task (e-mail or pop-up message).
		The script uses "diskpart" utility.
		
		You can modify the EventLog parameters by changing the constants.
		
		If you need only to create an event in case of volume's failure, you could use another my script:
		https://github.com/FutureIsHere/PowerShell-Scripts/tree/master/Get-DiskStatus
	.PARAMETER <paramName>
		no input parameters are required
	.EXAMPLE
		You can create a schedulled task, which will call the script several times a day
	.NOTES
		The function is free to use\copy or modify. In case of any issues or requests, feel free to ask me via GitHub
	.LINK
		https://github.com/FutureIsHere
	.LINK
		https://github.com/FutureIsHere/PowerShell-Scripts/tree/master/Fix-FailedVolume
#>
#region CONSTANTS
	$VOLUME_RECHECK_INTERVAL = 600			#in seconds
	$EVENT_SOURCE = "DiskDiagnostic"		#name of the event source. If it does not exist, it will be created
	$EVENT_LOG = "System"
	$EVENT_ID_VOLUME_NOT_HEALTHY = 5566
	$EVENT_ID_VOLUME_HEALTHY = 5570
	$EVENT_ID_VOLUME_RECOVER_SUCCESSFULL = 5567
	$EVENT_ID_VOLUME_RECOVER_FAILED = 5568
	$EVENT_ID_DISK_ERROR_STATUS = 5569	
	$EVENT_ID_VOLUME_REBUILDING = 5571
	$EVENT_ID_VOLUME_NOT_REBUILDING = 5572
	$EVENT_ID_VOLUME_NOT_HEALTHY = 5573
	$EVENT_ID_VOLUME_REBULDING_COMPLETED = 5575
#endregion
#region FUNCTIONS
	Function Run-Diskpart {
		param (
			[Parameter(Position=0,Mandatory=$true) ]
			$DiskpartCommand		#command which will be executed via diskpart (i.e. "list volumes")
		)
	    $DP_UNKNOWN_COMMAND_MESSAGE = "Microsoft DiskPart version"
		try {
			$CommandOutput = ($DiskpartCommand | diskpart)
			#if Disppart version line more than 1 times - unknown command
			$RegexpResult = $CommandOutput -match $DP_UNKNOWN_COMMAND_MESSAGE
	        if ($RegexpResult.Length -gt 1) {
	            Throw ("ERROR!!! Unknown command:""" + $DiskpartCommand +"""!")
	        } else {
	            return $CommandOutput
	        }
		} catch {
	        Throw $_
		}
	}
	Function Parse-DiskpartList {
	<#
		.SYNOPSIS
			The function converts "raw" "diskpart list" output into an object
		.DESCRIPTION
			The function has been created to convert output of "diskpart list" command
			into an object. 
			It can parse output of the following "List" commands:
				DISK        - Display a list of disks. For example, LIST DISK.
				PARTITION   - Display a list of partitions on the selected disk.
				VOLUME      - Display a list of volumes. For example, LIST VOLUME.
				VDISK       - Displays a list of virtual disks.
			The standard output is a table which consist of a title row and several data row. Example:
				DISKPART> list volume

				Volume ###  Ltr  Label        Fs     Type        Size     Status     Info
				----------  ---  -----------  -----  ----------  -------  ---------  --------
				Volume 0     D   Data         NTFS   Mirror      1863 GB  Healthy
				Volume 1     E   de-DE_L2     CDFS   DVD-ROM      382 MB  Healthy
				Volume 2         System Rese  NTFS   Partition    100 MB  Healthy    System
				Volume 3     C                NTFS   Partition     55 GB  Healthy    Boot 
			The script will create an array of objects which consist of properties named after columns
			(i.e. "Volume ###", "Label" etc)
			Example: 
				Volume ### : Volume 0
				Ltr        : D
				Label      : Data
				Fs         : NTFS
				Type       : Mirror
				Size       : 1863 GB
				Status     : Healthy
				Info       : 

				Volume ### : Volume 1
				Ltr        : E
				Label      : de-DE_L2
				Fs         : CDFS
				Type       : DVD-ROM
				Size       : 382 MB
				Status     : Healthy
				Info       : 

				Volume ### : Volume 2
				Ltr        : 
				Label      : System Rese
				Fs         : NTFS
				Type       : Partition
				Size       : 100 MB
				Status     : Healthy
				Info       : System

				Volume ### : Volume 3
				Ltr        : C
				Label      : 
				Fs         : NTFS
				Type       : Partition
				Size       : 55 GB
				Status     : Healthy
				Info       : Boot
		.PARAMETER  ParameterA
			The description of the ParameterA parameter.

		.PARAMETER  DiskpartOutput
			An array which contains the output of "diskpart list" command 
			(i.e. $DiskpartOutput = ("list volume" | diskpart) 
		.EXAMPLE
			$objDiskpartList = Parse-DiskpartList -DiskpartOutput $DiskpartOutput
			System.String,System.Int32
		.OUTPUTS
			System.Array
		.NOTES
			The function is free to use\copy or modify. In case of any issues or requests, feel free to ask me via GitHub
		.LINK
			https://github.com/FutureIsHere
		.LINK
			https://github.com/FutureIsHere/PowerShell-Functions/tree/master/Parse-DiskpartList
	#>

		param (
			[parameter(Position=0,Mandatory=$true)]
			[array]$DiskpartOutput
		)
		#remove empty lines
		$tmpArray = @()
		foreach ($line in $DiskpartOutput) {
			$line = $line.TrimStart()
			if ($line.length -ne 0) {
				$tmpArray+=$line
			}
		}
		$DiskpartOutput = $tmpArray

		#find the line with dashes (i.e. "----- ---- --- "
		$indexTitleSeparatorLine = $null
		$indexCurrentLine = 0
		foreach ($line in $DiskpartOutput) {
			if ($line -match "---") {
				$indexTitleSeparatorLine = $indexCurrentLine
				break
			}
			$indexCurrentLine++ 
		}
		if ($indexTitleSeparatorLine -eq $null) {
			throw ("ERROR!!! Incorect format of diskpart output (no separation line (----))")
		}
		
		#get the last data line index (the line before "DISKPART>" line)
		$indexLastDataLine = $null
		for ($i = $indexTitleSeparatorLine; $i -lt $DiskpartOutput.Length; $i++) {
			if ($DiskpartOutput[$i] -match "DISKPART>") {
				$indexLastDataLine = $i - 1 	#the line above
				break
			}
		}
		if ($indexLastDataLine -eq $null) {
			throw ("ERROR!!! Incorect format of diskpart output (no ending line)")
		}

		#calculate columns's width (i.e. "-----" - 5)
		$arrColumnWidth = @()
		$arrColumns = $DiskpartOutput[$indexTitleSeparatorLine].Split()
		foreach($Column in $arrColumns) {
			if ($Column.Length -ne 0) {
				#include only not empty column titles
				$arrColumnWidth+=$Column.Length
			}
		}
		
		#get columns's title
		$ColumnTitleLine = $DiskpartOutput[$indexTitleSeparatorLine-1]	#we assume, that the title line is above the separation line
		$arrColumnTitle = @()
		$indexCurrentColumnTitle = 0		#position of the first character of column's title in the title line
		for ($i = 0; $i -lt $arrColumnWidth.Length; $i++) {
			if ($i -ne ($arrColumnWidth.Length -1)) {
				$ColumnTitle = $ColumnTitleLine.Substring($indexCurrentColumnTitle,$arrColumnWidth[$i])
				$indexCurrentColumnTitle = $indexCurrentColumnTitle + 2 		#at least 2 whitespaces separates columns
				$indexCurrentColumnTitle = $indexCurrentColumnTitle + $arrColumnWidth[$i]		#move the position index to the next column
			} else {
				#get the last element
				$ColumnTitle = $ColumnTitleLine.Substring($indexCurrentColumnTitle)
			}
			$ColumnTitle = $ColumnTitle.Trim()
			$arrColumnTitle += $ColumnTitle
		}
		
		#parse the data
		#the data will be stored in an array of objects
		$arrDiskpartListData = @()
		for ($i = $indexTitleSeparatorLine + 1; $i -le $indexLastDataLine; $i++) {
			#create an object which contains the data
			$objData = New-Object psobject
			foreach ($Column in $arrColumnTitle) {
				$objData | Add-Member -Name "$Column" -MemberType NoteProperty -Value $null
			}
			$indexCurrentColumn = 0
			$indexCurrentColumnData = 0		#position of the first character of data column
			$DataLine = $DiskpartOutput[$i]
			foreach ($Column in $arrColumnTitle) {
				if ($indexCurrentColumn -lt ($arrColumnTitle.Length - 1)) {
					$Data = $DataLine.Substring($indexCurrentColumnData,$arrColumnWidth[$indexCurrentColumn])
					$indexCurrentColumnData=$indexCurrentColumnData + 2 	#at least 2 whitespaces separates columns
					$indexCurrentColumnData=$indexCurrentColumnData + $arrColumnWidth[$indexCurrentColumn]
					$indexCurrentColumn++			
				} else {
					$Data = $DataLine.Substring($indexCurrentColumnData)
				}
				$Data = $Data.Trim()
				$objData.$Column = $Data
			}
			$arrDiskpartListData+= $objData
		}
		return $arrDiskpartListData
	}	
#endregion

cls

try {   
    $DP_output = Run-Diskpart "list volume"
    $AllVolumes = $null
	$AllVolumes = Parse-DiskpartList $DP_output
} catch {
    $CaughtException = $_
	Write-Host $CaughtException
	return (-1)
}

#2. Generate an error event if one RAID of volumes is NOT healthy
try {
	$EVENT_SOURCE = "DiskDiagnostic"
	$NumberOfUnhealthyVolumes = 0
	#check if the event source exists. If doesn't - create it
	if ([System.Diagnostics.EventLog]::SourceExists($EVENT_SOURCE)-eq $false) {
		New-EventLog -LogName $EVENT_LOG -Source $EVENT_SOURCE
	}
	foreach ($Volume in $AllVolumes) {
		if (($Volume."Status" -notmatch "Healthy")  -and ($Volume."Type" -notmatch "Removable")) {
			$NumberOfUnhealthyVolumes++
			$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is NOT healthy!`nThe current status:""" + $Volume."Status" + """!" )
			Write-EventLog -EventId $EVENT_ID_VOLUME_NOT_HEALTHY -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
			Write-Host $EventErrorMessage
		}
	}
} catch {
    $CaughtException = $_
	Write-Host $CaughtException
	return (-2)
}
if ($NumberOfUnhealthyVolumes -eq 0) {
	$EventErrorMessage = ("The volumes verifitation script has completed. All volumes are healthy!" )
	Write-EventLog -EventId $EVENT_ID_VOLUME_HEALTHY -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	Write-Host $EventErrorMessage
} else {
	#try to recover the failed volumes
	foreach ($Volume in $AllVolumes) {
		if ($Volume."Status" -match "Failed Rd") {
			$VolumeNumber = (($Volume."Volume ###").Split())[1]
			$DP_Command = @(("select volume " + $VolumeNumber),'recover')
			$DP_output = Run-Diskpart $DP_Command
			if ($DP_output -match "The RECOVER command completed successfully") {
				$EventErrorMessage = ("The RECOVER command for volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """  has been started successfully!" )
				Write-EventLog -EventId $EVENT_ID_VOLUME_RECOVER_SUCCESSFULL -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
			} else {
				$EventErrorMessage = ("The RECOVER command for volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """  has failed!`nStatus:""" +  $DP_output + """")
				Write-EventLog -EventId $EVENT_ID_VOLUME_RECOVER_FAILED -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
			}
		}
	}
	#check the status of disks and volumes
	#If there are disks with "Error" status - generate an error event
	$DP_Output = Run-Diskpart "list disk"
	$AllDisks = $null
	$AllDisks = Parse-DiskpartList $DP_Output
	foreach ($Disk in $AllDisks) {
		if ($Disk."Status" -match "Error") {
			$EventErrorMessage = ("ERROR!!! """ + $Disk."Disk ###" + """, Size: """ + $Disk."Size" + """ has Error status!")
			Write-EventLog -EventId $EVENT_ID_DISK_ERROR_STATUS -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
		}
	}
    $DP_output = Run-Diskpart "list volume"
    $AllVolumes = $null
	$AllVolumes = Parse-DiskpartList $DP_output
	$NumberOfRebuildingVolumes = 0
	foreach ($Volume in $AllVolumes) {
		if ($Volume."Status" -match "Rebuild") {
			$NumberOfRebuildingVolumes++
		}
	}
	if ($NumberOfRebuildingVolumes -eq $NumberOfUnhealthyVolumes) {
		$EventErrorMessage = ("All unhealthy volumes (" + $NumberOfUnhealthyVolumes + ") are rebuilding!")
		Write-EventLog -EventId $EVENT_ID_VOLUME_REBUILDING -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	} else {
		$EventErrorMessage = ("ERROR!!! Some of unhealthy volumes (" + $NumberOfUnhealthyVolumes + ") are NOT rebuilding!")
		Write-EventLog -EventId $EVENT_ID_VOLUME_NOT_REBUILDING -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Error -Message $EventErrorMessage -Category 0
		return 0
	}
	do {
		sleep -Seconds $VOLUME_RECHECK_INTERVAL 			#delay between checks
	    $DP_output = Run-Diskpart "list volume"
    	$AllVolumes = $null
		$AllVolumes = Parse-DiskpartList $DP_output
		$NumberOfRebuildingVolumes = 0
		foreach ($Volume in $AllVolumes) {
			if ($Volume."Status" -match "Rebuild") {
				$NumberOfRebuildingVolumes++
				$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is rebuilding!" )
				Write-EventLog -EventId $EVENT_ID_VOLUME_REBUILDING -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Warning -Message $EventErrorMessage -Category 0
			} else {
				if ($Volume."Status" -notmatch "Healthy") {
					$EventErrorMessage = ("Volume """ + $Volume."Volume ###" + """, Letter """ + $Volume."Ltr" + """, Type """ + $Volume."Type" + """ is not healthy or rebuilding!`nCurrent status:""" + $Volume."Status" + """!" )
					Write-EventLog -EventId $EVENT_ID_VOLUME_NOT_HEALTHY -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Warning -Message $EventErrorMessage -Category 0
					return 0
				}
			}
		}
	} while ($NumberOfRebuildingVolumes -gt 0)
	$EventErrorMessage = ("Rebuilding of volumes have been completed successfully!" )
	Write-EventLog -EventId $EVENT_ID_VOLUME_REBULDING_COMPLETED -LogName $EVENT_LOG -Source $EVENT_SOURCE -EntryType Information -Message $EventErrorMessage -Category 0
	
}
$AllVolumesHealthy = $false