#!/usr/bin/env bash

set -u
shopt -s dotglob
export DEBIAN_FRONTEND="noninteractive"

NEW_ACCOUNTS_SHELL=/bin/sh

package_updated=0
os=""

_set_default ()
{
    ftp_username=""
    ftp_password=""
    ftp_directory=""

    new_acc_uid=1000
    new_acc_gid=1000
}

_set_cfg_paths ()
{
    if [[ "${os}" = "debian" ]]; then
        proftpd_config_path=/etc/proftpd/proftpd.conf
        proftpd_passwd_path=/etc/proftpd/ftpd.passwd
        proftpd_group_path=/etc/proftpd/ftpd.group
    elif [[ "${os}" = "centos" ]]; then
        proftpd_config_path=/etc/proftpd.conf
        proftpd_passwd_path=/etc/ftpd.passwd
        proftpd_group_path=/etc/ftpd.group
    else
        echo 'Unknown OS' >> /dev/stderr
        exit 1
    fi
}

_show_help ()
{
    echo
    echo "GameAP FTP Manager CLI"
    echo "Use this script with GameAP FTP Module: https://github.com/gameap/ftp-module"
    echo 
    echo "Usage: ./ftp.sh COMMAND [OPTIONS]"
    echo
    echo "Options: "
    echo "    --username[=USERNAME]    FTP Username"
    echo "    --password[=PASSWORD]    FTP Password"
    echo "    --directory[=DIRECTORY]  Path to FTP directory"
    echo
    echo "Commands: "
    echo "  add        Create new FTP account"
    echo "  update     Update FTP account"
    echo "  delete     Delete FTP account"
    echo "  install    Install and configure all deps"
    echo 
    echo "Examples: "
    echo "  ./ftp.sh add --username=\"gameap_ftp\" --password=\"blaB1aBlaPa\$\$worD\" --directory=\"/srv/gameap/servers/server01\""
    echo "  ./ftp.sh update --username=\"gameap_ftp\" --password=\"NewPa\$sw0RD\" --directory=\"/srv/gameap/servers/server02\""
    echo "  ./ftp.sh delete --username=\"gameap_ftp\""
    echo
}

_parse_options ()
{
    for i in "$@"
    do
        case $i in
            -h|--help)
                _show_help
                exit 0
            ;;
            --username=*)
                ftp_username=${i#*=}
                shift
            ;;
            --password=*)
                ftp_password="${i#*=}"
                shift
            ;;
            --directory=*)
                ftp_directory="${i#*=}"
                shift
            ;;
            --user=*)
                user="${i#*=}"
                new_acc_uid=$(id -u $user)
                new_acc_gid=$(id -g $user)
            ;;
        esac
    done
}

_unknown_os ()
{
    echo "Unfortunately, your operating system distribution and version are not supported by this script." >> /dev/stderr
    exit 1
}

_detect_os ()
{
    os=""
    dist=""

    if [[ -e /etc/lsb-release ]]; then
        . /etc/lsb-release

        if [[ "${ID:-}" = "raspbian" ]]; then
            os=${ID}
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        else
            os=${DISTRIB_ID}
            dist=${DISTRIB_CODENAME}

            if [[ -z "$dist" ]]; then
                dist=${DISTRIB_RELEASE}
            fi
        fi
    elif [[ -e /etc/os-release ]]; then
        . /etc/os-release

        os="${ID:-}"

        if [[ -n "${VERSION_CODENAME:-}" ]]; then
            dist=${VERSION_CODENAME:-}
        elif [[ -n "${VERSION_ID:-}" ]]; then
            dist=${VERSION_ID:-}
        fi

    elif [[ -n "$(command -v lsb_release 2>/dev/null)" ]]; then
        dist=$(lsb_release -c | cut -f2)
        os=$(lsb_release -i | cut -f2 | awk '{ print tolower($1) }')

    elif [[ -e /etc/debian_version ]]; then
        os=$(cat /etc/issue | head -1 | awk '{ print tolower($1) }')
        if grep -q '/' /etc/debian_version; then
            dist=$(cut --delimiter='/' -f1 /etc/debian_version)
        else
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        fi

        if [[ "${os}" = "debian" ]]; then
          case $dist in
              6* ) dist="squeeze" ;;
              7* ) dist="wheezy" ;;
              8* ) dist="jessie" ;;
              9* ) dist="stretch" ;;
              10* ) dist="buster" ;;
              11* ) dist="bullseye" ;;
          esac
        fi

    else
        _unknown_os
    fi

    if [[ -z "$dist" ]]; then
        _unknown_os
    fi

    # remove whitespace from OS and dist name
    os="${os// /}"
    dist="${dist// /}"

    # lowercase
    os=${os,,}
    dist=${dist,,}

    # echo "Detected operating system as $os/$dist."
}

_update_packages ()
{
    if [[ $package_updated != 0 ]]; then
        return
    fi

    installer_update_cmd=""
    if [[ "${os}" = "debian" ]] || [[ "${os}" = "ubuntu" ]]; then
        installer_update_cmd="apt-get -y update"
    elif [[ "${os}" == "centos" ]]; then
        installer_update_cmd=""
    fi

    if [[ -n "${installer_update_cmd:-}" ]]; then
        bash -c "${installer_update_cmd}"
    fi
}

_install_packages ()
{
    packages=("$@")

    local installer_cmd=""
    local installer_update_cmd=""

    if [[ "${os}" = "debian" ]] || [[ "${os}" = "ubuntu" ]]; then
        installer_cmd="apt-get -y install"
    elif [[ "${os}" = "centos" ]]; then
        installer_cmd="yum -y install"
    fi

    echo
    echo -n "Installing ${packages[*]}... "

    if ! ${installer_cmd} ${packages[*]} ; then
        echo "Unable to install ${packages[*]}." >> /dev/stderr
        echo "Package installation aborted." >> /dev/stderr
        exit 1
    fi

    echo "done."
    echo
}

_proftpd_check ()
{
    if command -v proftpd > /dev/null; then
        return 0
    else
        return 1
    fi
}

_install_proftpd ()
{
    if [[ "${os}" == "centos" ]]; then
        _install_packages epel-release
    fi

    if ! _proftpd_check; then
        _install_packages proftpd
    fi

    sed -i '/#\s*DefaultRoot/s/^#\s*//g'  "${proftpd_config_path}"

    sed -i '/^\s*AuthOrder/ s/^#*/# /' "${proftpd_config_path}"

    sed -i "s/^\s*#\s*AuthOrder\s*.*$/&\nAuthOrder mod_auth_file\.c/g" "${proftpd_config_path}"
    sed -i "s/^\s*AuthOrder mod_auth_file\.c$/&\n\nAuthUserFile ${proftpd_passwd_path//\//\\/}/g" "${proftpd_config_path}"
    sed -i "s/^\s*AuthUserFile.*$/&\nAuthGroupFile ${proftpd_passwd_path//\//\\/}/g" "${proftpd_config_path}"

    touch "${proftpd_passwd_path}"
    touch "${proftpd_group_path}"

    chmod 600 "${proftpd_passwd_path}"

    if ! command -v ftpasswd > /dev/null; then
        _install_packages perl
        curl https://raw.githubusercontent.com/proftpd/proftpd/master/contrib/ftpasswd --output /usr/bin/ftpasswd
        chmod +x /usr/bin/ftpasswd
    fi

    if [[ "${os}" = "centos" ]]; then
        systemctl enable proftpd
        systemctl start proftpd
    else
        service proftpd start
    fi
}

_curl_check ()
{
    echo
    echo "Checking for curl..."

    if command -v curl > /dev/null; then
        echo "Detected curl..."
    else
        echo "Installing curl..."

        _update_packages

        if ! _install_packages curl; then
          echo "Unable to install curl! Your base system has a problem; please check your default OS's package repositories because curl should work." >> /dev/stderr
          echo "Repository installation aborted." >> /dev/stderr
          exit 1
        fi
    fi
}

_install ()
{
    _detect_os
    _update_packages
    _curl_check
    _install_proftpd
}

_create_account ()
{
    echo -e "${ftp_password}\n${ftp_password}" > /tmp/ftp_password_tmp

    ftpasswd --passwd --stdin --file=${proftpd_passwd_path} --name=${ftp_username} --uid=${new_acc_uid} --gid=${new_acc_gid} --home=${ftp_directory} --shell=${NEW_ACCOUNTS_SHELL} < /tmp/ftp_password_tmp

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to add FTP user" >> /dev/stderr
        exit 1
    fi

    rm /tmp/ftp_password_tmp
}

_update_account ()
{
    _create_account
}

_delete_account ()
{
    ftpasswd --passwd --file=${proftpd_passwd_path} --name="${ftp_username}" --delete-user

    if [[ "$?" -ne "0" ]]; then
        echo "Unable to delete user" >> /dev/stderr
        exit 1
    fi
}

_main ()
{
    _detect_os
    _set_cfg_paths

    if [[ -z "${1:-}" ]]; then
        echo "Empty command" >> /dev/stderr
        echo "Use './ftp.sh --help' to get help" >> /dev/stderr
        exit 1
    fi

    command=$1

    if [[ "${command}" == "install" ]]; then
        _install
        exit
    fi

    if [[ -z "${new_acc_uid}" ]] || [[ -z "${new_acc_gid}" ]]; then
        echo "Invalid UID/GID" >> /dev/stderr
        exit 1
    fi

    if [[ -z "${ftp_username}" ]]; then
        echo "Empty FTP username" >> /dev/stderr
        echo "Use './ftp.sh --help' to get help" >> /dev/stderr
        exit 1
    fi

    if [[ "$command" = "add" ]] || [[ "$command" = "update" ]]; then
        if [[ -z "${ftp_password}" ]]; then
            echo "Empty FTP password" >> /dev/stderr
            echo "Use './ftp.sh --help' to get help" >> /dev/stderr
            exit 1
        fi

        if [[ -z "${ftp_directory}" ]]; then
            echo "Empty FTP directory" >> /dev/stderr
            echo "Use './ftp.sh --help' to get help" >> /dev/stderr
            exit 1
        fi
    fi

    if [[ "$command" = "add" ]]; then
        _create_account
    elif [[ "$command" = "update" ]]; then
        _update_account
    elif [[ "$command" = "delete" ]]; then
        _delete_account
    fi
}

_set_default
_parse_options "$@"
_main ${1:-}