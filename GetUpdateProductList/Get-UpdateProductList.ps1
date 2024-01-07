# Get-UpdateProductList
#
# Created by: Scott Fairchild
# email: scott@scottjfairchild.com

# Set script variables
$updateWMI = $true # Set to true if WMI should be updated with the results so it can be inventoried by Configuration Manager
$wmiCustomNamespace = "ITLocal" # Will be created under the ROOT namespace
$wmiCustomClass = "Update_Product_List" # Will be created in the $wmiCustomNamespace. Will also be used to name the view in Configuration Manager
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
		
    # Log Variables
    $LogFileName = "Get-UpdateProductList.log"
    $OldLogFileName = "Get-UpdateProductList.lo_"
    $CmdletName = @('Get-UpdateProductList')


    # Set log file location
    $LogFile = Join-Path $LogFilePath $LogFileName # C:\Windows\CCM\Logs\UpdateProductList.log
    $OldLogFile = Join-Path $LogFilePath $OldLogFileName # C:\Windows\CCM\Logs\UpdateProductList.lo_

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

# Create List to hold distinct Product results
$script:products = [System.Collections.ArrayList]::new()
# Create List to hold updates Microsoft found
$script:updates = [System.Collections.ArrayList]::new()
# Set ServiceID for Microsoft Update
$ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"

# Check if 'Receive updates for other Microsoft products when you update Windows' is enabled
$ServiceManager = New-Object -ComObject "Microsoft.Update.ServiceManager"
$found = $false
Write-CMLogEntry -Value "Checking if Microsoft Update is enabled" -Severity 1
foreach ($service in $ServiceManager.Services) {
    if ($service.ServiceID -eq $ServiceID) {
        if ($service.IsRegisteredWithAU -eq 1) {
            $found = $true
            Write-CMLogEntry -Value "Microsoft Update is enabled" -Severity 1
        }
    }
}

if (-Not $found) {
    Write-CMLogEntry -Value "Microsoft Update is not enabled" -Severity 1
    # Enable 'Receive updates for other Microsoft products when you update Windows', so we can scan against it.
    try {
        Write-CMLogEntry -Value "Enabling Microsoft Update so we can scan against it" -Severity 1
        $NewService = $ServiceManager.AddService2($ServiceID, 7, "")
    }
    catch {
        Write-CMLogEntry -Value  "Failed to register service" -Severity 3
        Write-CMLogEntry $_.Exception.Message -Severity 3
        Exit 1
    }
    if ($NewService.IsPendingRegistrationWithAU) {
        Write-CMLogEntry -Value  "Needs to reboot" -Severity 2
        # Exit script since we need the service fully registered
        Write-CMLogEntry -Value "****************************** Script Finished ******************************" -Severity 1
        Exit 0
    }
    Write-CMLogEntry -Value "Service enabled" -Severity 1
}

try {

    Write-CMLogEntry -Value "Get current Windows Update source settings" -Severity 1
    # If the GPO setting 'Specify source service for specific classes of Windows Update' is enabled, get the values 
    $currentQualityUpdateSetting = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForQualityUpdates -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SetPolicyDrivenUpdateSourceForQualityUpdates
    $currentOtherUpdateSetting = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForOtherUpdates -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SetPolicyDrivenUpdateSourceForOtherUpdates

    if ($currentQualityUpdateSetting -eq 1)
    {
        Write-CMLogEntry -Value "Setting SetPolicyDrivenUpdateSourceForQualityUpdates to 0" -Severity 1
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForQualityUpdates -Value 0 -Type DWord
    }
    if ($currentOtherUpdateSetting -eq 1)
    {
        Write-CMLogEntry -Value "Setting SetPolicyDrivenUpdateSourceForOtherUpdates to 0" -Severity 1
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForOtherUpdates -Value 0 -Type DWord
    }

    Write-CMLogEntry -Value "Connecting to Microsoft Update" -Severity 1
    # Create COM object so we can search for updates
    $Searcher = New-Object -ComObject Microsoft.Update.Searcher
    # Force search to go online and not use cached metadata
    $Searcher.Online = 1
    # Scan online against Microsoft Update and include other products
    $Searcher.ServerSelection = 3 # Microsoft Update
    $Searcher.ServiceID = $ServiceID
    $Results = $null
    Write-CMLogEntry -Value "Start scanning for Microsoft Updates" -Severity 1
    # Note: If you only want to show the results for missing updates, change the following line to
    # $Results = $Searcher.Search("Type='Software' AND IsInstalled=0")
    $Results = $Searcher.Search("Type='Software'")
    Write-CMLogEntry -Value "Finished scanning for Microsoft Updates" -Severity 1

    Write-CMLogEntry -Value "Setting Windows Update source values back to what they were before" -Severity 1
    # Revert 'Specify source service for specific classes of Windows Update' back to original values 
    if ($currentQualityUpdateSetting -eq 1)
    {
        Write-CMLogEntry -Value "Setting SetPolicyDrivenUpdateSourceForQualityUpdates to 1" -Severity 1
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForQualityUpdates -Value 1 -Type DWord
    }
    if ($currentOtherUpdateSetting -eq 1)
    {
        Write-CMLogEntry -Value "Setting SetPolicyDrivenUpdateSourceForOtherUpdates to 1" -Severity 1
        Set-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name SetPolicyDrivenUpdateSourceForOtherUpdates -Value 1 -Type DWord
    }

    # Create list of classifications so we know when to add them to the third array element
    # The information in $update.Categories is not always in the correct order 
    $Classifications = ("Critical Updates", "Definition Updates", "Feature Packs", "Security Updates", "Service Packs", "Tools", "Update Rollups", "Updates", "Upgrades")

    # loop through found updates
    ForEach ($update in $Results.Updates) {

        # Create empty array to hold each update's details
        $a = @('', '', '', '')
        # Add  Title to first array element
        $a[0] = """$($update.Title)"""
        # Add installation status to second array element
        $a[1] = """$($update.IsInstalled.ToString())"""
   
        # Loop through catagories and product types associated with the update
        foreach ($cat in $update.Categories) {
            if ($null -ne $cat) {
                # If the name matches a classification, add it to the third array element
                If ($Classifications.Contains($cat.Name)) {
                    $a[2] = """$($cat.Name)"""
                }
                else {
                    # Must be a Product name, so add to the fourth array element
                    $a[3] += """$($cat.Name)""" + ","
                    if (-Not ($script:products.Contains($cat.Name))) {
                        $script:products.Add($cat.Name) | Out-Null
                    }     
                }
            }
        }

        # Add array element to the update list
        $script:updates.Add($a) | Out-Null

    }
}
catch {
    # Do nothing
    # More than likely 'Receive updates for other Microsoft products when you update Windows' failed to enable or it is waiting for a reboot
}

# Disable 'Receive updates for other Microsoft products when you update Windows' if it was not enabled when the script first ran
if (-Not $found) {
    try {
        Write-CMLogEntry -Value "Disabling Microsoft Updates since it was disabled when the script first ran" -Severity 1
        $ServiceManager.RemoveService($ServiceID)
        Write-CMLogEntry -Value "Service disabled" -Severity 1
    }
    catch {
        if ($_.Exception.ErrorCode -eq -2145091564) {
            Write-CMLogEntry -Value "The service doesn't exist, so exit successfully" -Severity 1
        }
        else {
            Write-CMLogEntry -Value "Failed to remove service" -Severity 3
            Write-CMLogEntry -Value $_.Exception.Message -Severity 3
        }
    }
}

# Create new stringbuilder
$sb = [System.Text.StringBuilder]::new()
# add header
[void]$sb.AppendLine("Update Name,Is Installed,Classification,Product(s)")
# parse each line and add it to the stringbuilder
foreach ($item in $script:updates) {
    [void]$sb.AppendLine("$($item[0]),$($item[1]),$($item[2]),$($item[3])")
}
# Output stringbuilder to a csv file in the $LogFilePath folder
Write-CMLogEntry -Value "Saving scan results to $LogFilePath\UpdateProductListScanResults.csv" -Severity 1
$sb.ToString() | Out-File -Encoding ascii -FilePath $LogFilePath\UpdateProductListScanResults.csv

# Sort the Products list
$script:products.Sort()
# Output the list of distinct Products to a txt file in the $LogFilePath folder
Write-CMLogEntry -Value "Saving product list to $LogFilePath\UpdateProductListProductsFound.txt" -Severity 1
$script:products | Out-File -Encoding ascii -FilePath $LogFilePath\UpdateProductListProductsFound.txt

if ($updateWMI) {
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
        $newClass.Properties.Add("ProductName", [System.Management.CimType]::String, $false)
        $newClass.Properties["ProductName"].Qualifiers.Add("Key", $true)
        $newClass.Put() | Out-Null
    }


    # Remove current inventory records from WMI
    # This is done so Hardware Inventory can pick up applications that have been added/removed
    Write-CMLogEntry -Value "Clearing current WMI entries" -Severity 1
    Get-CimInstance -Namespace root\$wmiCustomNamespace -Query "Select * from $wmiCustomClass" | Remove-CimInstance

    # Update WMI
    Write-CMLogEntry -Value "Start adding Product Names to WMI" -Severity 1
    foreach ($product in $script:products) {

        Write-CMLogEntry -Value "-> Adding $product" -Severity 1

        # Create new instance in WMI
        $newRec = New-CimInstance -Namespace root\$wmiCustomNamespace -ClassName $wmiCustomClass -Property @{ProductName = "$product" }

        # Save to WMI
        $newRec | Set-CimInstance

    }
    Write-CMLogEntry -Value "Finished adding Product Names to WMI" -Severity 1
}

Write-CMLogEntry -Value "****************************** Script Finished ******************************" -Severity 1
Return "True"
