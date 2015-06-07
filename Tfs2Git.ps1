# Script that copies the history of an entire Team Foundation Server repository to a Git repository.
# Original author: Wilbert van Dolleweerd (wilbert@arentheym.com)
#
# Contributions from:
# - Patrick Slagmeulen
# - Tim Kellogg (timothy.kellogg@gmail.com)
#
# Assumptions:
# - MSysgit is installed and in the PATH 
# - Team Foundation commandline tooling is installed and in the PATH (tf.exe)

Param
(
	[Parameter(Mandatory = $True)]
	[string]$TFSRepository,
	[string]$GitRepository = "ConvertedFromTFS",
	[string]$WorkspaceName = "TFS2GIT",
	[int]$StartingCommit,
	[int]$EndingCommit,
	[string]$UserMappingFile
)

function CheckPath([string]$program) 
{
	$count = (gcm -CommandType Application $program -ea 0 | Measure-Object).Count
	if($count -le 0)
	{
		Write-Host "$program must be found in the PATH!"
		Write-Host "Aborting..."
		exit
	}
}

# Do some sanity checks on specific parameters.
function CheckParameters
{
	# If Starting and Ending commit are not used, simply ignore them.
	if (!$StartingCommit -and !$EndingCommit)
	{
		return;
	}

	if (!$StartingCommit -or !$EndingCommit)
	{
		Write-Host "You must supply values for both parameters StartingCommit and EndingCommit"
		Write-Host "Aborting..."
		exit
	}

	if ($EndingCommit -le $StartingCommit)
	{
		if ($EndingCommit -eq $StartingCommit)
		{
			Write-Host "Parameter StartingCommit" $StartingCommit "cannot have the same value as the parameter EndingCommit" $EndingCommit
			Write-Host "Aborting..."
			exit
		}

		Write-Host "Parameter EndingCommit" $EndingCommit "cannot have a lower value than parameter StartingCommit" $StartingCommit
		Write-Host "Aborting..."
		exit
	}
}

# When doing a partial import, check if specified commits are actually present in the history
function AreSpecifiedCommitsPresent([array]$ChangeSets)
{
	[bool]$StartingCommitFound = $false
	[bool]$EndingCommitFound = $false
	foreach ($ChangeSet in $ChangeSets)
	{
		if ($ChangeSet -eq $StartingCommit)
		{
			$StartingCommitFound = $true
		}
		if ($ChangeSet -eq $EndingCommit)
		{
			$EndingCommitFound = $true
		}
	}

	if (!$StartingCommitFound -or !$EndingCommitFound)
	{
		if (!$StartingCommitFound)
		{
			Write-Host "Specified starting commit" $StartingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your starting commit parameter."
		}
		if (!$EndingCommitFound)
		{
			Write-Host "Specified ending commit" $EndingCommit "was not found in the history of" $TFSRepository
			Write-Host "Please check your ending commit parameter."			
		}

		Write-Host "Aborting..."		
		exit
	}
}

# Build an array of changesets that are between the starting and the ending commit.
function GetSpecifiedRangeFromHistory
{
	$ChangeSets = GetAllChangeSetsFromHistory

	# Create an array
	$FilteredChangeSets = @()

	foreach ($ChangeSet in $ChangeSets)
	{
		if (($ChangeSet -ge $StartingCommit) -and ($ChangeSet -le $EndingCommit))
		{
			$FilteredChangeSets = $FilteredChangeSets + $ChangeSet
		}
	}

	return $FilteredChangeSets
}


function GetTemporaryDirectory
{
	return $env:temp + "\workspace"
}

# Creates a hashtable with the user account name as key and the name/email address as value
function GetUserMapping
{
	if (!(Test-Path $UserMappingFile))
	{
		Write-Host "Could not read user mapping file" $UserMappingFile
		Write-Host "Aborting..."
		exit
	}	

	$UserMapping = @{}

	Write-Host "Reading user mapping file" $UserMappingFile
	Get-Content $UserMappingFile | foreach { [regex]::Matches($_, "^([^=#]+)=(.*)$") } | foreach { $userMapping[$_.Groups[1].Value] = $_.Groups[2].Value }
	foreach ($key in $userMapping.Keys) 
	{
		Write-Host $key "=>" $userMapping[$key]
	}

	return $UserMapping
}

function PrepareWorkspace
{
	$TempDir = GetTemporaryDirectory

	# Remove the temporary directory if it already exists.
	if (Test-Path $TempDir)
	{
		remove-item -path $TempDir -force -recurse		
	}
	
	md $TempDir | Out-null

	# Create the workspace and map it to the temporary directory we just created.
	tf workspace /delete $WorkspaceName /noprompt
	tf workspace /new /noprompt /comment:"Temporary workspace for converting a TFS repository to Git" $WorkspaceName
	tf workfold /unmap /workspace:$WorkspaceName $/
	tf workfold /map /workspace:$WorkspaceName $TFSRepository $TempDir
}


# Retrieve the history from Team Foundation Server, parse it line by line, 
# and use a regular expression to retrieve the individual changeset numbers.
function GetAllChangesetsFromHistory 
{
	$HistoryFileName = "history.txt"

	tf history $TFSRepository /recursive /noprompt /format:brief | Out-File $HistoryFileName

	# Necessary, because Powershell has some 'issues' with current directory. 
	# See http://huddledmasses.org/powershell-power-user-tips-current-directory/
	$FileWithCurrentPath =  (Convert-Path (Get-Location -PSProvider FileSystem)) + "\" + $HistoryFileName 
	
	$file = [System.IO.File]::OpenText($FileWithCurrentPath)
	# Skip first two lines 
	$line = $file.ReadLine()
	$line = $file.ReadLine()

	while (!$file.EndOfStream)
	{
		$line = $file.ReadLine()
		# Match digits at the start of the line
		$num = [regex]::Match($line, "^\d+").Value
		$ChangeSets = $ChangeSets + @([System.Convert]::ToInt32($num))
	}
	$file.Close()

	# Sort them from low to high.
	$ChangeSets = $ChangeSets | Sort-Object			 

	return $ChangeSets
}

# Actual converting takes place here.
function Convert ([array]$ChangeSets)
{
	$TemporaryDirectory = GetTemporaryDirectory

	# Initialize a new git repository.
	Write-Host "Creating empty Git repository at", $TemporaryDirectory
	git init $TemporaryDirectory

	# Let git disregard casesensitivity for this repository (make it act like Windows).
	# Prevents problems when someones only changes case on a file or directory.
	git config core.ignorecase true

	# If we use this option, read the usermapping file.
	if ($UserMappingFile)
	{
		$UserMapping = GetUserMapping
	}

	Write-Host "Retrieving sources from", $TFSRepository, "in", $TemporaryDirectory

	[bool]$RetrieveAll = $true
	foreach ($ChangeSet in $ChangeSets)
	{
		# Retrieve sources from TFS
		Write-Host "Retrieving changeset", $ChangeSet

		if ($RetrieveAll)
		{
			# For the first changeset, we have to get everything.
			tf get $TemporaryDirectory /force /recursive /noprompt /version:C$ChangeSet | Out-Null
			$RetrieveAll = $false
		}
		else
		{
			# Now, only get the changed files.
			tf get $TemporaryDirectory /recursive /noprompt /version:C$ChangeSet | Out-Null
		}


		# Add sources to Git
		Write-Host "Adding commit to Git repository"
		pushd $TemporaryDirectory
		git add --all | Out-Null
		$CommitMessageFileName = "commitmessage.txt"
		GetCommitMessage $ChangeSet $CommitMessageFileName

		# We don't want the commit message to be included, so we remove it from the index.
		# Not from the working directory, because we need it in the commit command.
		git rm $CommitMessageFileName --cached --force		

		$CommitMsg = Get-Content $CommitMessageFileName		
		$Match = ([regex]'User: (\S+)').Match($commitMsg)
		if ($UserMapping.Count -gt 0 -and $Match.Success -and $UserMapping.ContainsKey($Match.Groups[1].Value)) 
		{	
			$Author = $userMapping[$Match.Groups[1].Value]
			Write-Host "Found user" $Author "in user mapping file."
			git commit --file $CommitMessageFileName --author $Author | Out-Null									
		}
		else 
		{	
			if ($UserMappingFile)
			{
				$GitUserName = git config user.name
				$GitUserEmail = git config user.email				
				Write-Host "Could not find user" $Match.Groups[1].Value "in user mapping file. The default configured user" $GitUserName $GitUserEmail "will be used for this commit."
			}
			git commit --file $CommitMessageFileName | Out-Null
		}
		popd 
	}
}

# Retrieve the commit message for a specific changeset
function GetCommitMessage ([string]$ChangeSet, [string]$CommitMessageFileName)
{	
	tf changeset $ChangeSet /noprompt | Out-File $CommitMessageFileName -encoding utf8
}

# Clone the repository to the directory where you started the script.
function CloneToLocalBareRepository
{
	$TemporaryDirectory = GetTemporaryDirectory

	# If for some reason, old clone already exists, we remove it.
	if (Test-Path $GitRepository)
	{
		remove-item -path $GitRepository -force -recurse		
	}
	git clone --bare $TemporaryDirectory $GitRepository
	$(Get-Item -force $GitRepository).Attributes = "Normal"
	Write-Host "Your converted (bare) repository can be found in the" $GitRepository "directory."
}

# Clean up leftover directories and files.
function CleanUp
{
	$TempDir = GetTemporaryDirectory

	Write-Host "Removing workspace from TFS"
	tf workspace /delete $WorkspaceName /noprompt

	Write-Host "Removing working directories in" $TempDir
	Remove-Item -path $TempDir -force -recurse

	# Remove history file
	Remove-Item "history.txt"
}

# This is where all the fun starts...
function Main
{
	#CheckPath("git.cmd")
	CheckPath("git.exe")
	CheckPath("tf.exe")
	CheckParameters
	PrepareWorkspace

	if ($StartingCommit -and $EndingCommit)
	{
		Write-Host "Filtering history..."
		AreSpecifiedCommitsPresent(GetAllChangeSetsFromHistory)
		Convert(GetSpecifiedRangeFromHistory)
	}
	else
	{
		Convert(GetAllChangeSetsFromHistory)
	}

	CloneToLocalBareRepository
	CleanUp

	Write-Host "Done!"
}

Main

# SIG # Begin signature block
# MIINIgYJKoZIhvcNAQcCoIINEzCCDQ8CAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQU3vnVGAIH2QmCnXSSx9aLDymq
# ftegggpkMIIFLDCCBBSgAwIBAgIQCJmU9t5nNfz0ZmBttmJmhTANBgkqhkiG9w0B
# AQsFADByMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFz
# c3VyZWQgSUQgQ29kZSBTaWduaW5nIENBMB4XDTE1MDUyMTAwMDAwMFoXDTE4MDcy
# NDEyMDAwMFowczELMAkGA1UEBhMCVVMxETAPBgNVBAgTCE1pY2hpZ2FuMREwDwYD
# VQQHEwhEZWFyYm9ybjEeMBwGA1UEChMVTmF1c2xleSBTZXJ2aWNlcywgTExDMR4w
# HAYDVQQDExVOYXVzbGV5IFNlcnZpY2VzLCBMTEMwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQC2dySniJYwQymDfgr/Sz0Ho9OQ2sUBfKfY7MfjG7QJ6I2X
# xj69K7VKnyqBHCj5SLbJ32djOhh6DUIOh5NLh5y3Gam99a/ZD3EtExKmrJr8qucM
# pU7IQqDXld7lAtbpFoXUQWIuFcS45fFNmb5VSIMF+RbTtsbe4eWCjL7KNhFpmM8d
# tLXIIW2dS5zhINEMIwzpGTuSH7lBNtwJBPE0CTng6sO2Gz4hWHMOzlp8zGZE0Y7O
# sSe8yVFsg1x9kHttc/w+7voLoUhEEUYkuoICVWRIZAq9jgAdqpsO/VyHGVovIYuR
# JO/9uvXmsR665eQHg0nPo+kCvEgFMnSOPE58CIuRAgMBAAGjggG7MIIBtzAfBgNV
# HSMEGDAWgBRaxLl7KgqjpepxA8Bg+S32ZXUOWDAdBgNVHQ4EFgQUaagv8T80XC2u
# GEhZe39j3axr0UkwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMD
# MHcGA1UdHwRwMG4wNaAzoDGGL2h0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9zaGEy
# LWFzc3VyZWQtY3MtZzEuY3JsMDWgM6Axhi9odHRwOi8vY3JsNC5kaWdpY2VydC5j
# b20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDBCBgNVHSAEOzA5MDcGCWCGSAGG/WwD
# ATAqMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5kaWdpY2VydC5jb20vQ1BTMIGE
# BggrBgEFBQcBAQR4MHYwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0
# LmNvbTBOBggrBgEFBQcwAoZCaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0U0hBMkFzc3VyZWRJRENvZGVTaWduaW5nQ0EuY3J0MAwGA1UdEwEB/wQC
# MAAwDQYJKoZIhvcNAQELBQADggEBACphMQjZG8ner+I0+pfyTrNXgMlOqFm2ENCl
# 4s/GtzniGZIIhBHUEDs9hCGvxuidpSqRdG3EUS77gvhKyVUpC6wLSzlwMGICiZq5
# kTH8ozj/d13RCjYxAeHmL4hB5VL973OIJ/Cgjbv2fGn5CTSHJYaKWKMEU0uMvGA0
# J1SzkYLb2XaNPbkb6th84sAFv+XR+8G5YKr/YO1lX4g33tumMdyu2EXF3selTAFz
# 8ye6xvTO8ilsUykMgGE8UQnHjAJ8uvJpuTCvrqCjAHarUntCp6AoFqVcAQ3np7WF
# 1ikNR1zq8QTFNUMweEnxaRaYRSMep81M63OBUMXAuOVqcL0r3V8wggUwMIIEGKAD
# AgECAhAECRgbX9W7ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYT
# AlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2Vy
# dC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0x
# MzEwMjIxMjAwMDBaFw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYD
# VQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAv
# BgNVBAMTKERpZ2lDZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0Ew
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZ
# z9D7RZmxOttE9X/lqJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnko
# On7p0WfTxvspJ8fTeyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXU
# LaGj6YgsIJWuHEqHCN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q
# 8grkV7tKtel05iv+bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5S
# lsHyDxL0xY4PwaLoLFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPR
# AgMBAAGjggHNMIIByTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIB
# hjATBgNVHSUEDDAKBggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUH
# MAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDov
# L2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNy
# dDCBgQYDVR0fBHoweDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBG
# MDgGCmCGSAGG/WwAAgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNl
# cnQuY29tL0NQUzAKBghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt
# 9mV1DlgwHwYDVR0jBBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcN
# AQELBQADggEBAD7sDVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L
# /e8q3yBVN7Dh9tGSdQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xG
# Tlz/kLEbBw6RFfu6r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGiv
# m6dcIFzZcbEMj7uo+MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZ
# Hen6dGRrsutmQ9qzsIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdi
# bqFT+hKUGIUukpHqaGxEMrJmoecYpJpkUe8xggIoMIICJAIBATCBhjByMQswCQYD
# VQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cuZGln
# aWNlcnQuY29tMTEwLwYDVQQDEyhEaWdpQ2VydCBTSEEyIEFzc3VyZWQgSUQgQ29k
# ZSBTaWduaW5nIENBAhAImZT23mc1/PRmYG22YmaFMAkGBSsOAwIaBQCgeDAYBgor
# BgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEE
# MBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMCMGCSqGSIb3DQEJBDEWBBQO
# 3bVqeLrcYIp99tRlB0YI3WgEHTANBgkqhkiG9w0BAQEFAASCAQBK5v+0013Twzu1
# S4Tbm+3btw8oTw+6mfUzxYbK+1/qyedLaiaK0OLu45jkNLZgV1l6Bw7sOsmD5S6T
# FBdYx+yMUur8cgzphX1rRBndmGAFUyFjpzG13aeDqz0A4DqCLt1XAzpjEHgDHdX2
# TAE0DZRPjikhQdbzxsIVfRxFv8XDe0LwEIDpPj8/n6hBn+QSeFyP2rpm55wVFFQW
# X2tur4gEAfdkq4HKpPi9vwaZiPz2oDIcuK3CHdC0+jjX7iXBhj5Han/RNa7M7y0+
# r6On9fGNttkstmMKOYibo0CdEin4lXRA5pZEYAK7hv1H50tAQbGCISYVUiAVM72X
# EqBf91oM
# SIG # End signature block
