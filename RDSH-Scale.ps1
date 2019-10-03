# Author: Michael Troisi
# Date: 8/5/2019
#
# This script calculates the utlization of each session host and determinies if  
# more session hosts need to be started or stopped based on a breadth algorithm

# NOTE: This script operates on the assumption. 
# That the VM name in Azure is the hostname of the machine.


# Configuration Variables
# ----------------------------------------------------------------------------------

# This setting prevents any configuration changes to be made when set to 1
$TESTING_MODE = 0

# path to store log files. Trailing backslash necessary
$LogPath = ''
$LogFile = Get-Date -Format "yyyyMMdd"


$ConnectionBroker = ''
$CollectionName = ''
$TagValues = ''

# Maximum percentage utilization
$MaxUtilization = 80
# Minimum percentage utlization
$MinUtilization = 40

# Minimum session hosts to remain online
$MinSessionHost = 1

# Shutdown delay in seconds
$ShutdownTimer = '300'

$MessageTitle = 'System Scaling Underway'
$MessageBody = 'Please save your work and logoff!'

# ----------------------------------------------------------------------------------


# Declare functions
# ----------------------------------------------------------------------------------

# logging function
Function Write-Log {
    param ( [String]$Message )
    $DatePrefix = Get-Date -Format "MM/dd/yyyy HH:mm:ss : "

    Write-Host $Message
    Out-File -FilePath ($LogPath + $LogFile + ".log") -Append -InputObject ( $DatePrefix + $Message )
}



# Set the power state of an Azure VM. Input is session host object and the variable, on or off.
Function Set-AzureVMPower {
    param ( $SessionHost,
            [String]$PowerState )

    Write-Host ( $SessionHost )

                
    # block attempt to turn off last session host
    if ( ($SessionHostTable | Where-Object PowerOn).Count -le $MinSessionHost -and 
    $PowerState -like 'off' ) {

        Write-Log ( "Set-AzureVMPower off was called on the last running session host. No action taken" )
    }
    elseif ($PowerState -like 'on' -and $SessionHost.PowerOn -eq 0) { 
        

        if ( -not $TESTING_MODE ) {

            Write-Log ( "Starting VM: " + $SessionHost.VMName )
            # Try to start VM
            try {             
                            
                Start-AzureRmVM -Name $SessionHost.VMName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
            }
            catch { 

                Write-Log ( "An error has occurred when starting VM: " + $SessionHost.VMName ) 
            }
        else { 

            Write-Log ("TESTING: Starting VM: " + $SessionHost.VMName)
        }
            # update session host table
            $SessionHost.PowerOn = 1 | Out-Null
        }
    }
    elseif ($PowerState -like 'off' -and $SessionHost.PowerOn -eq 1) {

        if ( -not $TESTING_MODE ) { 

            Write-Log ( "Stopping VM: " + $SessionHost.VMName )
            # Try to stop VM            
            try { 

                Stop-AzureRmVM -Name $SessionHost.VMName -ResourceGroupName $ResourceGroupName -Force
            }
            catch { 

                Write-Log ( "An error has occurred when stopping VM: " + $SessionHost.VMName ) 
            }
        else { 

            Write-Log ("TESTING: Stopping VM: " + $SessionHost.VMName)
        }
        # update session host table
        $SessionHost.PowerOn = 0 | Out-Null
        }
    }
    else {

        Write-Log ( "Unknown power state: " + $Value + ". No action was taken on VM: " + $SessionHost.VMName )
    }
}    

# Send a message to all connected users on a session host. Input is session host object.
Function Send-UserMessage {
    param ( $SessionHost )

    # Get user session list for server being scaled down
    $SessionHostSessionList = $UserSessionList | Where-Object HostServer -Like $SessionHost.FQDN
    # Get count of user sessions for server being scaled down
    $SessionHostUserCount = $SessionHostSessionList.Count

    # Cancel function early if no users on host
    if ( $SessionHostUserCount -le 0 ) {
        Write-Log ( "No users on " + $SessionHost.FQDN )
        return 0
    }

    $SessionHostSessionList | ForEach-Object {
        try {

            if ( -not $TESTING_MODE ) {

                Write-Log ("Sending RDUsermessage. SessionHostName: " + $SessionHost.FQDN + " UserName: " + $_.UserName)

                Send-RDUserMessage -HostServer $SessionHost.FQDN -UnifiedSessionID $_.UnifiedSessionId -MessageTitle $MessageTitle -MessageBody $MessageBody
            }
            else {

                Write-Log ("TESTING: Sending RDUsermessage. SessionHostName: " + $SessionHost.FQDN + " UserName: " + $_.UserName)
            }
        }
        catch { 

            Write-Log ( "An error has occurred when sending an RDUserMessage. SessionHostName: " + $SessionHost.FQDN + " UserName: " + $_.UserName ) 
        }
    }

    # delay shutdown for users to sign off
    Write-Log ( "Waiting " + $ShutdownTimer + " seconds before shutdown" )
        if ( -not $TESTING_MODE ) { 
        
            Start-Sleep $ShutdownTimer 
        }
}

# Begins the scale down operation on a session host. Input is a session host collection.
Function Start-ScaleDown {

    if ( $OnlineSessionHostCount -le $MinSessionHost ) {
        Write-Log "Session hosts at minumum. Will not scale down"
        return
    }

    # finds the host with the least sessions
    $SessionHost = $SessionHostTable | Where-Object PowerOn |
        Sort-Object -Property CurrentSessions -Descending | Select-Object -Last 1

    if ( Test-ScaleDown $SessionHost ) {

        Write-Log ("Beginning scale down on " + $SessionHost.VMName )

        # disallow new connections
        Set-NewConnectionAllowed -SessionHost $SessionHost -Value No

        # notify users of shutdown and wait
        Send-UserMessage $SessionHost

        # shutdown session host
        Set-AzureVMPower -SessionHost $SessionHost -PowerState off
    }
    else {

        Write-Log ( "Test-ScaleDown returns 0. Scale down not committed on " + $SessionHost.VMName )
    }
    
    Write-Log "Scale down completed"
}

# Begins the scale up operation on a session host.
Function Start-ScaleUp {

    if ( $OnlineSessionHostCount -ge $CollectionConfiguration.Count ) {
        Write-Log "Session hosts at maximum. Will not scale up."
        return
    }

    # picks offline session host with highest relative weight
    $NextSessionHost = $SessionHostTable | Where-Object PowerOn -EQ 0 |
        Sort-Object -Property RelativeWeight -Descending |Select-Object -First 1

    Write-Log ( "Beginning scale up on " + $NextSessionHost.VMName )

    # turns on the first session host in the queue
    Set-AzureVMPower -SessionHost $NextSessionHost -PowerState 'On'

    # enables new connections to the session host
    Set-NewConnectionAllowed -SessionHost $NextSessionHost -Value Yes
}



# Estimate utlization after a scale down. Input is a session host object to be scaled down.
# returns 1 if scale down is viable, 0 if not.
Function Test-ScaleDown {
    param ( $SessionHost )

    $CurrentRatio = ($UserSessionList.Count.ToString() + "/" + 
        ($OnlineSessionHosts.SessionLimit | Measure-Object -Sum).Sum).ToString()

    Write-Log ( "Test-ScaleDown Current farm utilization is " + 
    (Get-FarmUtilization $OnlineSessionHosts) + "% : (" + $CurrentRatio + ")")
    
    # run calculations for environment where this session host is scaled down
    $NewSessionHostTable = $OnlineSessionHosts | Where-Object FQDN -NotContains $SessionHost.FQDN

    $NewFarmUtilization = Get-FarmUtilization $NewSessionHostTable

    $NewRatio = ($UserSessionList.Count.ToString() + "/" +
        (($NewSessionHostTable | Where-Object PowerOn).SessionLimit | Measure-Object -Sum).Sum).ToString()
       
    Write-Log ( "Estimated new farm utlization is " + $NewFarmUtilization + "% : (" + $NewRatio + ")")

    if ($NewFarmUtilization -ge $MaxUtilization) { 

        Write-Log "Scale down operation is not viable"
        return 0 
    }
    else {

        Write-Log "Scale down operation is viable"
        return 1
    }
}

# Get average utilization of session hosts in a collection. Input is collection configuration
# Returns average utilization of session hosts
Function Get-FarmUtilization {
    param ( [Array]$ServerCollection )

    $UserCount = $UserSessionList.Count
    $TotalSeats = ($ServerCollection.SessionLimit | Measure-Object -Sum).Sum
    return ( [Math]::Round( (($UserCount / $TotalSeats) * 100 | Measure-Object -Average).Average))
}

# Sets session host connection allowed setting, Input is a session host object and yes or no.
Function Set-NewConnectionAllowed {
    param ( $SessionHost,
            [String]$Value )
    
    try { 

        if ( -not $TESTING_MODE ) { 

            Write-Log ( "Setting new connection allowed on " + $SessionHost.FQDN + " to " + $Value )
            Set-RDSessionHost -SessionHost $SessionHost.FQDN -NewConnectionAllowed $Value -ConnectionBroker $ConnectionBroker
        }
        else {

            Write-Log ( "TESTING: setting new connection allowed on " + $SessionHost.FQDN + " to " + $Value )
        }
        # update session host table
        $SessionHost.NewConnectionsAllowed = if ($Value -like "yes") {1} else {0}
    }
    catch { 

        Write-Log ( "Error while setting NewConnectionAllowed setting for " + $SessionHost.FQDN ) 
    }
}



# ----------------------------------------------------------------------------------


# Gather environment information
# ----------------------------------------------------------------------------------

#create delimiter between script runs
Write-Log "-------------------------------------------------------------------------"

Write-Log "Getting Collection Configuration..."

$CollectionConfiguration = Get-RDSessionCollectionConfiguration -CollectionName $CollectionName -ConnectionBroker $ConnectionBroker -LoadBalancing |
                            Sort-Object -Property RelativeWeight -Descending

Write-Log "Getting Session Host Settings..."

$RDSessionHost = Get-RDSessionHost -CollectionName $CollectionName -ConnectionBroker $ConnectionBroker

Write-Log "Getting list of user sessions..."

$UserSessionList = Get-RDuserSession -CollectionName $CollectionName -ConnectionBroker $ConnectionBroker

Write-Log "Getting status of Azure virtual machines..."
$AzureVMList = Get-AzureRmVM -status | Where-Object {$_.Tags.Values -like $TagValues}

# Gets the resource group name from a session host.
$ResourceGroupName = $AzureVMList.ResourceGroupName[0]

# ----------------------------------------------------------------------------------


# Check session hosts and gather information
# ----------------------------------------------------------------------------------

# Create table of session hosts
try { $SessionHostTable.Clear() } catch {}
$SessionHostTable = New-Object System.Data.DataTable
$SessionHostTable.Columns.Add("FQDN", "string") | Out-Null
$SessionHostTable.Columns.Add("VMName", "string") | Out-Null
$SessionHostTable.Columns.Add("RelativeWeight", "int") | Out-Null
$SessionHostTable.Columns.Add("CurrentSessions", "int") | Out-Null
$SessionHostTable.Columns.Add("SessionLimit", "int") | Out-Null
$SessionHostTable.Columns.Add("Utilization", "int") | Out-Null
$SessionHostTable.Columns.Add("NewConnectionsAllowed", "int") | Out-Null
$SessionHostTable.Columns.Add("PowerOn", "int") | Out-Null

Write-Log "##"

ForEach ($SessionHost in $CollectionConfiguration) {

    $row = $SessionHostTable.NewRow()

    # populate table with data
    $row.FQDN = $SessionHost.SessionHost
    $row.VMName = $SessionHost.SessionHost.Split('.')[0]
    $row.RelativeWeight = $SessionHost.RelativeWeight
    $row.CurrentSessions = ($UserSessionList | Where-Object HostServer -Like $row.FQDN).Count
    $row.SessionLimit = $SessionHost.SessionLimit
    $row.Utilization = [Math]::Round( ( $row.CurrentSessions / $row.SessionLimit) * 100 )
    $row.NewConnectionsAllowed = if ( ($RDSessionHost | Where-Object SessionHost -Like $row.FQDN).NewConnectionAllowed -like "yes" ) {1} else {0}
    $row.PowerOn = if ( ($AzureVMList | Where-Object Name -Like $row.VMName).PowerState -Like '*running*') {1} else {0}

    $SessionHostTable.Rows.Add($row)

    # Check and correct any discrepencies
    # Check if session host is empty, not allowing new ones, and powered on
    if ( $row.CurrentSessions -lt 1 -and $row.NewConnectionsAllowed -eq 0 -and $row.PowerOn -eq 1 ) {

        Write-Log ( $row.VMName + " has no sessions, is not allowing new ones, yet powered on. Turning off now..." )
        Set-AzureVMPower -SessionHost $row -PowerState off
    }
}


# ----------------------------------------------------------------------------------


# Check online hosts and display statistics
# ----------------------------------------------------------------------------------


$OnlineSessionHosts = $SessionHostTable | Where-Object PowerOn
$OnlineSessionHostCount = ( $OnlineSessionHosts | Measure-Object ).Count
$AboveThresholdCount = 0
$BelowThresholdCount = 0

ForEach ($SessionHost in $OnlineSessionHosts ) {
    
    $Threshold = " "
    if ( $SessionHost.Utilization -ge $MaxUtilization ) {
       $Threshold = "+"
       $AboveThresholdCount = $AboveThresholdCount + 1
    }
    elseif ( $SessionHost.Utilization -le $MinUtilization ) {
        $Threshold = "-"
        $BelowThresholdCount = $BelowThresholdCount + 1
    }
  
    Write-Log ( $SessionHost.VMName + " Utlization is at " + $SessionHost.Utilization + "%" + 
            " : (" + $SessionHost.CurrentSessions + "/" + $SessionHost.SessionLimit + ") " + $Threshold )
}

Write-Log "##"

Write-Log ( "Current farm utilization is at " + (Get-FarmUtilization $OnlineSessionHosts) + "%" +
    " : (" + $UserSessionList.Count + "/" + ( $OnlineSessionHosts.SessionLimit | Measure-Object -Sum).Sum + ")" )

Write-Log ( $OnlineSessionHostCount.ToString() + " Session host(s) online" )
Write-Log ( "Total session hosts above threshold: " + $AboveThresholdCount )
Write-Log ( "Total session hosts below threshold: " + $BelowThresholdCount )

# ----------------------------------------------------------------------------------


# Scale up/down
# ----------------------------------------------------------------------------------

# if online session hosts below minumum set to be online. Shoudn't need this
if ( $OnlineSessionHostCount -lt $MinSessionHost ) {
    Write-Log "WARNING: Online session hosts have fallen below the minimum"
    Start-ScaleUp
}
# all session hosts above max threshold
elseif ( $AboveThresholdCount -ge $OnlineSessionHostCount ) {

    Write-Log "##"
    Start-ScaleUp
}
# farm utlilization below minimum or more session hosts below
# threshold than are above threshold
elseif( (Get-FarmUtilization  $OnlineSessionHosts) -le $MinUtilization -or
    $BelowThresholdCount -gt $AboveThresholdCount) {

    Write-Log "##"
    Start-ScaleDown
}

Write-Log "DONE"