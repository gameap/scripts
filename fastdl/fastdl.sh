#!/usr/bin/env bash

# FastDL Manage script for GameAP
# Author: Nikita Kuznetsov <https://github.com/et-nik>

shopt -s dotglob
[ "${DEBUG:-}" == 'true' ] && set -x

SCRIPT_PATH=$(dirname $0)

FASTDL_NGINX_SITE="/etc/nginx/conf.d/fastdl.conf"
FASTDL_NGINX_PATH="/etc/nginx/fastdl.d"

FASTDL_DB="${SCRIPT_PATH}/fastdl/fastdl.db"

NGINX_MAIN_CONFIG="/etc/nginx/nginx.conf"
NGINX_PID_FILE="/run/nginx.pid"

package_updated=0

_set_default ()
{
    server_path=''
    web_path='/srv/gameap/fastdl/public'
    method='link'
    autoindex=0

    nginx_host="0.0.0.0"
    nginx_port="80"
    nginx_autoindex=0
}

_parse_options ()
{
  command=$1
  shift

  for i in "$@"
    do
        case $i in
            -h|--help)
                _show_logo
                _show_help
                exit 0
            ;;
            --server-path=*|-p=*)
                server_path="${i#*=}"
                shift
            ;;
            --method=*|-m=*)
                method="${i#*=}"
                shift
            ;;
            --web-path=*|-w=*)
                web_path="${i#*=}"
            ;;
            --host=*)
                nginx_host="${i#*=}"
                shift
            ;;
            --port=*)
                nginx_port="${i#*=}"
                shift
            ;;
            --autoindex=*|-a=*)
                nginx_autoindex="${i#*=}"
            ;;
        esac
    done
}

_show_help ()
{
    echo
    echo 'Usage:	./fastdl.sh COMMAND [OPTIONS]'
    echo
    echo 'Options:'
    echo '      --server-path=            Game Server Path'
    echo '      --method=                 Server resource create method [Default: link]. Available values: link, rsync, copy'
    echo "      --web-dir=                Web Directory. Default '/srv/gameap/fastdl/public'"
    echo '      --host=                   FastDL web host'
    echo '      --port=                   FastDL port'
    echo '      --autoindex               Enable Nginx autoindex'
    echo
    echo 'Commands:'
    echo '    add        Create new fastdl for server'
    echo '    delete     Delete fastdl for game server'
    echo '    install    Install all dependencies'
    echo
    echo 'Examples:'
    echo '      ./fastdl.sh'
}

_show_logo ()
{
    echo
    echo '
                  ###           ####
               #######################
               #######################
              #######````````````#######
            ######   ############   ######
          #####  ####             ##  ########
      ########  ###               ####  ########
     ######## ###                 ###### ########
      ###### ####     ################### ######
       ####  ####     ################### #####
       #### #####     ###           #####  ####
       #### #####     ###           #####  ####
       ####  ####     #########     ##### #####
      ###### ####     #########     ##### ######
     ######## ###       ######      #### ########
      ########  ##                 ###  ########
       ########   ###            ###   #####
            #####    ############   ######
              #######````````````#######
                #######################
                #######################
                 #####          ####'
    echo
    echo '             GameAP FastDL'
    echo
    echo '----------------------------------------------------'
    echo
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

    if [ -e /etc/lsb-release ]; then
        . /etc/lsb-release

        if [ "${ID:-}" = "raspbian" ]; then
            os=${ID}
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        else
            os=${DISTRIB_ID}
            dist=${DISTRIB_CODENAME}

            if [ -z "$dist" ]; then
                dist=${DISTRIB_RELEASE}
            fi
        fi
    elif [ -e /etc/os-release ]; then
        . /etc/os-release

        os="${ID:-}"

        if [ -n "${VERSION_CODENAME:-}" ]; then
            dist=${VERSION_CODENAME:-}
        elif [ -n "${VERSION_ID:-}" ]; then
            dist=${VERSION_ID:-}
        fi

    elif [ -n "$(command -v lsb_release 2>/dev/null)" ]; then
        dist=$(lsb_release -c | cut -f2)
        os=$(lsb_release -i | cut -f2 | awk '{ print tolower($1) }')

    elif [ -e /etc/debian_version ]; then
        os=$(cat /etc/issue | head -1 | awk '{ print tolower($1) }')
        if grep -q '/' /etc/debian_version; then
            dist=$(cut --delimiter='/' -f1 /etc/debian_version)
        else
            dist=$(cut --delimiter='.' -f1 /etc/debian_version)
        fi

        if [ "${os}" = "debian" ]; then
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

    if [ -z "$dist" ]; then
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
    if [ $package_updated != 0 ]; then
        return
    fi

    installer_update_cmd=""
    if [ "${os}" = "debian" ] || [ "${os}" = "ubuntu" ]; then
        installer_update_cmd="apt-get -y update"
    elif [ "${os}" == "centos" ]; then
        installer_update_cmd=""
    fi

    if [ -n "${installer_update_cmd:-}" ]; then
        bash -c "${installer_update_cmd}"
    fi

    echo "installer_update_cmd: ${installer_update_cmd}"
}

_install_packages ()
{
    packages=("$@")

    local installer_cmd=""
    local installer_update_cmd=""

    if [ "${os}" = "debian" ] || [ "${os}" = "ubuntu" ]; then
        installer_cmd="apt-get -y install"
    elif [ "${os}" = "centos" ]; then
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

_nginx_check ()
{
    if command -v nginx > /dev/null; then
        return 0
    else
        return 1
    fi
}

_nginx_process_status ()
{
    if [ ! -f "${NGINX_PID_FILE}" ]; then
        return 1
    fi

    if ! kill -0 "$(cat ${NGINX_PID_FILE})" > /dev/null 2>&1; then
        return 1
    fi

    return 0
}

_nginx_start_or_reload ()
{
    if ! _nginx_process_status; then
        nginx
    else
        nginx -s reload
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

        if _install_packages curl; then
          echo "Unable to install curl! Your base system has a problem; please check your default OS's package repositories because curl should work." >> /dev/stderr
          echo "Repository installation aborted." >> /dev/stderr
          exit 1
        fi
    fi
}


_install_nginx ()
{
    if [ "${os}" == "centos" ]; then
        _install_packages epel-release
    fi

    if ! _nginx_check; then
        _install_packages nginx
    fi

    if [ ! -d "${FASTDL_NGINX_PATH}" ]; then
        mkdir "${FASTDL_NGINX_PATH}"
    fi

    if [ ! -f $FASTDL_NGINX_SITE ]; then
      curl -o $FASTDL_NGINX_SITE https://raw.githubusercontent.com/gameap/scripts/master/fastdl/nginx-site.conf
      sed -i "s/^\(\s*root\s*\).*$/\1${web_path//\//\\/}\;/" $FASTDL_NGINX_SITE
    fi
}

_install ()
{
  _update_packages
  _install_nginx
  _nginx_start_or_reload
}

_uuid_by_path ()
{
    sha512path=$(sha512sum <<< "${server_path}")
    echo "${sha512path:0:8}-${sha512path:8:4}-${sha512path:12:4}-${sha512path:8:12}"
}

_uuid ()
{
    cat /proc/sys/kernel/random/uuid
}

_exists()
{
    if [ -f "${FASTDL_DB}" ]; then
        local
        if [ -n "$(grep $(_uuid_by_path) -m 1 ${FASTDL_DB} | head -1 )" ]; then
            # Exist
            return 0
        else
            return 1
        fi
    fi

    # Not exist
    return 1
}

_contents_fastdl ()
{
    local uuid=$(_uuid_by_path)

    case ${method} in
        link)
            if [ ! -f "${web_path}/${uuid}" ]; then
                ln -s "${server-path}" "${web_path}/${uuid}"
            fi
        ;;
        copy)
            if [ ! -f "${web_path}/${uuid}" ]; then
                mkdir -p "${web_path}/${uuid}"
            fi

            cp -r "${server-path}/" "${web_path}/$(_uuid_by_path)/"
        ;;
        rsync)
            if [ ! -f "${web_path}/${uuid}" ]; then
                mkdir -p "${web_path}/${uuid}"
            fi

            rsync -avz --delete "${server-path}/" "${web_path}/$(_uuid_by_path)/"

            echo "rsync method not implemented" > /dev/stderr
            exit 1
        ;;
    esac
}

_rm_contents_fastdl ()
{
    local uuid=$(_uuid_by_path)
    case ${method} in
        link)
            if [ -f "${web_path}/${uuid}" ]; then
                rm "${web_path}/${uuid}"
            fi
        ;;
        copy|rsync)
            if [ -f "${web_path}/${uuid}" ]; then
                rm -rf "${web_path:?}/${uuid:?}"
            fi
        ;;
    esac
}

_add_fastdl ()
{
    if [ -z "${server_path}" ]; then
        echo "Empty game server path. You should specify --server-path." >> /dev/stderr
        exit 1
    fi

    if [ ! -d "${server_path}" ]; then
        echo "Server path not found" >> /dev/stderr
        exit 1
    fi

    if _exists ; then
        echo "FastDL account is already exists"  >> /dev/stderr
        exit 1
    fi

    if [ ! -d $web_path ]; then
        mkdir -p "${web_path}"
    fi

    local uuid="$(_uuid_by_path)"

    if [ ! -d "$(dirname $FASTDL_DB)" ]; then
        mkdir "$(dirname $FASTDL_DB)"
    fi

    echo "${uuid} ${server_path}" >> $FASTDL_DB
    _contents_fastdl

    _nginx_start_or_reload
}

_delete_fastdl ()
{
    if [ -z "$server_path" ]; then
        echo "Empty game server path. You should specify --server-path." >> /dev/stderr
        exit 1
    fi

    if ! _exists ; then
        echo "FastDL account doesn't exists"
        exit 1
    fi

    sed -i "/^$(_uuid_by_path).*$/d" "${FASTDL_DB}"

    _rm_contents_fastdl

    _nginx_start_or_reload
}

_run ()
{
    case $command in
        "install") _install;;
        "add"|"create") _add_fastdl;;
        "delete"|"remove") _delete_fastdl;;
        "help" | "--help" | "-h" | "") _show_help;;
        *) echo "Invalid command";;
    esac
}

main ()
{
    _detect_os
    _run
}

_set_default
_parse_options "$@"
main