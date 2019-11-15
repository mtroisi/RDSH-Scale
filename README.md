# RDSH-Scale
RDSH-Scale is a PowerShell script interacts with a Remote App deployment in Azure to scale the amount of online session hosts based on current usage. Usage is configured by setting the threshold percentages in the script.

## Purpose
The purpose of this script is to reduce the cost of having several session hosts active in Azure. There is no need for all session hosts to be online all the time if the user load operates in waves or cycles. Rather than power on and off hosts based on time of day, this script aims to be a more reliable method, dynamically scaling based of usage and not a fixed schedule.

## Usage
The host in which this script runs on needs to have the AzureRM PowerShell modules installed and configured for use. It is also recommended to have this script run on a host from within Azure. From experience, the runtime of this script is significantly decreased when run from the same location as the connection broker.

Once run the script will analyze the current session host usage and compare that with the configured parameters. If it is determined that the session hosts are underutilized or overutilized, session hosts will begin to power down or power on respectively. Users will be notified before a session host is turned off and a configurable delay will occur before the host is powered down.

It is recommended to run this script on a frequent schedule dependent upon the rate in which users sign on and sign off session hosts. In other words, you do not want users to be unable to log in due to not enough seats being available in the pool. This can be achieved by configuring a scheduled task to run every 5 minutes or so.

## Logging
By default, the script will output to both a log file and to console. A new log file is created each day in the log location configured. Log file name format is "yyyyMMdd.log" The log file will contain information into the current usage of each session host and check if each host is over or under the threshold. If a scale down or scale up occurs, that will also be logged along with any users that were logged off in the process.

## Configuration
The following variables are available to be configured:

`$TESTING_MODE`: If set, machines will not change power state, users will not be signed off, the environment will not change.

`$LogPath`: The folder in which log files are created.

`$LogFile`: The naming convention of the log files

`$ConnectionBroker`: The connection broker FQDN

`$CollectionName`: The collection name

`$TagValues`: Tag values assigned to session hosts in Azure so that the script can determine which hosts to use

`$MaxUtilization`: Percentage to consider a session host overutilized.

`$MinUtilization`: Percentage to consider a session host underutilized.

`$MinSessionHost`: Minimum amount of session hosts to always keep online, regardless of current usage.

`$ShutdownTimer`: Seconds to wait after sending user messages and before shutdown.

`$MessageTitle`: Title of the message displayed to users.

`$MessageBody`: Body of the message displayed to users.
