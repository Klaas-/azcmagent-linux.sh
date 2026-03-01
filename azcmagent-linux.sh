#!/bin/bash
#
# Copyright (c) Microsoft Corporation.
#
# This script will
#   1.  Configure host machine to download from packages.microsoft.com
#   2.  Install Azcmagent package
#   3.  Configure for proxy operation (if specified on the command line)
#
# Note that this script is for Linux only

proxy=
outfile=
configfile=
altdownloadfile=
format_success=
format_failure=
desired_version=
alt_his_endpoint=
apt=0
zypper=0
rpm_distro=
deb_distro=
localinstall=0
yum="yum"
provider="Microsoft.HybridCompute"
tempdir=$(mktemp -d /tmp/azcmagent.XXXXXXXXXX)
use_curl=0
use_wget=0
install_curl=0
arm64=0
noproxy=0

# Commands that involve pipes will have return value of '0' only if all parts execute successfully
set -o pipefail 

# Function to log failures to gbl.his.arc.<com | us | cn | custom>
function log_failure() {

  if [ -n "${providerNamespace}" ]; then
    provider="${providerNamespace}"
  fi
  operation="onboarding"
  # if desired_version was passed in, it is implying it is an upgrade operation
  if [ -n "${desired_version}" ]; then
    operation="upgrading"
  fi
  
  message=${2:0:500}
  logBody="{\"subscriptionId\":\"${subscriptionId}\",\"resourceGroup\":\"${resourceGroup}\",\"tenantId\":\"${tenantId}\",\"location\":\"${location}\",\"correlationId\":\"${correlationId}\",\"authType\":\"${authType}\",\"operation\":\"${operation}\",\"namespace\":\"${provider}\",\"osType\":\"linux\",\"messageType\":\"$1\",\"message\":\"${message}\"}"

  his_endpoint=https://gbl.his.arc.azure.com
  if [ "${cloud}" = "AzureUSGovernment" ]; then
    his_endpoint=https://gbl.his.arc.azure.us
  elif [ "${cloud}" = "AzureChinaCloud" ]; then
    his_endpoint=https://gbl.his.arc.azure.cn
  elif [ "${cloud}" = "AzureStackCloud" ]; then
    if [ -n "${alt_his_endpoint}" ]; then
        his_endpoint=${alt_his_endpoint}
    else
        echo "error in log_failure due to invalid his endpoint."
        return
    fi
  fi

    if [ ${use_wget} -eq 1 ]; then
        if [ -n "${proxy}" ]; then
            sudo wget -qO- -e use_proxy=yes -e https_proxy=${proxy} --method=PUT --body-data="$logBody" ${his_endpoint}/log &> /dev/null || true
        else
            sudo wget -qO- --method=PUT --body-data="$logBody" ${his_endpoint}/log &> /dev/null || true
        fi
    elif [ ${use_curl} -eq 1 ]; then
        if [ -n "${proxy}" ]; then
            sudo curl -s -X PUT --proxy ${proxy} -d "$logBody" ${his_endpoint}/log &> /dev/null || true
        else
            sudo curl -s -X PUT -d "$logBody" ${his_endpoint}/log &> /dev/null || true
        fi
    fi
}

# Error codes used by azcmagent are in range of [0, 125].
# Installation scripts will use [127, 255].
function exit_failure {
    if [ -n "${outfile}" ]; then
	json_string=$(printf "$format_failure" "failed" "$1" "$2")
	echo "$json_string" > "$outfile"
    fi
    log_failure $1 "$2"
    echo "$2"
    exit 1
}

function exit_success {
    if [ -n "${outfile}" ]; then
	json_string=$(printf "$format_success" "success" "$1")
	echo "$json_string" > "$outfile"
    fi
    echo "$1"
    exit 0
}

function verify_downloadfile {
    if [ -z "${altdownloadfile##*.deb}" ]; then
        if [ $apt -eq 0 ]; then
	    exit_failure 127 "$0: error: altdownload file should not have .deb suffix"
	fi
    elif [ -z "${altdownloadfile##*.rpm}" ]; then
        if [ $apt -eq 1 ]; then
	    exit_failure 128 "$0: error: altdownload file should not have .rpm suffix"
	fi
    else
	if [ $apt -eq 0 ]; then
	    altdownloadfile+=".rpm"
	else
	    altdownloadfile+=".deb"
	fi
    fi
}
	     
# For Ubuntu, system updates could sometimes occupy apt. We loop and wait until it's no longer busy
function verify_apt_not_busy {
    for i in {1..30}
    do
        sudo lsof /var/lib/dpkg/lock-frontend
        if [ $? -ne 0 ]; then
            sudo lsof /var/lib/apt/lists/lock
            if [ $? -ne 0 ]; then
                return
            fi
        fi
        echo "Another apt/dpkg process is updating system. Retrying up to 5 minutes...$(expr $i \* 30) seconds"
        sleep 10
    done
    exit_failure 145 "$0: file /var/lib/dpkg/lock-frontend or /var/lib/apt/lists/lock is still busy after 5 minutes. Please make sure no other apt/dpkg updates is still running, and retry again."
}

function use_dnf_or_yum {
    yum="yum"
    if command -v dnf &> /dev/null; then
        yum="dnf"
        localinstall=0
        echo "Using 'dnf' instead of 'yum'"
    elif command -v tdnf &> /dev/null; then
        yum="tdnf"
        localinstall=0
        echo "Using 'tdnf' instead of 'yum'"
    fi
}

function use_curl_or_wget {
    if command -v curl &> /dev/null; then
        use_curl=1
        use_wget=0
        install_curl=0
        echo "Using 'curl' for downloads"
    elif command -v wget &> /dev/null; then
        use_curl=0
        use_wget=1
        install_curl=0
        echo "Using 'wget' for downloads"
    else
        use_curl=1
        use_wget=0
        install_curl=1
        echo "Installing 'curl' for downloads"
    fi
}

function check_usable_memory {
    size=$(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d ' ' -f2)
    unit=$(grep MemTotal /proc/meminfo | tr -s ' ' | cut -d ' ' -f3)
    if [ $unit == "kB" ]; then
        echo "Total usable memory: ${size} ${unit}"
    fi
}

function download_file {
# $1 is file to download
# $2 is where to output downloaded file

    if [ -f "$2" ]; then
        sudo rm -f "$2"
    fi

    if [ ${use_curl} -eq 1 ]; then
        if [ -n "${proxy}" ]; then
            sudo curl --proxy ${proxy} "$1" -o "$2"
        else
            sudo curl "$1" -o "$2"
        fi
    elif [ ${use_wget} -eq 1 ]; then
        if [ -n "${proxy}" ]; then
            sudo wget -e use_proxy=yes -e http_proxy=${proxy} "$1" -O "$2"
        else
            sudo wget "$1" -O "$2"
        fi
    fi
    echo $?
}

# Function to resolve full azcmagent version number from the --desiredversion arg (which can be major.minor rather than the full version number)
function resolveDesiredVersion {
    if [ -n "${desired_version}" ]; then
        echo "Resolving desired version"
        if [ "$apt" -eq 0 ]; then
            echo "Resolving full version for prefix: $desired_version"

            if [ $zypper -eq 1 ]; then
                echo "Using Zypper package manager..."
                available_versions=$(zypper --gpg-auto-import-keys --no-refresh se -s azcmagent 2>/dev/null | grep azcmagent | grep -v '^|' | awk '{for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+/) print $i}' | sort -V)
                azcmagent_output=$(zypper --gpg-auto-import-keys --no-refresh se -s azcmagent 2>/dev/null)
                test_output=$(zypper --gpg-auto-import-keys search -s azcmagent)
                echo "test_output"
                echo "$test_output"
                echo "test_output"
            
            elif [ "$yum" = "yum" ]; then
                echo "Using YUM package manager..."
                available_versions=$(yum --showduplicates -y list azcmagent 2>/dev/null | grep azcmagent | awk '{print $2}' | sort -V)
                azcmagent_output=$(yum --showduplicates -y list azcmagent 2>/dev/null)

            elif [ "$yum" = "dnf" ]; then
                echo "Using DNF package manager..."
                available_versions=$(dnf --showduplicates -y list azcmagent 2>/dev/null | grep azcmagent | awk '{print $2}' | sort -V)
                azcmagent_output=$(dnf --showduplicates -y list azcmagent 2>/dev/null)

            elif [ "$yum" = "tdnf" ]; then
                echo "Using TDNF package manager..."
                available_versions=$(tdnf -y list azcmagent 2>/dev/null | grep azcmagent | awk '{print $2}' | sort -V)
                azcmagent_output=$(tdnf -y list azcmagent 2>/dev/null)
            fi

            matching_version=""
            for v in $available_versions; do
                if [[ "$v" =~ ^$desired_version([.-]|$) ]]; then
                    matching_version="$v"
                    break
                fi
            done

            if [ -z "$matching_version" ]; then
                echo "No matching version found for prefix $desired_version"
                echo "Available versions:"
                echo "$available_versions"
                echo "azcmagent_output:"
                echo "$azcmagent_output"
                echo "exiting"
                exit 1
            fi

            desired_version="$matching_version"
            echo "Resolved full version: $desired_version"
        fi
    fi
}

# Check whether to use curl or wget
use_curl_or_wget

# Parse the command-line args
while [[ $# -gt 0 ]]
do
key="$1"

case "$key" in
    -p|--proxy)
	proxy="$2"
    if [ -z "${proxy}" ]; then
        noproxy=1
    else
        echo "Proxy: ${proxy}"
    fi
	shift
	shift
	;;
    -o|--output)
	outfile="$2"
	format_failure='{\n\t"status": "%s",\n\t"error": {\n\t\t"code": "AZCM%04d",\n\t\t"message": "%s"\n\t}\n}'
	format_success='{\n\t"status": "%s",\n\t"message": "%s"\n}'
	shift
	shift
	;;
    -a|--altdownload)
	altdownloadfile="$2"
        shift
	shift
	;;
    -t|--tempdir)
	tempdir="$2"
        shift
	shift
	;;
    -d|--desiredversion)
	desired_version="$2"
	shift
	shift
	;;
    -e|--althisendpoint)
	alt_his_endpoint="$2"
	shift
	shift
	;;
    -h|--help)
	echo "Usage: $0 [--proxy <proxy>] [--output <output file>] [--altdownload <alternate download file>] [--althisendpoint <alternate his endpoint for logging failures>] [--tempdir <alternate temp directory>]"
	echo "For example: $0 --proxy \"localhost:8080\" --output out.json --altdownload http://aka.ms/alternateAzcmagent.deb --altdownload https://gbl.his.arc.azure.com --tempdir ${HOME}/tmp"
        echo "To clear the proxy setting, specify --proxy with two double quotes, i.e.: $0 --proxy \"\""
	exit 0
	;;
    *)
	exit_failure 129 "$0: unrecognized argument: '${key}'. Type '$0 --help' for help."
	;;
esac
done

# Check if $tempdir is writable
if ! [ -d "${tempdir}" -a -w "${tempdir}" ]; then
    exit_failure 129 "$0: temp directory '${tempdir}' is not writable"
fi

# Check usable memory available
check_usable_memory

# Make sure we have systemctl in $PATH
if ! [ -x "$(command -v systemctl)" ]; then
    exit_failure 130 "$0: Azure Connected Machine Agent requires systemd, and that the command 'systemctl' be found in your PATH"
fi

# Detect OS and Architecture
__m=$(uname -m 2>/dev/null) || __m=unknown
__s=$(uname -s 2>/dev/null)  || __s=unknown

distro=
distro_version=
echo "Platform type:  ${__m}:${__s}"
case "${__m}:${__s}" in
    x86_64:Linux)
        arm64=0
        ;;
    aarch64:Linux)
        arm64=1
        ;;
    *)
        exit_failure 132 "$0: unsupported platform: ${__m}:${__s}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        ;;
esac

# Detect Linux distribution and version using multiple fallback methods
# This is critical for determining the correct package manager and repository configuration
if [ -f /etc/centos-release ] && [ ! -f /etc/almalinux-release ]; then
    echo "Retrieving distro info from /etc/centos-release..."
    distro=$(awk -F" " '{ print $1 }' /etc/centos-release)
    distro_version=$(awk -F" " '{ print $4 }' /etc/centos-release)
elif [ -f /etc/os-release ]; then
    echo "Retrieving distro info from /etc/os-release..."
    distro=$(grep ^NAME /etc/os-release | awk -F"=" '{ print $2 }' | tr -d '"')
    distro_version=$(grep VERSION_ID /etc/os-release | awk -F"=" '{ print $2 }' | tr -d '"')
elif which lsb_release 2>/dev/null; then
    echo "Retrieving distro info from lsb_release command..."
    distro=$(lsb_release -i | awk -F":" '{ print $2 }')
    distro_version=$(lsb_release -r | awk -F":" '{ print $2 }')
else
    exit_failure 131 "$0: unknown linux distro. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
fi

# Extract major and minor version numbers from the full version string for distribution-specific logic
distro_major_version=$(echo "${distro_version}" | cut -f1 -d".")  # Extract everything before first dot (e.g., "20" from "20.04")
distro_minor_version=$(echo "${distro_version}" | cut -f2 -d".")  # Extract everything between first and second dot (e.g., "04" from "20.04")

# Following block does the following distro-specific setup:
#   1. Checks that the distro, version, and architecture are supported by Arc
#   2. Sets the appropriate package manager flag (apt, zypper, yum, etc)
#   2. Maps to the appropriate packages.microsoft.com repository path
case "${distro}" in
    # Red Hat Enterprise Linux
    *edHat* | *ed\ Hat*)
        if [ "${distro_major_version}" -eq 7 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for RHEL 7 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Redhat 7..."
            rpm_distro=rhel/7
        elif [ "${distro_major_version}" -eq 8 ]; then
            echo "Configuring for Redhat 8..."
            rpm_distro=rhel/8
        elif [ "${distro_major_version}" -eq 9 ]; then
            echo "Configuring for Redhat 9..."
            rpm_distro=rhel/9.0
        elif [ "${distro_major_version}" -eq 10 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for RHEL 10 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
            fi
            echo "Configuring for Redhat 10..."
            rpm_distro=rhel/10
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum 
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # CentOS (uses RHEL repositories)
    *entOS*)
        # Doc says to use RHEL for CentOS: https://docs.microsoft.com/en-us/windows-server/administration/linux-package-repository-for-microsoft-software
        if [ ${arm64} -eq 1 ]; then
            exit_failure 133 "$0: ARM64 for CentOS is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
        fi
        if [ "${distro_major_version}" -eq 7 ]; then
            echo "Configuring for CentOS 7..."
            rpm_distro=rhel/7  # Use RHEL repository for CentOS 7
            # Yum install on CentOS 7 is not idempotent, and will throw an error if "Nothing to do"
            # The workaround is to use "yum localinstall"
            localinstall=1
        elif [ "${distro_major_version}" -eq 8 ]; then
            echo "Configuring for CentOS 8..."
            rpm_distro=rhel/8 # Use RHEL repository for CentOS 8
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # Oracle Linux (uses RHEL repositories)
    *racle*)
        if [ "${distro_major_version}" -eq 7 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Oracle Linux 7 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Oracle 7..."
            rpm_distro=rhel/7  # Use RHEL repository for Oracle Linux 7
        elif [ "${distro_major_version}" -eq 8 ]; then
            echo "Configuring for Oracle 8..."
            rpm_distro=rhel/8 # Use RHEL repository for Oracle Linux 8
        elif [ "${distro_major_version}" -eq 9 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Oracle Linux 9 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Oracle 9..."
            rpm_distro=rhel/9 # Use RHEL repository for Oracle Linux 9
        elif [ "${distro_major_version}" -eq 10 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Oracle Linux 10 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Oracle 10..."
            rpm_distro=rhel/10 # Use RHEL repository for Oracle Linux 10
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # SUSE Linux Enterprise Server
    *SLES*)
        # Use zypper package manager
        zypper=1
        if [ "${distro_major_version}" -eq 12 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for SLES 12 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for SLES 12..."
            rpm_distro=sles/12
        elif [ "${distro_major_version}" -eq 15 ]; then
            echo "Configuring for SLES 15..."
            rpm_distro=sles/15
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} zypper install -y curl
            else
                sudo -E zypper install -y curl
            fi
        fi
        ;;

    # Amazon Linux
    *mazon\ Linux*)
        if [ "${distro_major_version}" -eq 2 ]; then
            echo "Configuring for Amazon Linux 2 ..."
            rpm_distro=amazonlinux/2
        elif [ "${distro_major_version}" -eq 2023 ]; then
            echo "Configuring for Amazon Linux 2023 ..."
            rpm_distro=amazonlinux/2023
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # Debian
    *ebian*)
        # Use apt package manager
	    apt=1
        if [ "${distro_major_version}" -eq 10 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Debian 10 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
            fi
            echo "Configuring for Debian 10..."
            deb_distro=debian/10
        elif [ "${distro_major_version}" -eq 9 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Debian 9 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
            fi
            echo "Configuring for Debian 9..."
            deb_distro=debian/9
        elif [ "${distro_major_version}" -eq 11 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Debian 11 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
            fi
            echo "Configuring for Debian 11..."
            deb_distro=debian/11
        elif [ "${distro_major_version}" -eq 12 ]; then
            echo "Configuring for Debian 12..."
            deb_distro=debian/12
        elif [ "${distro_major_version}" -eq 13 ]; then
            echo "Configuring for Debian 13..."
            deb_distro=debian/13
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Update package lists and install required packages (gnupg for repository signing keys, curl for downloads if needed)
        if [ -n "${proxy}" ]; then
            sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt update
            sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt install -y gnupg
            if [ ${install_curl} -eq 1 ]; then
                sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt install -y curl
            fi
        else
            sudo -E DEBIAN_FRONTEND=noninteractive apt update
            sudo -E DEBIAN_FRONTEND=noninteractive apt install -y gnupg
            if [ ${install_curl} -eq 1 ]; then
                sudo -E DEBIAN_FRONTEND=noninteractive apt install -y curl
            fi
        fi
        ;;        

    # Ubuntu
    *buntu*)
        # Use apt package manager
	    apt=1
        if [ "${distro_major_version}" -eq 16 ] && [ "${distro_minor_version}" -eq 04 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Ubuntu 16 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Ubuntu 16.04..."
	        deb_distro=ubuntu/16.04
        elif [ "${distro_major_version}" -eq 18 ] && [ "${distro_minor_version}" -eq 04 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Ubuntu 18 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Ubuntu 18.04..."
	        deb_distro=ubuntu/18.04
        elif [ "${distro_major_version}" -eq 20 ] && [ "${distro_minor_version}" -eq 04 ]; then
            echo "Configuring for Ubuntu 20.04..."
	        deb_distro=ubuntu/20.04
        elif [ "${distro_major_version}" -eq 22 ] && [ "${distro_minor_version}" -eq 04 ]; then
            echo "Configuring for Ubuntu 22.04..."
	        deb_distro=ubuntu/22.04
        elif [ "${distro_major_version}" -eq 24 ] && [ "${distro_minor_version}" -eq 04 ]; then
            echo "Configuring for Ubuntu 24.04..."
	        deb_distro=ubuntu/24.04
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Check if apt is currently in use by another process
        verify_apt_not_busy
        # Update package lists and install curl if needed for downloads
        if [ -n "${proxy}" ]; then
            sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt update
            if [ ${install_curl} -eq 1 ]; then
                sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt install -y curl
            fi
        else
            sudo -E DEBIAN_FRONTEND=noninteractive apt update
            if [ ${install_curl} -eq 1 ]; then
                sudo -E DEBIAN_FRONTEND=noninteractive apt install -y curl
            fi
        fi
        ;;        

    # CBL-Mariner
    *ariner*)
        if [ "${distro_major_version}" -eq 1 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Mariner 1 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Common Base Linux Mariner 1..."
        elif [ "${distro_major_version}" -eq 2 ]; then
            echo "Configuring for Common Base Linux Mariner 2..."
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # Azure Linux
    *zure\ Linux*)
        if [ "${distro_major_version}" -eq 3 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Azure Linux 3 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Azure Linux 3..."
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # Rocky Linux (uses RHEL repositories)
    *ocky*)
        if [ ${arm64} -eq 1 ]; then
            exit_failure 133 "$0: ARM64 for Rocky Linux is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
        fi
        if [ "${distro_major_version}" -eq 8 ]; then
            echo "Configuring for Rocky Linux 8..."
            rpm_distro=rhel/8  # Use RHEL repository for Rocky Linux 8
        elif [ "${distro_major_version}" -eq 9 ]; then
            echo "Configuring for Rocky Linux 9..."
            rpm_distro=rhel/9 # Use RHEL repository for Rocky Linux 9
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # AlmaLinux (uses RHEL repositories)
    *lma*)
        if [ "${distro_major_version}" -eq 8 ]; then
            echo "Configuring for Alma Linux 8..."
            rpm_distro=rhel/8  # Use RHEL repository for AlmaLinux 8
        elif [ "${distro_major_version}" -eq 9 ]; then
            if [ ${arm64} -eq 1 ]; then
                exit_failure 133 "$0: ARM64 for Alma Linux 9 is currently not supported. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"            
            fi
            echo "Configuring for Alma Linux 9..."
            rpm_distro=rhel/9 # Use RHEL repository for AlmaLinux 9
        else
            exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        fi
        # Determine whether to use yum, dnf, or tdnf
        use_dnf_or_yum
        # Install curl if needed for downloads
        if [ ${install_curl} -eq 1 ]; then
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install curl
            else
                sudo -E ${yum} -y install curl
            fi
        fi
        ;;

    # Catch-all for unsupported distributions
    *)
        exit_failure 133 "$0: unsupported Linux distribution: ${distro}:${distro_major_version}.${distro_minor_version}. For supported OSs, see https://learn.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems"
        ;;
esac

# Check whether we are running in Azure by querying Azure Instance Metadata Service (IMDS)
# Azure Arc is designed for non-Azure machines, so we prevent installation on Azure VMs
# For testing Arc on Azure VMs, see https://aka.ms/azcmagent-testwarning
if [ ${use_curl} -eq 1 ]; then
    imds_response=$(sudo curl "http://169.254.169.254/metadata/instance/compute?api-version=2019-06-01" -f -s -H "Metadata: true" --connect-timeout 1 --noproxy "*")
else
    imds_response=$(sudo wget "http://169.254.169.254/metadata/instance/compute?api-version=2019-06-01" --header="Metadata: true" --connect-timeout=1 --tries=1 --quiet --no-proxy)
fi
if [ $? -eq 0 ]; then
    # If we get here we are in Azure
    arc_test=$(systemctl show-environment | grep -c 'MSFT_ARC_TEST=true')
    if [ $? -eq 0 ]; then
        # MSFT_ARC_TEST environment variable is set, proceed with warning
        echo "WARNING: Running on an Azure Virtual Machine with MSFT_ARC_TEST set.
Azure Connected Machine Agent is designed for use outside Azure.
This virtual machine should only be used for testing purposes.
See https://aka.ms/azcmagent-testwarning for more details.
"
    else        
        exit_failure 141 "$0: cannot install Azure Connected Machine agent on an Azure Virtual Machine.
Azure Connected Machine Agent is designed for use outside Azure.
To connect an Azure VM for TESTING PURPOSES ONLY, see https://aka.ms/azcmagent-testwarning for more details."
    fi
fi

# Download/copy azcmagent package from alternate location if specified
if [ -n "${altdownloadfile}" ]; then
    # Check if altdownloadfile is a URL or local file path
    # If URL doesn't have http/https protocol, assume it's a regular file and copy it
    proto="$(echo "${altdownloadfile}" | grep :// | sed -e's,^\(.*://\).*,\1,g')"
    if [ "${proto}" == "http://" -o "${proto}" == "https://" ]; then
        # Download URL - download to temp directory
        # Ensure correct file extension for package type (i.e. assert .deb for Debian based systems, .rpm for RPM based systems)
        verify_downloadfile
        echo "Downloading from alternate location: ${altdownloadfile}..."

        # Download package from alt download location
        if [ $apt -eq 1 ]; then
            # Debian based distro
            download_ret=$(download_file "${altdownloadfile}" "${tempdir}/azcmagent.deb")
        else
            # RPM based distro
            download_ret=$(download_file "${altdownloadfile}" "${tempdir}/azcmagent.rpm")
        fi
        if [ $download_ret -ne 0 ]; then
            exit_failure 142 "$0: invalid --altdownload link: ${altdownloadfile}"
        fi
    else
        # Local file path - copy to temp directory
        echo "Copying from alternate location: ${altdownloadfile} to ${tempdir}"
        if [ $apt -eq 1 ]; then
            # Copy .deb file for apt-based systems
            cp ${altdownloadfile} "${tempdir}/azcmagent.deb"
        else
            # Copy .rpm file for rpm-based systems
            cp ${altdownloadfile} "${tempdir}/azcmagent.rpm"
        fi
        if [ $? -ne 0 ]; then
            exit_failure 142 "$0: Unable to copy altdownload file ${altdownloadfile} to ${tempdir}"
        fi
    fi
fi

# Installing azcmagent package
install_cmd=
if [ $apt -eq 1 ]; then
    # Using apt package manager
    install_cmd="apt"
    if [ -n "${altdownloadfile}" ]; then
        # Install from local .deb file
	    sudo -E DEBIAN_FRONTEND=noninteractive apt install "${tempdir}/azcmagent.deb"
    else
        # Install from Microsoft repository - clean up previous configuration first
        sudo apt -y remove packages-microsoft-prod || true
        # Download and install Microsoft repository configuration package
        download_ret=$(download_file https://packages.microsoft.com/config/${deb_distro}/packages-microsoft-prod.deb "${tempdir}/packages-microsoft-prod.deb")
        if [ $download_ret -ne 0 ]; then
            if [ $download_ret -eq 23 -a ${use_curl} -eq 1 ]; then
                exit_failure 157 "$0: curl permission error"
            fi
            exit_failure 146 "$0: download of https://packages.microsoft.com/config/${deb_distro}/packages-microsoft-prod.deb errored"
        fi
        # Install repository configuration package
        sudo -E dpkg -i "${tempdir}/packages-microsoft-prod.deb"
        # Update package lists to include Microsoft repository
        if [ -n "${proxy}" ]; then
            sudo -E https_proxy=${proxy} apt-get update
        else
            sudo -E apt-get update
        fi
        # Convert partial version to full version if needed
        resolveDesiredVersion
        # Install azcmagent package
        if [ -n "${desired_version}" ]; then
            # Installing specific version of azcmagent package
            # Verify the desired version is available in the repository
            if ! [ -n "$(apt-cache policy azcmagent | grep ${desired_version})" ]; then
                exit_failure 147 "$0: desired_version not found: $desired_version"
            fi
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt install -y azcmagent=${desired_version}*
            else
                sudo -E DEBIAN_FRONTEND=noninteractive apt install -y azcmagent=${desired_version}*
            fi
        else
            # Installing the latest available version of azcmagent package
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} DEBIAN_FRONTEND=noninteractive apt install -y azcmagent
            else
                sudo -E DEBIAN_FRONTEND=noninteractive apt install -y azcmagent
            fi
        fi
    fi
elif [ $zypper -eq 1 ]; then
    # Using zypper package manager
    install_cmd="zypper"
    if [ -n "${altdownloadfile}" ]; then
        # Install from local .rpm file
	    sudo -E zypper install -y "${tempdir}/azcmagent.rpm"
    else
        # Install from Microsoft repository - clean up previous configuration first
        sudo zypper remove -y packages-microsoft-prod || true
        # Download and install Microsoft repository configuration package
        download_ret=$(download_file https://packages.microsoft.com/config/${rpm_distro}/packages-microsoft-prod.rpm "${tempdir}/packages-microsoft-prod.rpm")
        if [ $download_ret -ne 0 ]; then
            if [ $download_ret -eq 23 -a ${use_curl} -eq 1 ]; then
                exit_failure 157 "$0: curl permission error"
            fi
            exit_failure 146 "$0: download of https://packages.microsoft.com/config/${rpm_distro}/packages-microsoft-prod.rpm errored"
        fi
        # Install repository configuration package
        sudo -E rpm -i "${tempdir}/packages-microsoft-prod.rpm"
        # Convert partial version to full version if needed
        resolveDesiredVersion
        # Install azcmagent package
        if [ -n "${desired_version}" ]; then
            # Installing specific version of azcmagent package
            # Verify the desired version is available in the repository
            if ! [ -n "$(zypper --gpg-auto-import-keys search -s azcmagent | grep ${desired_version})" ]; then
                exit_failure 147 "$0: desired_version not found: $desired_version"
            fi
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} zypper --gpg-auto-import-keys --non-interactive install -y -l azcmagent=${desired_version}
            else
                sudo -E zypper --gpg-auto-import-keys --non-interactive install -y -l azcmagent=${desired_version}
            fi
        else
            # Installing the latest available version of azcmagent package
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} zypper --gpg-auto-import-keys --non-interactive install -y -l azcmagent
            else
                sudo -E zypper -vv --gpg-auto-import-keys --non-interactive install -y -l azcmagent
            fi
        fi
    fi
else
    # Using yum/dnf/tdnf package manager
    install_cmd="${yum}"
    if [ -n "${altdownloadfile}" ]; then
        # Install from local .rpm file
        if [ $localinstall -eq 0 ]; then
            sudo -E ${yum} -y install "${tempdir}/azcmagent.rpm"
        else
            # Use localinstall for CentOS compatibility, regular install otherwise
            sudo -E ${yum} -y localinstall "${tempdir}/azcmagent.rpm"
        fi
    else
        if [ -n "${rpm_distro}" ]; then
            # Install from Microsoft repository - clean up previous configuration first
            sudo ${yum} -y remove packages-microsoft-prod || true

            # Download and install Microsoft repository configuration package
            download_ret=$(download_file https://packages.microsoft.com/config/${rpm_distro}/packages-microsoft-prod.rpm "${tempdir}/packages-microsoft-prod.rpm")
            if [ $download_ret -ne 0 ]; then
                if [ $download_ret -eq 23 -a ${use_curl} -eq 1 ]; then
                    exit_failure 157 "$0: curl permission error"
                fi
                exit_failure 146 "$0: download of https://packages.microsoft.com/config/${rpm_distro}/packages-microsoft-prod.rpm errored"
            fi
            # Install repository configuration package
            sudo -E rpm -i "${tempdir}/packages-microsoft-prod.rpm"
        fi
        # Convert partial version to full version if needed
        resolveDesiredVersion
        # Install specific version or latest available
        if [ -n "${desired_version}" ]; then
            # Installing specific version of azcmagent package
            # Verify the desired version is available in the repository
            if ! [ -n "$(${yum} --showduplicates list available azcmagent | grep ${desired_version})" ]; then
                exit_failure 147 "$0: desired_version not found: $desired_version"
            fi
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install azcmagent-${desired_version}
            else
                sudo -E ${yum} -y install azcmagent-${desired_version}
            fi
        else
            # Installing the latest available version of azcmagent package
            if [ -n "${proxy}" ]; then
                sudo -E https_proxy=${proxy} ${yum} -y install azcmagent
            else
                sudo -E ${yum} -y install azcmagent
            fi
        fi
    fi
fi

# Check if package installation was successful
install_exit_code=$?
if [ $install_exit_code -ne 0 ]; then
    exit_failure 143 "$0: error installing azcmagent (exit code: $install_exit_code). See '$install_cmd' command logs for more information."
fi

# Configure proxy settings for azcmagent if specified
if [ -n "${proxy}" ]; then
    echo "Configuring proxy..."
    # Set proxy URL in azcmagent configuration
    sudo azcmagent config set proxy.url ${proxy}
elif [ "${noproxy}" -eq 1 ]; then
    echo "Clearing proxy..."
    # Clear any existing proxy configuration
    sudo azcmagent config clear proxy.url
fi

# Report successful installation
if [ -n "${desired_version}" ]; then
    exit_success "azcmagent version ${desired_version} is installed."
else
    exit_success "Latest version of azcmagent is installed."
fi
