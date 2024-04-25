#!/bin/bash
# ----------------------------------------------------------------------------------
# Script Name: arch_install.sh
# Author: Lubos Rendek
# Purpose: To automate the installation of Arch Linux on non-UEFI systems.
# Description:
# This script provides a fully automated approach to installing Arch Linux on
# non-UEFI systems, handling tasks like setting timezones, locales, hostname,
# creating users, and configuring the GRUB bootloader. It is designed to simplify
# the installation process for users unfamiliar with manual Arch Linux installation.
# ----------------------------------------------------------------------------------
# Usage:
# Run this script as root from a live Arch Linux environment:
# ./arch_install.sh
# Ensure that all parameters and environmental variables are set correctly
# to reflect the target installation environment.
# ----------------------------------------------------------------------------------
# License: GNU General Public License v3.0
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# ----------------------------------------------------------------------------------


# List available drives and create/mount partition
function prepare_disk() {
    echo "Available drives:"
    lsblk -nd --output NAME,SIZE
    read -p "Enter the drive where you want to install Arch Linux (e.g., sda): " drive
    if [ -z "$drive" ]; then
        echo "Invalid drive selected."
        exit 1
    fi

    export drive="/dev/${drive}"

    # Create and format the partition
    echo -e "o\nn\np\n1\n\n\nw" | fdisk $drive
    mkfs.ext4 ${drive}1

    # Mount the partition
    mount ${drive}1 /mnt
}

# Install Arch Linux system
function install_system() {
    pacstrap /mnt base linux linux-firmware grub os-prober
}

# Create fstab
function create_fstab() {
    genfstab -U /mnt >> /mnt/etc/fstab
}

# Get timezone
function get_timezone() {

    TIMEZONE_DIR="/usr/share/zoneinfo"

    # Function to list directories and let user select
    select_option() {
        local PROMPT="$1"
        shift
        PS3="$PROMPT"
        select OPTION; do
            if [ -n "$OPTION" ]; then
                echo "$OPTION"
                break
            else
                echo "Invalid option. Please try again."
            fi
        done
    }

    # Get a list of continents (subdirectories in /usr/share/zoneinfo)
    CONTINENTS=$(find "$TIMEZONE_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)

    # Let user select a continent
    echo "Select a continent:"
    CHOSEN_CONTINENT=$(select_option "Choose a continent: " $CONTINENTS)

    # Get a list of cities in the chosen continent
    CITIES=$(find "$TIMEZONE_DIR/$CHOSEN_CONTINENT" -mindepth 1 -maxdepth 1 -type f -exec basename {} \;)

    # Let user select a city
    echo "Select a city:"
    CHOSEN_CITY=$(select_option "Choose a city: " $CITIES)

    # Export the timezone selection by creating the symlink command to be executed later in chroot
    #echo "ln -sf $current_path/$selection /etc/localtime" > /mnt/tmp/set_timezone.sh
    echo "$CHOSEN_CONTINENT/$CHOSEN_CITY" > /mnt/root/timezone_selection.txt

}

# Get locale
function get_locale() {

    LOCALE_GEN_FILE="/mnt/etc/locale.gen"
    LOCALE_CONF_FILE="/mnt/etc/locale.conf"

    # Backup the original locale.gen file
    cp $LOCALE_GEN_FILE "$LOCALE_GEN_FILE.bak"

    # Default locale
    DEFAULT_LOCALE="en_US.UTF-8 UTF-8"

    # Function to list locales and let user select
    select_locale() {
        local options=("$@")
        local num_locales=${#options[@]}
        local items_per_page=30  # Adjust this to fit the screen better
        local page=1

        echo "Default locale is $DEFAULT_LOCALE. Press Enter to select it, or choose from the list below."

        while : ; do
            local start=$(( (page - 1) * items_per_page ))
            local end=$(( start + items_per_page - 1 ))

            # Display locales page by page, formatted for uniform column width
            echo "Page $page:"
            for (( i=start; i<=end && i<num_locales; i++ )); do
                printf "%2d) %-35s" $((i + 1)) "${options[i]}"
                if (( (i - start + 1) % 3 == 0 )); then
                    echo ""
                fi
            done
            echo ""
            echo "n) Next page"
            echo "p) Previous page"
            echo "Enter number to select a locale or 'n/p' for more, or just press Enter for default:"

            read -p "Choice (default $DEFAULT_LOCALE): " choice

            if [ -z "$choice" ]; then
                echo "Default selected: $DEFAULT_LOCALE"
                CHOSEN_LOCALE="$DEFAULT_LOCALE"
                return
            fi

            case $choice in
                [Nn]*) ((page++))
                    if (( page > (num_locales + items_per_page - 1) / items_per_page )); then page=1; fi
                    ;;
                [Pp]*) ((page--))
                    if (( page < 1 )); then page=$(( (num_locales + items_per_page - 1) / items_per_page )); fi
                    ;;
                *[!0-9]*) echo "Invalid option, try again." ;;
                *) if (( choice >= 1 && choice <= num_locales )); then
                    CHOSEN_LOCALE="${options[choice-1]}"
                    echo "Locale selected: $CHOSEN_LOCALE"
                    break
                else
                    echo "Invalid option, try again."
                fi
                ;;
            esac
        done
    }

    # Extract available locales (only those that start with a lowercase character)
    mapfile -t locales < <(grep "^#[a-z]" $LOCALE_GEN_FILE | sed 's/#\s*//' | sed 's/\s*$//')

    # Let the user select a locale
    echo "Select a locale:"
    select_locale "${locales[@]}"

    # Update the locale.gen file to activate the selected locale and deactivate others
    sed -i "/$CHOSEN_LOCALE/s/^#//" $LOCALE_GEN_FILE

    # Set LANG environment variable in locale.conf
    echo "LANG=$CHOSEN_LOCALE" | cut -d " " -f1 > $LOCALE_CONF_FILE


}


function update_hostname {

    HOSTNAME_FILE="/mnt/etc/hostname"
    HOSTS_FILE="/mnt/etc/hosts"

    local new_hostname=""

    while true; do
        echo "Please enter a new hostname:"
        read new_hostname

        # Check if the hostname is valid
        if [[ "$new_hostname" =~ ^[a-zA-Z0-9]+([-]*[a-zA-Z0-9]+)*$ ]] && [[ ! "$new_hostname" =~ (^-|-$) ]] && [[ ! "$new_hostname" =~ " " ]]; then
            echo "$new_hostname" > $HOSTNAME_FILE
            echo -e "127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t${new_hostname}.localdomain ${new_hostname}" > $HOSTS_FILE
            echo "Hostname updated to $new_hostname in $HOSTNAME_FILE and $HOSTS_FILE"
            break  # Exit the loop if the hostname is valid
        else
            echo "Invalid hostname. Hostnames must consist of alphanumeric characters and hyphens (cannot start or end with a hyphen, and no spaces allowed)."
        fi
    done

}




function set_users {

    ROOT_PASSWORD=""
    USER_NAME=""
    USER_PASSWORD=""

    # Prompt for root password
    echo "Please enter the root password:"
    read -s -p "Root Password: " ROOT_PASSWORD
    echo

        # Prompt for username
    echo "Please enter a username for the new user account:"
    read -p "Username: " USER_NAME

    # Check if the username is valid
    while [[ ! "$USER_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; do
        echo "Invalid username. Username must consist of alphanumeric characters and underscores only."
        read -p "Username: " USER_NAME
    done

    # Prompt for user password
    echo "Please enter the password for the new user account:"
    read -s -p "User Password: " USER_PASSWORD
    echo

        # Export variables if needed elsewhere in scripts or subshells
    export ROOT_PASSWORD USER_NAME USER_PASSWORD

    echo "User information set successfully."
}

function finish_installation() {
    umount -R /mnt
    reboot
}


function chroot_system() {
    # Export the drive variable before entering the chroot
    export drive

    # Execute commands inside the chroot environment
    arch-chroot /mnt /bin/bash <<EOF
    # Make environment variables available inside chroot
    export ROOT_PASSWORD="$ROOT_PASSWORD"
    export USER_NAME="$USER_NAME"
    export USER_PASSWORD="$USER_PASSWORD"

    # Read the selected timezone from a file stored at /root/timezone_selection.txt
    TIMEZONE=\$(cat /root/timezone_selection.txt)

    # Link the timezone to /etc/localtime and set hardware clock to UTC
    ln -sf "/usr/share/zoneinfo/\$TIMEZONE" /etc/localtime
    hwclock --systohc
    echo "Timezone set to \$TIMEZONE."

    # Remove the timezone selection file for security and cleanliness
    rm /root/timezone_selection.txt

    # Regenerate locale settings based on the updated locale configuration
    locale-gen

    # Set the root password by piping it into chpasswd, which updates the password
    echo "root:\$ROOT_PASSWORD" | chpasswd
    echo "Root password set."

    # Create a new user with a home directory, set default shell to bash,
    # and add to 'wheel' and 'users' groups for administrative privileges and group membership
    useradd -m -G wheel,users -s /bin/bash "\$USER_NAME"
    echo "\$USER_NAME:\$USER_PASSWORD" | chpasswd
    echo "User \$USER_NAME created and password set."

    # Install the GRUB bootloader to the specified drive
    grub-install --target=i386-pc \$drive

    # Generate the GRUB configuration file
    grub-mkconfig -o /boot/grub/grub.cfg

EOF
}

prepare_disk
install_system
create_fstab
update_hostname
get_timezone
get_locale
set_users
chroot_system
finish_installation
