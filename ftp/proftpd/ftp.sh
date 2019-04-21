#!/usr/bin/env bash

set -u
shopt -s dotglob
export DEBIAN_FRONTEND="noninteractive"

show_help ()
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
    echo 
    echo "Examples: "
    echo "  ./ftp.sh add --username=\"gameap_ftp\" --password=\"blaB1aBlaPa\$\$worD\" --directory=\"/srv/gameap/servers/server01\""
    echo "  ./ftp.sh update --username=\"gameap_ftp\" --password=\"NewPa\$sw0RD\" --directory=\"/srv/gameap/servers/server02\""
    echo "  ./ftp.sh delete --username=\"gameap_ftp\""
    echo
}

parse_options () 
{
    for i in "$@"
    do
        case $i in
            -h|--help)
                show_help
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
        esac
    done
}

create_account ()
{
    echo -e "${ftp_password}\n${ftp_password}" > /tmp/ftp_password_tmp

    ftpasswd --passwd --stdin --file=/etc/proftpd/ftpd.passwd --name=${ftp_username} --uid=1000 --gid=1000 --home=${ftp_directory} --shell=/bin/false < /tmp/ftp_password_tmp

    if [ "$?" -ne "0" ]; then
        echo "Unable to add FTP user" >> /dev/stderr
        exit 1
    fi

    rm /tmp/ftp_password_tmp
}

update_account ()
{
    create_account
}

delete_account ()
{
    ftpasswd --passwd --file=/etc/proftpd/ftpd.passwd --name="${ftp_username}" --delete-user

    if [ "$?" -ne "0" ]; then
        echo "Unable to delete user" >> /dev/stderr
        exit 1
    fi
}

main ()
{
    if [ -z "${1:-}" ]; then
        echo "Empty command" >> /dev/stderr
        echo "Use './ftp.sh --help' to get help" >> /dev/stderr
        exit 1;
    fi

    command=$1

    if [ -z "${ftp_username}" ]; then
        echo "Empty FTP username" >> /dev/stderr
        echo "Use './ftp.sh --help' to get help" >> /dev/stderr
        exit 1
    fi

    if [ "$command" = "add" ] || [ "$command" = "update" ]; then
        if [ -z "${ftp_password}" ]; then
            echo "Empty FTP password" >> /dev/stderr
            echo "Use './ftp.sh --help' to get help" >> /dev/stderr
            exit 1
        fi

        if [ -z "${ftp_directory}" ]; then
            echo "Empty FTP directory" >> /dev/stderr
            echo "Use './ftp.sh --help' to get help" >> /dev/stderr
            exit 1
        fi
    fi

    if [ "$command" = "add" ]; then
        create_account
    elif [ "$command" = "update" ]; then
        update_account
    elif [ "$command" = "delete" ]; then
        delete_account
    fi
}

parse_options "$@"
main ${1:-}