#!/bin/bash

###
#
#            Name:  migrate_ad_account_to_local_account.sh
#     Description:  This is simply a minor update to the script of the same name by Rich
#                   Trouton (github.com/rtrouton). I added an additional component to install
#                   NoMAD once the account has migrated. Recon with no output was added, 
#                   followed by a short pause, to allow the machine to fall into the correct 
#                   smart group in the JSS to apply a configuration profile.
#   Last Modified:  2017-01-04
#
###

# Modified 12/27/2016
Version=1.1
# Original source is from MigrateUserHomeToDomainAcct.sh
# Written by Patrick Gallagher - https://twitter.com/patgmac
#
# Guidance and inspiration from Lisa Davies:
# http://lisacherie.com/?p=239
#
# Modified by Rich Trouton
#
# Version 1.0 - Migrates an Active Directory mobile account to a local account by the following process:

# 1. Detect if the Mac is bound to AD and offer to unbind the Mac from AD if desired
# 2. Display a list of the accounts with a UID greater than 1000
# 3. Once an account is selected, back up the password hash of the account from the AuthenticationAuthority attribute
# 4. Remove the following attributes from the specified account:
# 
# cached_groups
# cached_auth_policy
# CopyTimestamp - This attribute is used by the OS to determine if the account is a mobile account
# SMBPrimaryGroupSID
# OriginalAuthenticationAuthority
# OriginalNodeName
# AuthenticationAuthority
# SMBSID
# SMBScriptPath
# SMBPasswordLastSet
# SMBGroupRID
# PrimaryNTDomain
# AppleMetaRecordName
# MCXSettings
# MCXFlags
#
# 5. Recreate the AuthenticationAuthority attribute and restore the password hash of the account from backup
# 6. Restart the directory services process
# 7. Check to see if the conversion process succeeded by checking the OriginalNodeName attribute for the value "Active Directory"
# 8. If the conversion process succeeded, update the permissions on the account's home folder.
# 9. Prompt if admin rights should be granted for the specified account
#
# Version 1.1
#
# Changes:
# 
# 1. After conversion, the specified account is added to the staff group.  All local accounts on this Mac are members of the staff group,
#    but AD mobile accounts are not members of the staff group.
# 2. The "accounttype" variable is now checking the AuthenticationAuthority attribute instead of the OriginalNodeName attribute. 
#    The reason for Change 2's attributes change is that the AuthenticationAuthority attribute will exist following the conversion 
#    process while the OriginalNodeName attribute may not.
#

clear

listUsers="$(/usr/bin/dscl . list /Users UniqueID | awk '$2 > 1000 {print $1}') FINISHED"
FullScriptName=`basename "$0"`
ShowVersion="$FullScriptName $Version"
check4AD=`/usr/bin/dscl localhost -list . | grep "Active Directory"`
osvers=$(sw_vers -productVersion | awk -F. '{print $2}')

/bin/echo "********* Running $FullScriptName Version $Version *********"

RunAsRoot()
{
		##  Pass in the full path to the executable as $1
		if [[ "${USER}" != "root" ]] ; then
				/bin/echo
				/bin/echo "***  This application must be run as root.  Please authenticate below.  ***"
				/bin/echo
				sudo "${1}" && exit 0
		fi
}

RunAsRoot "${0}"

# Check for AD binding and offer to unbind if found. 
if [[ "${check4AD}" = "Active Directory" ]]; then
	/usr/bin/printf "This machine is bound to Active Directory.\nDo you want to unbind this Mac from AD?\n"
		select yn in "Yes" "No"; do
			case $yn in
				Yes) /usr/sbin/dsconfigad -remove -force -u none -p none; /bin/echo "AD binding has been removed."; break;;
				No) /bin/echo "Active Directory binding is still active."; break;;
			esac
		done
fi

until [ "$user" == "FINISHED" ]; do

	/usr/bin/printf "%b" "\a\n\nSelect a user to convert or select FINISHED:\n" >&2
	select netname in $listUsers; do
	
		if [ "$netname" = "FINISHED" ]; then
			/bin/echo "Finished converting users to local accounts"

			# Installing newest version of NoMAD
			echo "Installing NoMAD..."
			jamf policy -trigger update_nomad >/dev/null # the >/dev/null supresses output of the policy, just to keep things tidy

			# Run recon to detect NoMAD and apply configuration settings
			echo "Running recon..."
			jamf recon >/dev/null # the >/dev/null supresses output of the recon, just to keep things tidy

			# Give the JSS a chance to apply the configuration settings
			echo "Applying NoMAD settings..."
			sleep 10

			# Get current user and OS information.
			CURRENT_USER=$(/usr/bin/stat -f%Su /dev/console)
			USER_ID=$(id -u "$CURRENT_USER")
			OS_MAJOR=$(/usr/bin/sw_vers -productVersion | awk -F . '{print $1}')
			OS_MINOR=$(/usr/bin/sw_vers -productVersion | awk -F . '{print $2}')

			# Launch NoMAD using launchctl.
			echo "Launching NoMAD..."
			if [[ "$OS_MAJOR" -eq 10 && "$OS_MINOR" -le 9 ]]; then
				LOGINWINDOW_PID=$(pgrep -x -u "$USER_ID" loginwindow)
				launchctl bsexec "$LOGINWINDOW_PID" open "/Applications/NoMAD.app"
			elif [[ "$OS_MAJOR" -eq 10 && "$OS_MINOR" -gt 9 ]]; then
				launchctl asuser "$USER_ID" open "/Applications/NoMAD.app"
			else
				echo "[ERROR] macOS $OS_MAJOR.$OS_MINOR is not supported."
				exit 1004
			fi
			exit 0
		fi
	
	  accounttype=`/usr/bin/dscl . -read /Users/"$netname" AuthenticationAuthority | head -2 | awk -F'/' '{print $2}' | tr -d '\n'`
			
		if [[ "$accounttype" = "Active Directory" ]]; then
			mobileusercheck=`/usr/bin/dscl . -read /Users/"$netname" AuthenticationAuthority | head -2 | awk -F'/' '{print $1}' | tr -d '\n' | sed 's/^[^:]*: //' | sed s/\;/""/g`
			if [[ "$mobileusercheck" = "LocalCachedUser" ]]; then
				/usr/bin/printf "$netname has an AD mobile account.\nConverting to a local account with the same username and UID.\n"
			else
				/usr/bin/printf "The $netname account is not a AD mobile account\n"
				break
			fi
		else
			/usr/bin/printf "The $netname account is not a AD mobile account\n"
			break
		fi

			# Preserve the account password by backing up password hash
			
			shadowhash=`/usr/bin/dscl . -read /Users/$netname AuthenticationAuthority | grep " ;ShadowHash;HASHLIST:<"`
			
			# Remove the account attributes that identify it as an Active Directory mobile account
			
			/usr/bin/dscl . -delete /users/$netname cached_groups
			/usr/bin/dscl . -delete /users/$netname cached_auth_policy
			/usr/bin/dscl . -delete /users/$netname CopyTimestamp
			/usr/bin/dscl . -delete /users/$netname AltSecurityIdentities
			/usr/bin/dscl . -delete /users/$netname SMBPrimaryGroupSID
			/usr/bin/dscl . -delete /users/$netname OriginalAuthenticationAuthority
			/usr/bin/dscl . -delete /users/$netname OriginalNodeName
			/usr/bin/dscl . -delete /users/$netname AuthenticationAuthority
			/usr/bin/dscl . -create /users/$netname AuthenticationAuthority \'$shadowhash\'
			/usr/bin/dscl . -delete /users/$netname SMBSID
			/usr/bin/dscl . -delete /users/$netname SMBScriptPath
			/usr/bin/dscl . -delete /users/$netname SMBPasswordLastSet
			/usr/bin/dscl . -delete /users/$netname SMBGroupRID
			/usr/bin/dscl . -delete /users/$netname PrimaryNTDomain
			/usr/bin/dscl . -delete /users/$netname AppleMetaRecordName
			/usr/bin/dscl . -delete /users/$netname PrimaryNTDomain
			/usr/bin/dscl . -delete /users/$netname MCXSettings
			/usr/bin/dscl . -delete /users/$netname MCXFlags

			# Refresh Directory Services
			if [[ ${osvers} -ge 7 ]]; then
				/usr/bin/killall opendirectoryd
			else
				/usr/bin/killall DirectoryService
			fi
			
			sleep 20
			
			accounttype=`/usr/bin/dscl . -read /Users/"$netname" AuthenticationAuthority | head -2 | awk -F'/' '{print $2}' | tr -d '\n'`
			if [[ "$accounttype" = "Active Directory" ]]; then
				/usr/bin/printf "Something went wrong with the conversion process.\nThe $netname account is still an AD mobile account.\n"
				exit 1
			else
				/usr/bin/printf "Conversion process was successful.\nThe $netname account is now a local account.\n"
			fi
			
			homedir=`/usr/bin/dscl . -read /Users/"$netname" NFSHomeDirectory  | awk '{print $2}'`
			if [[ "$homedir" != "" ]]; then
				/bin/echo "Home directory location: $homedir"
				/bin/echo "Updating home folder permissions for the $netname account"
				/usr/sbin/chown -R "$netname" "$homedir"		
			fi
			
			# Add user to the staff group on the Mac
			
			/bin/echo "Adding $netname to the staff group on this Mac."
			/usr/sbin/dseditgroup -o edit -a "$netname" -t user staff
			
			
			/bin/echo "Displaying user and group information for the $netname account"
			/usr/bin/id $netname
			
			# Prompt to see if the local account should be give admin rights.
			
			/bin/echo "Do you want to give the $netname account admin rights?"
			select yn in "Yes" "No"; do
				case $yn in
						Yes) /usr/sbin/dseditgroup -o edit -a "$netname" -t user admin; /bin/echo "Admin rights given to this account"; break;;
						No ) /bin/echo "No admin rights given"; break;;
					esac
			done
			break
	done
done
