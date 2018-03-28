#requires -version 3.0

Import-Module multithreading -force
Import-module Windows\DomainInfo -force
import-module Windows\AccountInfo -force
import-module Windows\General -force
import-module Windows\ADSI -force
import-module password -force
import-module windows\securestring -force
import-module windows\filesystem -force

function Find-PotentialPtHEvents(){
<#
    .SYNOPSIS
    Determines if a network logon meets specific criteria that may have been a PtH login.

    .DESCRIPTION
    Find-PotentialPtHEvents iterates over all non-domain controllers registered within active directory and queries their event logs for specific network logon criteria that PtH logins meet. The criteria is as follows:
        network logon type == 3
        domain != domain name
        authentication mechanism == NTLM
        username != ANONYMOUS

    Each computer is contacted in parallel.  The current model pushes all of the work to the individual domain-joined machines from the invoking process. The invoker waits until the invokee finishes and returns the results. The length of time the process should take is dependent on the size of the event logs and whether or not some of the machines that are domain-joined are down.  In the case that a machine is down, the program will wait until a timeout occurs.   

    .PARAMETER ndays
    The number of days back to go in the event log.

    .PARAMETER interactive
    Returns the results to the pipeline interactively instead of pretty printing them to the screen.

    .EXAMPLE
    Find-PotentialPtHEvents

    Looks for PtH behavior in the event logs for the last 7 days.

    .EXAMPLE

    Find-PotentialPtHEvents -ndays 30

    Looks for PtH behavior in the event logs for the last 30 days.
#>
    [CmdletBinding(DefaultParameterSetName="All")]
    param(
        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="Single")]
            [int]$ndays=7,
        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="Single")]
            [switch]$interactive,
        
        [Parameter(Mandatory=$TRUE, ParameterSetName="Single")]
            [switch]$single,
        [Parameter(Mandatory=$TRUE, ParameterSetName="Single", ValueFromPipeline=$TRUE, position=1)]
            [string]$computerName,
        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="Single")]
            [string]$channelName="Security"
    )
    BEGIN{
        Test-Assert {(Test-ModuleExists multithreading) -eq $TRUE}
        $script:NSECS_IN_1_HOUR = 3600000
        $script:NSECS_IN_1_DAY = $script:NSECS_IN_1_HOUR * 24
    }
    PROCESS{
        $mgr = New-ParallelTaskManager
        try {
            $results = @{}
            
            $servers = $NULL
            if($PSCmdlet.ParameterSetName -eq "All"){
                $servers = @(Get-DomainComputersSansDomainControllers)
            }
            else{
                $servers = $computerName
            }
            
            $task = {
                param(
                    [Parameter(Mandatory=$TRUE)]
                        [string]$server, 
                    [Parameter(Mandatory=$TRUE)]
                        [string]$channelName,
                    [Parameter(Mandatory=$TRUE)] 
                        [int64]$nsecs
                )
                #$script:winXPLogonEvents = @{540="Success";528="Success";529="Failure"; 530="Failure"; 531="Failure"; 532="Failure"; 533="Failure"; 534="Failure"; 535="Failure";536="Failure";537="Failure";539="Failure"; }
                $script:winVistaPlusLogonEvents = @{4624="Success";4625="Failure"}
    
                function New-Result([string]$hostname, [string]$os, [DateTime]$TimeCreated, [int]$id, [string]$message, $event){
                    $result = "" | Select host, os, TimeCreated, Id, Message, Event
                    $result.host = $hostname
                    $result.os = $os
                    $result.timecreated = $timecreated
                    $result.id = $id
                    $result.message = $message
                    $result.event = $event
                    return $result
                }
    
                $domain = (([System.DirectoryServices.ActiveDirectory.domain]::GetCurrentDomain()).name).split(".")[0].toupper() #get ~NETBIOS name, which is how the event log stores the domain name
                $results = @()
                $os = $NULL
                try{
                    $os = Get-WmiObject -class Win32_OperatingSystem -cn $server
                    if($os){
                        #os will be null if Get-WMI fails...for any reason
                        Switch -regex ($os.Version){
                            #used to support xp classic event logs.
                            #moving away from it in further development
                            "^6`.*"
                            {
                                #vista+
                                #silently continue to suppress the error that is thrown
                                #if no events were found meeting our criteria
                                #$events = @(Get-WinEvent -ErrorAction SilentlyCOntinue -computerName $server -FilterXML "<QueryList><Query Id='0' Path='Security'><Select Path='Security'>*[(System[Provider[@Name='Microsoft-Windows-Security-Auditing']]) and (System[TimeCreated[timediff(@SystemTime) &lt;= $nsecs]]) and (System[EventID=4624] or System[EventID=4625]) and (EventData[Data[@Name='LogonType']='3' and Data[@Name='AuthenticationPackageName'] ='NTLM' and Data[@Name='TargetDomainName'] != '$domain' and Data[@Name='TargetUserName'] != 'ANONYMOUS LOGON' and Data[@Name='TargetUserName'] != '-']) ]</Select></Query></QueryList>")
                                $events = @(Get-WinEvent -ErrorAction SilentlyCOntinue -computerName $server -FilterXML "<QueryList><Query Id='0' Path='$channelName'><Select Path='$channelName'>*[(System[Provider[@Name='Microsoft-Windows-Security-Auditing']]) and (System[TimeCreated[timediff(@SystemTime) &lt;= $nsecs]]) and (System[EventID=4624] or System[EventID=4625]) and (EventData[Data[@Name='LogonType']='3' and Data[@Name='AuthenticationPackageName'] ='NTLM' and Data[@Name='TargetDomainName'] != '$domain' and Data[@Name='TargetUserName'] != 'ANONYMOUS LOGON']) ]</Select></Query></QueryList>")
                                
                                foreach($event in $events){
                                    $results += New-Result $server $os.version $event.timecreated $event.id $event.message $event
                                }
                                break
                            }
                            DEFAULT
                            {
                                Write-Error "UNSUPPORTED Operating system: $($os.version)"
                            }
                        }
                    }
                }
                catch{
                    Write-Error "Could not connect to server: $server"
                }
                Write-Output $results           
            }
            $nsecs = $script:NSECS_IN_1_DAY * $ndays
            foreach ($server in $servers){
                [void]$mgr.new_task($task, @($server, $channelName, $nsecs))
            }
            $results = $mgr.receive_alltasks()

            if($interactive){
                #return the results to the user
                Write-Output $results
            }
            else{
                #print out the results to the screen (Default)
                $results | Sort-Object TimeCreated -descending | format-table host, os, timecreated, id, message
                
            } 
        }
        catch [System.Exception]
        {
            Write-Host $_.Exception.Message
        }
        finally{
            $mgr = $NULL
        }
    }
    END{}
}

function Disable-NetworkLogonsForGroup(){
    param(
        [CmdletBinding()]
        
        [Parameter(Mandatory=$FALSE, ValueFromPipeline=$TRUE, position=1)]
            [string]$group,
        [Parameter(Mandatory=$FALSE)]
            [string]$computerName = $env:COMPUTERNAME,
        [Parameter(Mandatory=$FALSE)]
            [AllowEmptyString()]
            [string]$description=""
    )
    BEGIN{}

    PROCESS{
        if(Test-GroupExists -local -name $group -computerName $computerName){
            #could also do it this way.
            #Get-Group -local $group | Get-GroupMembers -local | foreach{Remove-GroupMember -local -group $group -user $_.name}
            Remove-Group -local -name $group -computerName $computerName
        }

        $adsiGroup = (New-Group -local -name $group -computerName $computerName -description $description)
        if((Test-ADSISuccess $adsiGroup) -eq $TRUE){
            $adminGroupName = Get-LocalAdminGroupName -computerName $computerName
            Get-Group -local -computerName $computerName $adminGroupName | Get-GroupMembers -local -computerName $computerName | foreach{(Add-GroupMember -local -group $group -user $_.name -computerName $computerName)} | Out-Null
            Write-Host "Successfully added local administrators to group $group on $computerName"
        }
    }
  
    END{}                              
}


function Invoke-DenyNetworkAccess(){
<#
    .SYNOPSIS
    Adds all local administrators to a specific group that can be used to deny them network access.
    
    .DESCRIPTION
    Interfaces with the cmdlet Disable-NetworkLogonsForGroup to provide the guidance given in the PtH paper. If the user wants a different group name, then they can call Disable-NetworkLogonsForGroup expclitly and provide a custom group name.
    
    .PARAMETER group
    [string] The group name to put all local admins in.

    .PARAMETER computername
    [string] The local computername to create the new group on.

    .PARAMETER description
    [string] The description of the group.
    
    .INPUTS
    [string] See <Computername>
    
    .OUTPUTS
    None.

    .EXAMPLE  
    Invoke-DenyNetworkAccess -group "DenyNetworkAccess" -computerName "host1" -description "Group used to remove network access to all local administrator."
#>            
    param(
        [CmdletBinding()]
        
        [Parameter(Mandatory=$FALSE)]
            [string]$group="DenyNetworkAccess",
        [Parameter(Mandatory=$FALSE, ValueFromPipeline=$TRUE, position=1)]
            [string]$computerName = $env:COMPUTERNAME,
        [Parameter(Mandatory=$FALSE)]
            [AllowEmptyString()]
            [string]$description=""       
    )
    BEGIN{}
    
    PROCESS{
        Disable-NetworkLogonsForGroup -group $group -computerName $computerName    -description $description
    }
    
    END{}                               
}



#script variables for Edit-AllLocalAccountPasswords
$script:MIN_REQUIRED_DISK_SPACE = 25mb


function Edit-AllLocalAccountPasswords(){
<#
    .SYNOPSIS
    Changes a local account password for an inputted list of domain-joined machines <machinesFilePath> or by automatically detecting all of the registered machines on the domain.  

    .DESCRIPTION
    This program changes a local account password for an inputted list of domain-joined machines <machinesFilePath> or by automatically detecting all of the registered machines on the domain. The length of the password is configurable by the <minPasswordLength> and <maxPasswordLength> parameters. If the -machinesFilePath switch is used, the program expects a file listing the hostnames, one on each line. Passwords are generated using the RNGCryptoServiceProvider .Net object. The local account (denoted by <localAccountName>) password is changed via the IADsUser interface.  If for any reason, the password change is unsuccessful, then the program will notify the user which machine names failed to have the account's password changed. Upon completion, the machine will have written a tab delimited file to the path of <outFilePath> with each line consisting of: <machineName> <localAccountName> <newPassword>. By default, the output must be saved to a USB drive, but this can be disabled with setting forceUSBKeyUsage to $FALSE.  It is recommended to run this script with a domain account.

    .PARAMETER machinesFilePath
    The path to a list of domain-joined machines to use for the password changing. The file is line delimited with each line consisting of a domain-joined machinename.

    .PARAMETER minPasswordLength
    The minimum password length (default value of 14) to use for the creation of the new password. Only used if random password is selected.

    .PARAMETER maxPasswordLength
    The maximum password length (default value of 25) to use for the creation of the new password. Only used if random password is selected.

    .PARAMETER maxThreads
    The maximum number of threads to attach to the runspace.

    .PARAMETER forceUSBKeyUsage
    Have the program ensure that the <outFilePath> location is on a USB drive (default value of true).

    .PARAMETER localAccountName
    The username for which the user desires to change the password.  

    .PARAMETER outFilePath
    The filename to use for writing the output (both successful and unsuccessful password changes).

    .NOTES
    Running this cmdlet in multithreaded mode will not get you realtime feedback to stdout.  Check the passwords.out and machinesNotChanged.out files to see the progress.  machinesNotChanged.out does not contain any machines that are unavailable, which are filtered out by Test-IsComputerAlive or Get-AllAliveComputers.

    .EXAMPLE
    Edit-AllLocalAccountPasswords -localAccountName test -outFilePath .\passwords.out

    Change the password for the local account name "test", in single threaded mode, and writing the output to the file passwords.out in the current working directory, where the current working directory must be on a usb drive. 

    .EXAMPLE
    Edit-AllLocalAccountPasswords -localAccountName test -outFilePath .\passwords.out -forceUSBKeyUsage $FALSE

    Change the password for the local accountname test and write the file to passwords.out in the current working directory, where the current workign directory does not require to be on a usb drive. 
#>
    [CmdletBinding(DefaultParameterSetName="All")]                                    
    param(
        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]
            [switch]$fast,

        [Parameter(Mandatory=$TRUE, ParameterSetName="multithreading")]
            [switch]$multithreaded,
    
        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]    
            [string]$machinesFilePath,


        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]
            [int]$minPasswordLength = 14,

        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]
            [int]$maxPasswordLength = 25,

        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]
            [int]$maxThreads = 20,

        [Parameter(Mandatory=$FALSE, ParameterSetName="All")]
        [Parameter(Mandatory=$FALSE, ParameterSetName="multithreading")]
            [bool]$forceUSBKeyUsage = $TRUE,

        [Parameter(Mandatory=$TRUE, ParameterSetName="All")]
        [Parameter(Mandatory=$TRUE, ParameterSetName="multithreading")]
            [string]$localAccountName,
        
        [Parameter(Mandatory=$TRUE, ParameterSetName="All")]
        [Parameter(Mandatory=$TRUE, ParameterSetName="multithreading")]
            [string]$outFilePath  
    )
    
    BEGIN{
        $machinesArray = $NULL
        $available = $NULL
        $unavailable = $NULL
        $errors = $NULL
        
        if($forceUSBKeyUsage -eq $TRUE){
            if((Test-ForceUSBKeyUsage $outFilePath) -eq $FALSE){
                #abort program.  The outfile path is not on a removable device
                throw "The outfile path is not on a removable device"
            }
        }
        if((Test-SufficientDiskSpace $outFilePath $script:MIN_REQUIRED_DISK_SPACE) -eq $FALSE){
            #see if volume contains enough space
            throw "disk does not have enough free space to save password file"
        }

        if(-not ([System.String]::IsNullOrEmpty($machinesFilePath))){
            if((Test-Path $machinesFilePath) -eq $FALSE){
                throw "$machinesFilePath does not exist"
            }
            $machinesArray = Get-Content $machinesFilePath
        }
        else{
            $machinesArray = @(Get-DomainComputersSansDomainControllers)
        }
        if($fast){
            if($multithreaded){
                $available = Get-AllComputersAlive -multithreaded -fast $machinesArray
                $unavailable = Get-SetDifference $machinesArray $available
            }
            else{
                $unavailable = @()
                $tempMachinesArray = @()
                foreach($m in $machinesArray){
                    if(Test-IsComputerAlive -fast $m){
                        $tempMachinesArray += $m
                    }
                    else{
                        $unavailable += $m
                    }
                }
                $available = $tempMachinesArray
                $tempMachinesArray = $NULL
                #===================================================================
                # Write-Host "************Unavailable**************"
                # $unavailable | foreach{Write-Host $_}
                # Write-Host "*************************************"
                #===================================================================
            }
        }
        else{
            $available = $machinesArray
        }
        #this should resolve to the locally defined Get-FunctionParameters
        $fargs = Get-FunctionParametersPTHTools "Invoke-PasswordChange"
        $fargs["multithreaded"] = $multithreaded.ispresent
        $fargs["machineNames"] = $available
    }
    PROCESS{
        $menu =
@"
`t1. Random passwords
`t2. Salt passwords.
`t3. Quit  
"@

        while($TRUE){
            Write-Host $menu
            $command = Read-Host "Enter command number"
            switch($command){
                1{
                    $fargs["random"] = [switch]$TRUE
                    [array]$errors = Invoke-PasswordChange @fargs
                    break
                }
                            
                2{
                    $fargs["salted"] = [switch]$TRUE
                    [array]$errors = Invoke-PasswordChange @fargs
                    break
                }
                            
                3{
                    break
                }
                default{
                    Write-Host "Invalid command $command"
                    break
                }
            }
            if($unavailable -gt 0){
                #unavailable hosts are only determined if the -fast option is on, which filters boxes that aren't responding to conventional probes
                Write-Host "`r`n*********Unavailable*************"
                $unavailable | foreach{Write-Host $_}
                Write-Host "****************************`r`n"
            }
            if($errors.count -gt 0){ 
                #anything that fails during run-time
                Write-Host "`r`n*********Errors*************"
                $errors | foreach {Write-Host $_} 
                Write-Host "****************************`r`n"
            }
                    
            break                   
        }   
    }
    END{}                                     
}

function Invoke-PasswordChange(){
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$TRUE, ParameterSetName="Random")]
            [switch]$random,
        [Parameter(Mandatory=$TRUE, ParameterSetName="Salted")]
            [switch]$salted,
        [Parameter(Mandatory=$FALSE)]
            [switch]$multithreaded,
        [Parameter(Mandatory=$TRUE)]
            [int]$minPasswordLength,
        [Parameter(Mandatory=$TRUE)]
            [int]$maxPasswordLength,
        [Parameter(Mandatory=$FALSE)]
            [int]$maxThreads,
        [Parameter(Mandatory=$TRUE)]
            [array]$machineNames,
        [Parameter(Mandatory=$TRUE)]
            [string]$localAccountName,
        [Parameter(Mandatory=$TRUE)]
            [string]$outFilePath
    )
                                
    $passwordsArray = @()
    if($random){
        #build up password array for random passwords
        foreach($m in $machineNames){
            $passwordLength = Get-Random -Minimum $minPasswordLength -Maximum ($maxPasswordLength+1); 
            $passwordsArray += (New-RandomPassword -length $passwordLength)
        }
    }
    else{
        #build up password array for salted passwords
    
        #read in the password from the user
        $password = Read-PasswordFromUser
        
        #prompt the user to see if they wanted the salt prepended or appended
        do{
            $cmd = (Read-Host "Enter location to place salt (p)repend or (a)ppend.").toLower()
        }while(($cmd -ne "a") -and ($cmd -ne "p"))

        #iterate over all machines and change the password for $machineName\$localAccountName
        foreach($name in $machineNames){
            $salt = $name.toLower()
            if($cmd -eq "p"){
                $saltedPassword = New-SecureStringPrependedWithString $salt $password                    
            }
            else{
                $saltedPassword = New-SecureStringAppendedWithString $salt $password
            }
            $passwordsArray += $saltedPassword
        }
    }
    Test-Assert {($passwordsArray).count -eq ($machineNames).count}
    if($multithreaded){
        Update-LocalAccountPasswordForAllHosts -multithreaded -localAccountName $localAccountName -machineNames $machineNames -passwords $passwordsArray -outFilePath $outFilePath
    }
    else{
        Update-LocalAccountPasswordForAllHosts -localAccountName $localAccountName -machineNames $machineNames -passwords $passwordsArray -outFilePath $outFilePath
    }                   
}

function Update-LocalAccountPasswordForAllHosts(){
    param(
        [Parameter(Mandatory=$FALSE)]
            [switch]$multiThreaded,
        [Parameter(Mandatory=$TRUE)]
            [array]$machineNames,
        [Parameter(Mandatory=$TRUE)]
            [array]$passwords,
        [Parameter(Mandatory=$TRUE)]
            [string]$localAccountName,
        [Parameter(Mandatory=$TRUE)]
            [string]$outFilePath        
    )
    $passwordFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($outFilePath)
    $errorFile = Join-Path (Split-Path $passwordFile -Parent) "machinesNotChanged.out"

    Out-File -FilePath $passwordFile > $NULL #clear file
    Out-File -FilePath $errorFile > $NULL #clear file

    if($multiThreaded){
        Update-LocalAccountPasswordForAllHostsMT -machineNames $machineNames -passwords $passwords -localAccountName $localAccountName -passwordFile $passwordFile -errorFile $errorFile
    }        
    else{
        Update-LocalAccountPasswordForAllHostsST -machineNames $machineNames -passwords $passwords -localAccountName $localAccountName -passwordFile $passwordFile -errorFile $errorFile  
    }                                
}

function Update-LocalAccountPasswordForAllHostsMT(){
    param(
        [Parameter(Mandatory=$TRUE)]
            [array]$machineNames,
        [Parameter(Mandatory=$TRUE)]
            [array]$passwords,
        [Parameter(Mandatory=$TRUE)]
            [string]$localAccountName,
        [Parameter(Mandatory=$TRUE)]
            [string]$passwordFile,
        [Parameter(Mandatory=$TRUE)]
            [string]$errorFile      
    )
    try{
        $mgr = New-ParallelTaskManager $maxThreads
        
        $setPasswordSB = {
            #script block for threaded password changing
            #get local information through WinNT provider and change password
            #through iADSuser interface.  Output successful pw changes to
            #$outFilePath and unsuccessful changes to $errorPath and console
            param(
                [string]$machineName,
                [System.Security.SecureString]$password,
                [string]$localAccountName,
                [string]$passwordFile,
                [string]$errorFile
            )
            Import-module Windows\DomainInfo -force
            import-module Windows\AccountInfo -force
            import-module Windows\General -force
            import-module Windows\ADSI -force
            import-module password -force
            import-module windows\securestring -force
            import-module windows\filesystem -force
            
            function Append-FileThreadSafe($filepath, $data){
                #appends $data to the file located at $filepath in a threadsafe
                #manner.  This script uses a global semaphore for mutual exclusion
                $sem = New-Object -TypeName System.Threading.Semaphore(1,1,"Global\PWSem")
                [void]$sem.waitOne()
                try{

                    Out-File -FilePath $filepath -InputObject $data -Append > $NULL
                }
                finally{
                    [void]$sem.release()
                    $sem = $NULL
                }
            }
            function Format-ErrorMessage($errorMessage){
                if($errorMessage){
                    $msg = $errorMessage.split(":")
                    Write-Output (($errormessage.split(":"))[1].replace('"', "").trim())
                }
            }
            function Edit-LocalAccountPassword(){
                param(
                    [Parameter(Mandatory=$TRUE)]
                    [AllowNull()]
                        [ADSI]$account,
                    [Parameter(Mandatory=$TRUE)]
                        [System.Security.SecureString]$password
                )

                if(Test-ADSISuccess $account){
                    $account.setPassword((ConvertFrom-SecureStringToBStr $password))
                    if($?){
                        $account.setInfo()
                        if($?){
                            return $TRUE
                        }
                        else{
                            throw "could not set the password for account $account"
                        }
                    }

                    else{
                        throw "could not set the password for account $account"
                    }
                }
                return $FALSE
            }
            try{
                $success = Edit-LocalAccountPassword (Get-User -local -name $localAccountName -computerName $machineName) ($password)
                if($success){
                    $output = "$machineName`t`t$localAccountName`t`t$(ConvertFrom-SecureStringToBStr $password)"
                    Write-Output $outpu
                    Append-FileThreadSafe $passwordFile $output
                }
                else{
                    throw [System.InvalidOperationException]
                }
            }
            catch [Exception] {
                Append-FileThreadSafe $errorFile $machineName
                $error | foreach{Format-ErrorMessage $($_.Exception.message)}  | foreach{Write-Output "Error changing password for $machineName`: $_"}
                
            } 
        }        
        for($i=0; $i -lt $machineNames.count; $i++ ){
            #iterate over all machine names and change password
            [void]$mgr.new_task($setPasswordSB, @($machineNames[$i], $passwords[$i], $localAccountName, $passwordFile, $errorFile))
        }
        $output = $mgr.receive_alltasks()
        [array]$errors = $output | where {$_ -ne $NULL}
        return $errors  
    }
    finally{
        $jobs = $NULL
    }                                  
}

function Update-LocalAccountPasswordForAllHostsST(){
    param(
        [Parameter(Mandatory=$TRUE)]
            [array]$machineNames,
        [Parameter(Mandatory=$TRUE)]
            [array]$passwords,
        [Parameter(Mandatory=$TRUE)]
            [string]$localAccountName,
        [Parameter(Mandatory=$TRUE)]
            [string]$passwordFile,
        [Parameter(Mandatory=$TRUE)]
            [string]$errorFile            
    )
    for($i=0; $i -lt $machineNames.count; $i++){
        try{
            $success = Edit-LocalAccountPassword (Get-User -local -name $localAccountName -computerName $machineNames[$i]) ($passwords[$i])
            if($success){
                $output = "$($machineNames[$i])`t`t$localAccountName`t`t$(ConvertFrom-SecureStringToBStr ($passwords[$i]))"
                Out-File -FilePath $passwordFile -InputObject $output -Append | Out-Null
                Write-Host "Password successfully changed on $($machineNames[$i]) for $($machineNames[$i])\$localAccountName"
            }
            else{
                throw [System.InvalidOperationException]
            }
        }
        catch [Exception] {
            $message = "Error changing password on $($machineNames[$i]) for $($machineNames[$i])\$localAccountName"
            Write-Output $message
            Out-File -FilePath $errorFile -InputObject $machineNames[$i] -Append
        } 
    }
}

function Edit-LocalAccountPassword(){
    param(
        [Parameter(Mandatory=$TRUE)]
        [AllowNull()]
            [ADSI]$account,
        [Parameter(Mandatory=$TRUE)]
            [System.Security.SecureString]$password
    )
                        
    if(Test-ADSISuccess $account){
        
        $account.setPassword((ConvertFrom-SecureStringToBStr $password))
        if($?){
            $account.setInfo()
            if($?){
                return $TRUE
            }
            else{
                throw "could not set the password for account $account"
            }
        }
        else{
            throw "could not set the password for account $account"
        }

    }
    return $FALSE
}

function Test-ForceUSBKeyUsage(){
    param(
        [Parameter(Mandatory=$TRUE, position=1)]
            [string]$outFilePath
    )
    if($(Test-isPathOnUSBDrive $outFilePath) -eq $FALSE){
        return $FALSE
        
    }
    return $TRUE                             
}



function Get-FunctionParametersPTHTools(){
    param(
        [string]$_function
    )
    $result = New-Object "System.collections.Generic.Dictionary[System.String, System.Object]"
    
    $cmd = Get-command $_function 
    foreach($key in $cmd.Parameters.keys){
        $metadata = $cmd.parameters.item($key)
        try{
            $value = (Get-Variable -ErrorAction Stop -errorvariable "fpErr" -scope 1 $key).value
            if($value -or $metadata.attributes.typeid.name -eq $script:ALLOW_EMPTY_STRING_ATTR){
                $result.add($key, $value)
            }
        }
        catch [System.Management.Automation.ItemNotFoundException]{
        #    Write-Host "CANNOT FIND PARAMETER: $key for function $_function"
        }
    }
    return $result
}

function Get-SetDifference(){
    param(
        [array]$lhs,
        [array]$rhs
    )
    #convert $rhs to a dictionary and then test if something in $lhs is not in $rhs.
    $table = New-Object System.Collections.Hashtable
    $rhs | foreach{$table.add($_, $TRUE)}

    $difference = @()
    foreach($ele in $lhs){
        if(-not ($table.containsKey($ele))){
            $difference += $ele
        }
    }
    return $difference
}

function Get-LocalAccountSummaryOnDomain(){
    [CmdletBinding()]
    param()

    BEGIN{
    }
    PROCESS{        
        $localAccountMgr = New-ParallelTaskManager 25
        $adminAccountMgr = New-ParallelTaskManager 25
        try{
            $machinesArray = @(Get-DomainComputersSansDomainControllers)
            
            $localAccountSB = {
                param(
                    [string]$computername=$env:COMPUTERNAME
                )
                import-module Windows\AccountInfo -force
                $localAccount = New-Object PSObject
                $localAccount | add-member -membertype noteproperty "host" $computername
                try{
                    $accountNames = (Get-Group -local -computerName $computername | Get-GroupMembers -local -computerName $computername).name
                    $localAccount | add-member -membertype noteproperty "accountNames" $($accountNames | Sort-Object)        
                }
                catch{
                    Write-Output "Host $computername is unavailable"
                    Write-output $error
                    Write-Output "`r`nException $($_.exception.toString()) occurred getting Local Admin Accounts on host: $machineName"
                }
                finally{
                    $localAccount
                }
            }
            
            $adminAccountSB = {
                param(
                    [string]$computername=$env:COMPUTERNAME
                )
                import-module Windows\AccountInfo -force
                $adminAccounts = New-Object PSObject
                $adminAccounts | add-member -membertype noteproperty "host" $computername
                try{
                    $accountNames = ((Get-Group -local -name $(Get-LocalAdminGroupName) -computerName $computername) | Get-GroupMembers -local -computerName $computername).name
                    $adminAccounts | add-member -membertype noteproperty "accountNames" $($accountNames | Sort-Object)        
                }
                catch{
                    Write-Output "Host $computername is unavailable"
                    Write-output $error
                    Write-Output "`r`nException $($_.exception.toString()) occurred getting Local Admin Accounts on host: $machineName"
                }
                finally{
                    $adminAccounts
                }
            }
            
            foreach($m in $machinesArray){
                [void]$localAccountMgr.new_task($localAccountSB, @($m))
                [void]$adminAccountMgr.new_task($adminAccountSB, @($m))
            }
            
            $accountOutput = $localAccountMgr.receive_alltasks()
            $adminOutput = $adminAccountMgr.receive_allTasks()
            
            $currFormatEnumerationLimit = $global:formatEnumerationLimit
            $global:formatEnumerationLimit = -1
            Write-Host "*****Summary of Local Accounts*****"
            #$accountOutput | where {$_.accountnames -ne $NULL} | Select host, accountnames | sort host | group -property accountnames  | Sort -descending count | format-table @{Label="Count";Expression={$_.count};Width=15;Alignment="Left"}, @{label='Host';Expression={$_.group.host};Width=50}, @{label='Local Accounts';Expression={$_.group.accountnames | Sort -unique }} -wrap 
            $accountOutput | where {$_.accountnames -ne $NULL} | Select host, accountnames |  group -property accountnames  | Sort -descending count | format-table  @{label='Host';Expression={$_.group[0].host};Alignment="Left";Width=50}, @{label='Local Accounts';Expression={$_.group[0].accountnames | Sort -unique }} -wrap | Out-Host
            Write-Host "***********************************"
            
            Write-Host "*****Summary of Local Admin Accounts*****"
            $adminOutput | where {$_.accountnames -ne $NULL} | Select host, accountnames | group -property accountnames | Sort -descending count | format-table @{label='Host';Expression={$_.group | foreach{$_.host}};Alignment="Left";Width=50}, @{label='Admin Accounts';e={$_.group[0].accountnames | Sort -unique}} -wrap | Out-Host
            Write-Host "*****************************************"
            
            Write-Host "*****Unique Local Accounts*****"
            $accountOutput | foreach{$_.accountNames} | Sort -unique | Out-Host
            Write-Host "*******************************"
            
            Write-Host "*****Unique Admin Accounts*****"
            $adminOutput | foreach{$_.accountNames} | Sort -unique | Out-Host
            Write-Host "*******************************"
            
            Write-Host "*****Unavailable Hosts*****"
            $accountOutput | Where {$_.accountnames -eq $NULL} | foreach{$_.host} | Out-Host
            Write-Host "***************************" 
            $global:formatEnumerationLimit = $currFormatEnumerationLimit 
        }
        finally{
            $localAccountMgr = $NULL
            $adminAccountMgr = $NULL
        }
    }
    END{}
}

function Invoke-SmartcardHashRefresh() {
<#
    .SYNOPSIS
    Changes the hash for any Active Directory accounts that require smartcards for login.  

    .DESCRIPTION
    Changes the hash for any Active Directory accounts that require smartcards for login.

    .PARAMETER User
    The samAccountName or distinguishedName of the user(s) to reset smartcard hashes for.

    .PARAMETER Group
    The samAccountName or distinguishedName of the group(s) containing users to reset smartcard hashes for.

    .PARAMETER OU
    The distinguishedName of the organizational unit(s) containing hashes to reset smartcard hashes for.

    .PARAMETER Container
    The distinguishedName of the container(s) containing hashes to reset smartcard hashes for.

    .PARAMETER AlwaysUpdatePasswordLastSet
    Always update the password last set property's timestamp even if the account has the password never expires flag enabled.

    .PARAMETER Evict
    Refresh the password hash two times to force active accounts to get locked out for an eviction operation.

    .EXAMPLE
    Invoke-SmartcardHashRefresh

    .EXAMPLE
    Invoke-SmartcardHashRefresh -Verbose -WhatIf

    .EXAMPLE
    Invoke-SmartcardHashRefresh -User 'scuser1',scuser2' -Verbose

    .EXAMPLE
    Invoke-SmartcardHashRefresh -User 'scuser1' -AlwaysUpdatePasswordLastSet -Verbose

    .EXAMPLE
    Invoke-SmartcardHashRefresh -Group 'scgroup1' -Verbose

    .EXAMPLE
    Invoke-SmartcardHashRefresh -OU 'OU=Smartcard Users,OU=Domain Users,DC=test,DC=net' -Verbose

    .EXAMPLE
    Invoke-SmartcardHashRefresh -User 'CN=Users,DC=test,DC=net' -Verbose

#>
    [CmdletBinding(SupportsShouldProcess=$true)]
    [OutputType([void])]
    Param(
        [Parameter(Position=0, Mandatory=$false, HelpMessage='The samAccountName or distinguishedName of the user(s) to reset smartcard hashes for')]
        [ValidateNotNullOrEmpty()]
        [string[]]$User,

        [Parameter(Position=1, Mandatory=$false, HelpMessage='The samAccountName or distinguishedName of the group(s) containing users to reset smartcard hashes for')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Group,

        [Parameter(Position=2, Mandatory=$false, HelpMessage='The distinguishedName of the organizational unit(s) containing hashes to reset smartcard hashes for')]
        [ValidateNotNullOrEmpty()]
        [string[]]$OU,

        [Parameter(Position=3, Mandatory=$false, HelpMessage='The distinguishedName of the container(s) containing hashes to reset smartcard hashes for')]
        [ValidateNotNullOrEmpty()]
        [string[]]$Container,

        [Parameter(Position=4, Mandatory=$false, HelpMessage='Always update the password last set property even if the account has the password never expires flag enabled')]
        [ValidateNotNullOrEmpty()]
        [switch]$AlwaysUpdatePasswordLastSet,

        [Parameter(Position=5, Mandatory=$false, HelpMessage='Refresh the password hash two times to force active accounts to get locked out for an eviction operation')]
        [ValidateNotNullOrEmpty()]
        [switch]$Evict
    
    )
    
    Import-Module ActiveDirectory -Verbose:$false

    $parameters = $PSBoundParameters

    $properties = [string[]]@('PasswordLastSet','PasswordNeverExpires','SamAccountName','SmartcardLogonRequired')

    if ($parameters.ContainsKey('User')) {
        $validUsers = New-Object System.Collections.Generic.List[string]
        $User | Select-Object -Unique | ForEach-Object { try { Get-ADUser -Identity $_ | Out-Null; $validUsers.Add($_) } catch {} } 

        $users = $validUsers | ForEach-Object { Get-ADUser -Identity $_ -Properties $properties } # can't use -Filter and -Identity together
    } elseif ($parameters.ContainsKey('Group')) {
        $validGroups = New-Object System.Collections.Generic.List[string]
        $Group | Select-Object -Unique | ForEach-Object { try { Get-ADGroup -Identity $_ | Out-Null; $validGroups.Add($_) } catch {} } 

        $users = $validGroups | ForEach-Object { Get-ADGroupMember -Identity $_ -Recursive | ForEach-Object { Get-ADUser -Identity $_ -Properties $properties } } # can't use -Filter and -Identity together
    } elseif ($parameters.ContainsKey('OU')) { # could collapse OU and Container into same case since Test-Path works for either one 
        $validOUs = New-Object System.Collections.Generic.List[string]
        $OU | Select-Object -Unique | ForEach-Object { try { Get-ADOrganizationalUnit -Identity $_ | Out-Null; $validOUs.Add($_) } catch {} } 

        $users = $validOUs | ForEach-Object { Get-ADUser -Filter 'SmartcardLogonRequired -eq $true' -Properties $properties -SearchScope Subtree -SearchBase $_ }
    } elseif ($parameters.ContainsKey('Container')) {
        $validContainers = New-Object System.Collections.Generic.List[string]
        $Container | Select-Object -Unique | ForEach-Object { if (Test-Path "AD:\$_"){ $validContainers.Add($_) } } | Out-Null # could collapse OU and Container into same case since Test-Path works for either one 

        $users = $validContainers | ForEach-Object { Get-ADUser -Filter 'SmartcardLogonRequired -eq $true' -Properties $properties -SearchScope Subtree -SearchBase $_ }
    } else {
        $users = Get-ADUser -Filter 'SmartcardLogonRequired -eq $true' -Properties $properties
    }

    # the Group case uses -Recursive so it is possible for a user to be repeated so use Select-Object -Unique to filter out repeats
    # not all cases (User and Group) can use -Filter so use Where-Object to include only smartcard enabled logins
    $users | Select-Object -Unique | Where-Object  { $_.SmartcardLogonRequired -eq $true } | ForEach-Object {
        # ChangePasswordAtLogon cannot be set to $true or 1 for an account that also has the PasswordNeverExpires property set to true.
        if (-not($_.PasswordNeverExpires) -or $AlwaysUpdatePasswordLastSet) {
            #$originalValue = $_.PasswordLastSet -eq 0

            if ($AlwaysUpdatePasswordLastSet) {
                Set-ADUser -Identity $_ -PasswordNeverExpires $false
            }

            Set-ADUser -Identity $_ -ChangePasswordAtLogon $true
            Set-ADUser -Identity $_ -ChangePasswordAtLogon $false

            if ($AlwaysUpdatePasswordLastSet) {
                Set-ADUser -Identity $_ -PasswordNeverExpires $true
            }
        } else {
            Write-Warning -Message ('Skipped updating the password last set property for user with login name of {0} because their password never expires. Use the AlwaysUpdatePasswordLastSet option to force an update to the password last set property' -f  $_.SamAccountName)
        }

        Set-ADUser -Identity $_ -SmartcardLogonRequired $false
        Set-ADUser -Identity $_ -SmartcardLogonRequired $true

        if ($Evict) { 
            Set-ADUser -Identity $_ -SmartcardLogonRequired $false   #added by Ryan because I'm not sure a true/true does a flip
            Set-ADUser -Identity $_ -SmartcardLogonRequired $true
        }

        Write-Verbose -Message ('Refreshed smartcard hash for user with login name {0}' -f  $_.SamAccountName)
    }
}

function Find-OldSmartcardHash() {
<#
    .SYNOPSIS
        Finds smartcard users whose Active Directory account's hash is over a certain age. 

    .DESCRIPTION
        Outputs smartcard users and the number of days when their password was last set,
        where the password was last set more than a specified number of days ago
        (or 60 days by default).

    .PARAMETER limit
        The threshold number of days, over which smartcard users require a hash refresh.
        Default is 60 days. 

    .EXAMPLE
        Find-OldSmartcardHash
        Outputs the account names and number of days since the hash was last changed, 
        for all smartcard users who have not had their hash changed in 60 days.

    .EXAMPLE
        Find-OldSmartcardHash 30
        Outputs the account names and number of days since the hash was last changed, 
        for all smartcard users who have not had their hash changed in 30 days.

    .EXAMPLE
        Find-OldSmartcardHash | Out-File C:\Users\user\Desktop\outputfile.out
        Outputs to the file 'C:\Users\user\Desktop\outputfile.out' the account names 
        and number of days since the hash was last changed, for all smartcard users 
        who have not had their hash changed in 60 days.
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
            [int]$limit = 60
    )

    Import-Module ActiveDirectory -Verbose:$false

    # Confirm running with elevated privileges
    $principal = [System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = [System.Security.Principal.WindowsBuiltInRole]::Administrator

    if(-not ($principal.IsInRole($admin))) { 
        # might not see all smartcard users
        Write-Warning "Find-OldSmartcardHash is not running with elevated privileges."
    }
    
    # get AD users who need a smartcard to logon
    $properties = [string[]]@("PasswordLastSet", "SamAccountName", "SmartcardLogonRequired")
    $users = Get-ADUser -Filter {SmartcardLogonRequired -eq $true} -Properties $properties
    
    if($users -ne $null) {
        $users | ForEach-Object {

            # pwdLastSet could be never; ignore - no warning 
            if($_.PasswordLastSet -ne $null) {

                # find the difference between current time and the time the hash was last refreshed
                $diff = (Get-Date) - ($_.PasswordLastSet)

                if($diff.TotalDays -gt $limit) {
                    Write-Output ("{0} {1}" -f $_.SamAccountName, [int]$diff.TotalDays)
                }
            }
        }
    }
}
