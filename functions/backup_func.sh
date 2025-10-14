#!/bin/bash
# This file is imported by backup.sh

function backup_func() {
  while true; do
  if [ ! -v archive_path ]; then
  # Ask the user for the backup location
  # If zenity is available, we'll use it to show a graphical directory chooser
  # TODO: Extract this into a function since similar code is used when restoring
  if command -v zenity >/dev/null 2>&1 && { [ "$(uname -r | sed -n 's/.*\( *Microsoft *\).*/\1/ip')" ] || [ -v "$XDG_DATA_DIRS" ]; } ;
  then
    cecho "A graphical directory chooser dialog will be open."
    cecho "You will be prompted for the backup location. Press Enter to continue."
    wait_for_enter

    # Dynamically set the default directory based on the operating system
    zenity_backup_default_dir="$HOME"
    if [ "$(uname -r | sed -n 's/.*\( *Microsoft *\).*/\1/ip')" ]; then
      zenity_backup_default_dir="/mnt/c/Users"
    fi

    archive_path=$(zenity --file-selection --title="Choose the backup location" --directory --filename="$zenity_backup_default_dir" 2>/dev/null | tail -n 1 | sed 's/\r$//' || true)
  else
    # Fall back to the CLI if zenity isn't available (e.g. on macOS)
    get_text_input "Enter the backup location. Press Ok for the current working directory." archive_path "$(pwd)"
    cecho "Install zenity to use a graphical directory chooser."
  fi

  fi
  directory_ok "$archive_path" && break
  unset archive_path
  done

  # Ask the user what data to backup
  selected_items=$(whiptail --title "Backup data" --checklist "Select the categories of data to backup." 20 60 3 \
    "Applications" "Installed apps" ON \
    "Storage" "Photos, downloads, other files" ON \
    "Contacts" "People, SMS and call logs" ON 3>&1 1>&2 2>&3)

  for item in $selected_items; do
    case $item in
    "\"Applications\"")
        backup_apps="yes"
        ;;
    "\"Storage\"")
        backup_storage="yes"
        ;;
    "\"Contacts\"")
        backup_contacts="yes"
        ;;
    esac
  done

  # Ensure that there's enough space in the directory according to what is backed up
  cecho "Estimating backup size, please wait..."

  local estimated_size
  enough_free_space "$archive_path" estimated_size
  local fs_status=$?
  local bkp_size_mb=$(echo "scale=2; $estimated_size/1024" | bc)

  if [ $fs_status -ne 0 ]; then
    echo -e "\033[31mThere isn't enough space for the backup. Estimated backup size: ${bkp_size_mb} MB\033[0m"
    echo -e "\033[31mFree up space on both the target and backup script locations (to handle temporary files). Double the space is needed if backing up to the drive the backup script is located on.\033[0m"
    cecho "Exiting..."
    exit 1
  else
    cecho "Enough space in the current directory. Estimated backup size: ${bkp_size_mb} MB"
  fi

  # The companion app is needed only for contact backups.
  mkdir -p ./backup-tmp/Contacts # Always created for backwards compatibility
  mkdir -p ./backup-tmp/SMS
  mkdir -p ./backup-tmp/CallLogs
  if [ "$backup_contacts" = "yes" ]; then
    adb shell am start -n mrrfv.backup.companion/.MainActivity
    cecho "The companion app has been opened on your device. Please press the 'Export Data' button - this will export contacts/messages to internal storage, allowing this script to back them up. When this is complete, press Enter to continue."
    wait_for_enter

    # Export contacts and SMS messages
    cecho "Exporting contacts (as vCard), call logs as well as SMS messages (as CSV)."
    # Get the entire oab-temp directory
    mkdir -p ./backup-tmp/open-android-backup-temp
    if ! get_file /storage/emulated/0/open-android-backup-temp . ./backup-tmp/open-android-backup-temp; then
      cecho "Error: Failed to get data from the Companion App! Please make sure that you have pressed the 'Export Data' button in the app."
      cecho "If you have already done that, please report this issue on GitHub."
      cecho "Cannot continue - exiting."
      exit 1
    fi
    # Get contacts
    mv ./backup-tmp/open-android-backup-temp/open-android-backup-contact*.vcf ./backup-tmp/Contacts || cecho "No contacts found on device - ignoring." 1>&2
    # Get SMS messages
    mv ./backup-tmp/open-android-backup-temp/SMS_Messages.csv ./backup-tmp/SMS
    # Get call logs
    mv ./backup-tmp/open-android-backup-temp/Call_Logs.csv ./backup-tmp/CallLogs
    # Cleanup
    cecho "Removing temporary files created by the companion app."
    adb shell rm -rf /storage/emulated/0/open-android-backup-temp
    rm -rf ./backup-tmp/open-android-backup-temp
  fi
  uninstall_companion_app # we're uninstalling it so that it isn't included in the backup, regardless of the settings

  # Export apps (.apk files)
  mkdir -p backup-tmp/Apps
  if [ "$backup_apps" = "yes" ]; then
    cecho "Exporting apps."
    app_count=$(adb shell pm list packages -3 -f | wc -l)
    apps_exported=0

    for app in $(adb shell pm list packages -3 -f)
    #   -f: see their associated file
    #   -3: filter to only show third party packages
    do
      # Increment the amount of apps exported
      apps_exported=$((apps_exported+1))
      #output=backup-tmp/Apps
      (
        apk_path=${app%=*}                                  # apk path on device
        apk_path=${apk_path/package:}                       # strip "package:"
        apk_clean_name=$(echo "$app" | awk -F "=" '{print $NF}' | tr -dc '[:alnum:]_.') # package name
        #apk_base="$apk_clean_name-$RANDOM$RANDOM"  # apk filename in the backup archive. Unused, removal pending?
        # e.g.:
        # app=package:/data/app/~~4wyPu0QoTM3AByZS==/org.fdroid.fdroid-iaTC9-W1lyR1FxO==/base.apk=org.fdroid.fdroid
        # apk_path=/data/app/~~4wyPu0QoTM3AByZS==/org.fdroid.fdroid-iaTC9-W1lyR1FxO==/base.apk
        # apk_clean_name=org.fdroid.fdroid
        # apk_base=org.fdroid.fdroid-123456.apk

        echo "Backing up app: $apk_clean_name ($apps_exported/$app_count)"

        # Get all the APKs associated with the package name, including split APKs
        # TODO: Ensure the changes made to apk_clean_name don't break this under certain conditions
        for apk in $(adb shell pm path "$apk_clean_name" | sed 's/package://g' | tr -d '\r'); do
          # Create a directory for the app to store all the APKs
          mkdir -p ./backup-tmp/Apps/"$apk_clean_name"
          # Save the APK to its directory
          get_file "$(dirname "$apk")" "$(basename "$apk")" ./backup-tmp/Apps/"$apk_clean_name"
        done
      )
    done
  fi

  # Export internal storage
  mkdir -p ./backup-tmp/Storage
  if [ "$backup_storage" = "yes" ]; then
    cecho "Exporting internal storage - this will take a while."
    get_file /storage/emulated/0 . ./backup-tmp/Storage
  fi

  # Run the third-party backup hook, if enabled.
  if [ "$use_hooks" = "yes" ] && [ "$(type -t backup_hook)" == "function" ]; then
    cecho "Running backup hooks in 5 seconds."
    sleep 5
    backup_hook
  elif [ "$use_hooks" = "yes" ] && [ ! "$(type -t backup_hook)" == "function" ]; then
    cecho "WARNING! Hooks are enabled, but the backup hook hasn't been found in hooks.sh."
    cecho "Skipping in 5 seconds."
    sleep 5
  fi

  # All data has been collected and the phone can now be unplugged
  cecho "---"
  cecho "All required data has been copied from your device and it can now be unplugged."
  cecho "---"
  sleep 4

  # Copy backup_archive_info.txt to the archive
  cp "$DIR/extras/backup_archive_info.txt" ./backup-tmp/PLEASE_READ.txt
  echo """
Backed up with settings:
backup_apps: $backup_apps
backup_storage: $backup_storage
backup_contacts: $backup_contacts
""" >> ./backup-tmp/PLEASE_READ.txt
  echo "$APP_VERSION" > ./backup-tmp/version.txt

  # If the "discouraged_disable_archive" is set to "yes", then we'll only create a directory with the backup files.
  if [ "$discouraged_disable_archive" = "yes" ]; then
    cecho "Skipping compression & encryption due to the 'discouraged_disable_archive' option being set to 'yes'."
    cecho "The backup data will be stored in a directory instead."
    # TODO: clean up the code, i.e. remove the repetition
    backup_timestamp=$(date +%m-%d-%Y-%H-%M-%S)
    declare backup_archive="$archive_path/open-android-backup-$backup_timestamp"
    mkdir -p "$archive_path/open-android-backup-$backup_timestamp"
    mv ./backup-tmp "$archive_path/open-android-backup-$backup_timestamp"
  else
    # Compress
    cecho "Compressing & encrypting data - this will take a while."
    # 7-Zip options:
    # -p: encrypt backup
    # -mhe=on: encrypt headers (metadata)
    # -mx=9: ultra compression
    # -bb3: verbose logging
    # The undefined variable (archive_password) is set by the user if they're using unattended mode
    if [ -z "$archive_password" ]; then
      get_password_input "Enter a password to encrypt the backup archive (input will be hidden):" archive_password
    fi
    declare backup_archive="$archive_path/open-android-backup-$(date +%m-%d-%Y-%H-%M-%S).7z"
    retry 5 7z a -p -mhe=on -mx=$compression_level -bb3 "$backup_archive" backup-tmp/* < <(echo "$archive_password")
    # Immediately clear sensitive password data
    unset archive_password
  fi

  # We're not using 7-Zip's -sdel option (delete files after compression) to honor the user's choice to securely delete temporary files after a backup
  remove_backup_tmp

  if [ "$use_hooks" = "yes" ] && [ "$(type -t after_backup_hook)" == function ]; then
    cecho "Running after backup hook in 5 seconds."
    sleep 5
    after_backup_hook
  elif [ "$use_hooks" = "yes" ] && [ ! "$(type -t after_backup_hook)" == function ]; then
    cecho "WARNING! Hooks are enabled, but an after backup hook hasn't been found in hooks.sh."
    cecho "Skipping in 5 seconds."
    sleep 5
  fi

  cecho "Backed up successfully."
  cecho "Note: SMS messages and call logs cannot be restored by Open Android Backup at the moment. They are included in the backup archive for your own purposes."
  cecho "You can find them by opening the backup archive using 7-Zip."
}
