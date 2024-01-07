# Script Name: Get-UserApplications.ps1
# Created by:  Scott Fairchild

# Based off the "Modifying the Registry for All Users" script from PDQ found at https://www.pdq.com/blog/modifying-the-registry-users-powershell/

# NOTE: When the WMI class is added to Configuration Manager Hardware Inventory, 
#       Configuration Manager will create a view called v_GS_<Whatever You Put In The $wmiCustomClass Variable>
#       You can then create custom reports against that view.

# Set script variables
$wmiCustomNamespace = "ITLocal" # Will be created under the ROOT namespace
$wmiCustomClass = "User_Based_Applications" # Will be created in the $wmiCustomNamespace. Will also be used to name the view in Configuration Manager
$DoNotLoadOfflineProfiles = $false # Prevents loading the ntuser.dat file for users that are not logged on
$LogFilePath = "C:\Windows\CCM\Logs" # Location where the log file will be stored
$maxLogFileSize = "5MB" # Sets the maximum size for the log file before it rolls over

# *******************************************************************************************
# DO NOT MODIFY ANYTHING BELOW THIS LINE
# *******************************************************************************************

# Function to write to a log file in Configuration Manager format
function Write-CMLogEntry {	
    param (
        [parameter(Mandatory = $true, HelpMessage = "Text added to the log file.")]
        [ValidateNotNullOrEmpty()]
        [string]$Value,

        [parameter(Mandatory = $true, HelpMessage = "Severity for the log entry. 1 for Informational, 2 for Warning and 3 for Error.")]
        [ValidateNotNullOrEmpty()]
        [ValidateSet("1", "2", "3")]
        [string]$Severity
    )
		
    # Calculate log file names based on the name of the running script
    #$scriptFullPath = $myInvocation.ScriptName -split "\\" # Ex: C:\Windows\Temp\Get-UserApplications.ps1
    #$scriptFullName = $scriptFullPath[($scriptFullPath).Length - 1] # Get-UserApplications.ps1
    #$CmdletName = $scriptFullName -split ".ps1" # Get-UserApplications
    #$LogFileName = "$($CmdletName[0]).log" # Get-UserApplications.log
    #$OldLogFileName = "$($CmdletName[0]).lo_" # Get-UserApplications.lo_

    # Hard Code names because script Configuration Items create a file that uses a GUID as the name
    $LogFileName = "Get-UserApplications.log"
    $OldLogFileName = "Get-UserApplications.lo_"
    $CmdletName = @('Get-UserApplications')


    # Set log file location
    $LogFile = Join-Path $LogFilePath $LogFileName # C:\Windows\CCM\Logs\Get-UserApplications.log
    $OldLogFile = Join-Path $LogFilePath $OldLogFileName # C:\Windows\CCM\Logs\Get-UserApplications.lo_

    # Rotate log file if needed
    if ( (Get-Item $LogFile -ea SilentlyContinue).Length -gt $maxLogFileSize ) {
        # Delete old log file
        if (Get-Item $OldLogFile -ea SilentlyContinue) {
            Remove-Item $OldLogFile
        }
        # Rename current log to old log
        Rename-Item -Path $LogFile -NewName $OldLogFileName
    }

    # Construct time stamp for log entry
    $Time = -join @((Get-Date -Format "HH:mm:ss.fff"), (Get-CimInstance -Class Win32_TimeZone | Select-Object -ExpandProperty Bias))

    # Construct date for log entry
    $Date = (Get-Date -Format "MM-dd-yyyy")
		
    # Construct final log entry
    $LogText = "<![LOG[$($Value)]LOG]!><time=""$($Time)"" date=""$($Date)"" component=""$($CmdletName[0])"" context="""" type=""$($Severity)"" thread=""$($PID)"" file="""">"

    # Add text to log file and output to screen
    try {
        Out-File -InputObject $LogText -Append -NoClobber -Encoding Default -FilePath $LogFile -ErrorAction Stop 
        #Write-Host $Value
    }		
    catch [System.Exception] {
        Write-Warning -Message "Unable to append log entry to $LogFileName file. Error message: $($_.Exception.Message)"
    }
}


Write-CMLogEntry -Value "****************************** Script Started ******************************" -Severity 1

if ($DoNotLoadOfflineProfiles) {
    Write-CMLogEntry -Value "DoNotLoadOfflineProfiles = True. Only logged in users will be checked" -Severity 1
}
else {
    Write-CMLogEntry -Value "DoNotLoadOfflineProfiles = False. All user profiles will be checked" -Severity 1
}

# Check if custom WMI Namespace Exists. If not, create it.
$namespaceExists = Get-CimInstance -Namespace root -ClassName __Namespace -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $wmiCustomNamespace }
if (-not $namespaceExists) {
    Write-CMLogEntry -Value "$wmiCustomNamespace WMI Namespace does not exist. Creating..." -Severity 1
    $ns = [wmiclass]'ROOT:__namespace'
    $sc = $ns.CreateInstance()
    $sc.Name = $wmiCustomNamespace
    $sc.Put() | Out-Null
}

# Check if custom WMI Class Exists. If not, create it.
$classExists = Get-CimClass -Namespace root\$wmiCustomNamespace -ClassName $wmiCustomClass -ErrorAction SilentlyContinue
if (-not $classExists) {
    Write-CMLogEntry -Value "$wmiCustomClass WMI Class does not exist in the ROOT\$wmiCustomNamespace namespace. Creating..." -Severity 1
    $newClass = New-Object System.Management.ManagementClass ("ROOT\$($wmiCustomNamespace)", [String]::Empty, $null); 
    $newClass["__CLASS"] = $wmiCustomClass; 
    $newClass.Qualifiers.Add("Static", $true)
    $newClass.Properties.Add("UserName", [System.Management.CimType]::String, $false)
    $newClass.Properties["UserName"].Qualifiers.Add("Key", $true)
    $newClass.Properties.Add("ProdID", [System.Management.CimType]::String, $false)
    $newClass.Properties["ProdID"].Qualifiers.Add("Key", $true)
    $newClass.Properties.Add("DisplayName", [System.Management.CimType]::String, $false)
    $newClass.Properties.Add("InstallDate", [System.Management.CimType]::String, $false)
    $newClass.Properties.Add("Publisher", [System.Management.CimType]::String, $false)
    $newClass.Properties.Add("DisplayVersion", [System.Management.CimType]::String, $false)
    $newClass.Put() | Out-Null
}

if ($DoNotLoadOfflineProfiles -eq $false) {
    # Remove current inventory records from WMI
    # This is done so Hardware Inventory can pick up applications that have been removed
    Write-CMLogEntry -Value "Clearing current inventory records" -Severity 1
    Get-CimInstance -Namespace root\$wmiCustomNamespace -Query "Select * from $wmiCustomClass" | Remove-CimInstance
}

# Regex pattern for SIDs
$PatternSID = 'S-1-5-21-\d+-\d+\-\d+\-\d+$'
 
# Get all logged on user SIDs found in HKEY_USERS (ntuser.dat files that are loaded)
Write-CMLogEntry -Value "Identifying users who are logged on" -Severity 1
$LoadedHives = Get-ChildItem Registry::HKEY_USERS | Where-Object { $_.PSChildname -match $PatternSID } | Select-Object @{name = "SID"; expression = { $_.PSChildName } }
if ($LoadedHives) {
    # Log all logged on users
    foreach ($userSID in $LoadedHives) {
        Write-CMLogEntry -Value "-> $userSID" -Severity 1
    }
}
else {
    Write-CMLogEntry -Value "-> None Found" -Severity 1
}

if ($DoNotLoadOfflineProfiles -eq $false) {

    # Get SID and location of ntuser.dat for all users
    Write-CMLogEntry -Value "All user profiles on machine" -Severity 1
    $ProfileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*' | Where-Object { $_.PSChildName -match $PatternSID } | 
    Select-Object  @{name = "SID"; expression = { $_.PSChildName } }, 
    @{name = "UserHive"; expression = { "$($_.ProfileImagePath)\ntuser.dat" } }
    # Log All User Profiles
    foreach ($userSID in $ProfileList) {
        Write-CMLogEntry -Value "-> $userSID" -Severity 1
    }

    # Compare logged on users to all profiles and remove loggon on users from list
    Write-CMLogEntry -Value "Profiles that have to be loaded from disk" -Severity 1
    # If logged on users found, compare profile list to see which ones are logged off
    if ($LoadedHives) {
        $UnloadedHives = Compare-Object $ProfileList.SID $LoadedHives.SID | Select-Object @{name = "SID"; expression = { $_.InputObject } }
    }
    else { # No logged on users found so lets load all profiles
        $UnloadedHives = $ProfileList | Select-Object -Property SID
    }

    # Log SID's that need to be loaded
    if ($UnloadedHives) {
        foreach ($userSID in $UnloadedHives) {
            Write-CMLogEntry -Value "-> $userSID" -Severity 1
        }
    }
}

# Determine list of users we will iterate over
$profilesToQuery = $null
if ($DoNotLoadOfflineProfiles) {
    
    if ($LoadedHives) {
        $profilesToQuery = $LoadedHives
    }
    else {
        Write-CMLogEntry -Value "No users are logged on. Exiting..." -Severity 1
        Write-CMLogEntry -Value "****************************** Script Finished ******************************" -Severity 1
        Return "True"
        Exit
    }
}
else {
    $profilesToQuery = $ProfileList
}

# Loop through each profile
Foreach ($item in $profilesToQuery) {
    Write-CMLogEntry -Value "-------------------------------------------------------------------------------------------------------------" -Severity 1
    $userName = ''

    # Get user name associated with profile from SID
    $objSID = New-Object System.Security.Principal.SecurityIdentifier ($item.SID)
    $userName = $objSID.Translate( [System.Security.Principal.NTAccount]).ToString()

    if ($DoNotLoadOfflineProfiles) {
        # Remove current inventory records from WMI
        # This is done so Hardware Inventory can pick up applications that have been removed
        Write-CMLogEntry -Value "Clearing out current inventory for $userName" -Severity 1
        $escapedUserName = $userName.Replace('\', '\\')
        $delItem = Get-CimInstance -Namespace root\$wmiCustomNamespace -Query "Select * from $wmiCustomClass where UserName = '$escapedUserName'"
        if ($delItem) {
            $delItem | Remove-CimInstance
        }
    }

    # Load ntuser.dat if the user is not logged on
    if ($DoNotLoadOfflineProfiles -eq $false) {
        if ($item.SID -in $UnloadedHives.SID) {
            Write-CMLogEntry -Value "Loading user hive for $userName from $($Item.UserHive)" -Severity 1
            reg load HKU\$($Item.SID) $($Item.UserHive) | Out-Null
        }
        else {
            Write-CMLogEntry -Value "$UserName is logged on. No need to load hive from disk" -Severity 1
        }
    }

    Write-CMLogEntry -Value "Getting installed User applications for $userName" -Severity 1

    # Define x64 apps location
    $userApps = Get-ChildItem -Path Registry::HKEY_USERS\$($Item.SID)\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue
    if ($userApps) {
        Write-CMLogEntry -Value "Found user installed applications" -Severity 1
        # parse each app
        $userApps | ForEach-Object {
            # Clear current values
            $ProdID = ''
            $DisplayName = ''
            $InstallDate = ''
            $Publisher = ''
            $DisplayVersion = ''

            # Get Key name
            $path = $_.PSPath
            $arrTemp = $_.PSPath -split "\\"
            $ProdID = $arrTemp[($arrTemp).Length - 1]
      
            # Iterate key and get all properties and values
            $_.Property | ForEach-Object {
                $prop = $_
                $value = Get-ItemProperty -literalpath $path -name $prop | Select-Object -expand $prop

                switch ( $prop ) {
                    DisplayName { $DisplayName = $value }
                    InstallDate { $InstallDate = $value }
                    Publisher { $Publisher = $value }
                    DisplayVersion { $DisplayVersion = $value }
                }
            }

            Write-CMLogEntry -Value "-> Adding $DisplayName" -Severity 1

            # Create new instance in WMI
            $newRec = New-CimInstance -Namespace root\$wmiCustomNamespace -ClassName $wmiCustomClass -Property @{UserName = "$userName"; ProdID = "$ProdID" }

            # Add properties
            $newRec.DisplayName = $DisplayName
            $newRec.InstallDate = $InstallDate
            $newRec.Publisher = $Publisher
            $newRec.DisplayVersion = $DisplayVersion

            # Save to WMI
            $newRec | Set-CimInstance
        }

    }
    else {
        Write-CMLogEntry -Value "No user applications found" -Severity 1
    }

    if ($DoNotLoadOfflineProfiles -eq $false) {
        # Unload ntuser.dat   
        # Let's do everything possible to make sure we no longer have a hook into the user profile,
        # because if we do, an Access Denied error will be displayed when trying to unload.     
        IF ($item.SID -in $UnloadedHives.SID) {
            # check if we loaded the hive
            Write-CMLogEntry -Value "Unloading user hive for $userName" -Severity 1

            # Close Handles
            If ($userApps) {
                $userApps.Handle.Close()
            }

            # Set variable to $null
            $userApps = $null

            # Garbage collection
            [gc]::Collect()

            # Sleep for 2 seconds
            Start-Sleep -Seconds 2

            #unload registry hive
            reg unload HKU\$($Item.SID) | Out-Null
        }
    }
}

Write-CMLogEntry -Value "****************************** Script Finished ******************************" -Severity 1
Return "True"
