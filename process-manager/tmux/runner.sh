#!/bin/bash

set -u
shopt -s dotglob

[[ "${DEBUG:-}" == 'true' ]] && set -x
export DEBIAN_FRONTEND="noninteractive"

HISTORY_LIMIT=1000

last_executed=""

option_command="help"
option_name=""
option_dir=$(pwd)
option_user=$(whoami)
option_execute_command=""

_parse_options() {
    option_command=${1:-}
    shift

    local positional=()
    while [[ $# -gt 0 ]]; do
        local key="$1"

        case $key in
        -h | --help)
            _show_help
            exit 0
            ;;
        -d | --dir)
            option_dir="$2"
            shift
            shift
            ;;
        -n | --name | --sname)
            option_name="$2"
            shift
            shift
            ;;
        -u | --user)
            option_user="$2"
            shift
            shift
            ;;
        -c | --command)
            option_execute_command="$2"
            shift
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
        esac
    done
}

_show_help() {
    echo
    echo 'Usage: ./runner.sh COMMAND [OPTIONS]'
    echo 'Options:'
    echo
    echo 'Commands:'
    echo '    start             Start new server'
    echo '    stop              Stop running server'
    echo '    restart           Restart server'
    echo '    status            Server status'
    echo '    get_console       Get output server log'
    echo '    send_command      Send command into server'
    echo
    echo 'Options:'
    echo
    echo '    General options'
    echo '          --dir, -d                   Working directory'
    echo '          --name, --sname, -n         Session/Screen name option'
    echo '          --user, -u                  Custom user'
    echo
    echo '    Start options'
    echo '          --command, -c               Shell command'
    echo
    echo '    Send command into server'
    echo '          --command, -c               Server command'
    echo
    echo 'Examples:'
    echo '    Starting server'
    echo '          ./runner.sh start -d /home/hl_server -n my_server -c "hlds_run -game valve +ip 127.0.0.1 +port 27015 +map crossfire"'
    echo '          ./runner.sh start --dir /home/hl_server --name my_server --command "hlds_run -game valve +ip 127.0.0.1 +port 27015 +map crossfire"'
    echo
    echo '    Stopping server'
    echo '          ./runner.sh stop -n my_server -u gameap'
    echo
    echo '    Sending command'
    echo '          ./runner.sh send_command -n my_server -u gameap -c stats'
    echo
    echo '    Getting console output'
    echo '          ./runner.sh get_console -n my_server -u gameap'
}

_run_command() {
    local cmd="$@"
    last_executed=$cmd

    cd "${option_dir}" || return 1

    if _run_as_user; then
        if [[ ${BASH_VERSINFO[0]} -eq 5 ]]; then
          if su "${option_user}" -c '$*' -- -- ${cmd}; then
              return 0
          else
              return 1
          fi
        else
            local tmpf
            tmpf=$(mktemp -t runner.XXXXXXXXXX)
            echo "${cmd}" > "${tmpf}"
            chmod 666 "${tmpf}"

            if su "${option_user}" -c "cat ${tmpf} | sh --"; then
                rm -f "${tmpf}"
                return 0
            else
                rm -f "${tmpf}"
                return 1
            fi
        fi
    else
        if $cmd; then
            return 0
        else
            return 1
        fi
    fi
}

_run_as_user() {
    if [[ -z ${option_user} ]]; then
        return 1
    fi

    if [[ $(id -u) != "0" ]]; then
        return 1
    fi

    if [[ $(id -u -n) != ${option_user} ]]; then
        return 0
    fi

    return 1
}

_server_start() {
    if [[ $option_name == "" ]]; then
        echo -e "Empty name" >> /dev/stderr
        return 1
    fi

    if [[ ${option_execute_command} == "" ]]; then
        echo -e "Empty command" >> /dev/stderr
        return 1
    fi

    if _server_status; then
        echo -e "Server is already running" >> /dev/stderr
        return 1
    else
        if ! _run_command \
            tmux \
                new-session -d -s "${option_name}" "${option_execute_command}"; then
            echo -e "Failed to make new tmux session" >> /dev/stderr
            return 1
        fi

        if ! _run_command \
            tmux \
                set-option -g history-limit ${HISTORY_LIMIT}; then
            echo -e "Failed to set history limit" >> /dev/stderr
        fi

        return 0
    fi
}

_server_stop() {
    if [[ $option_name == "" ]]; then
        echo -e "Name empty"
        return 1
    fi

    if _server_status; then
        if _run_command tmux kill-session -t "${option_name}"; then
            return 0
        fi

        echo "Couldn't stop a running server" >> /dev/stderr
        return 1
    else
        echo "Couldn't find a running server" >> /dev/stderr
        return 1
    fi
}

_server_status() {
    if _run_command tmux has-session -t "${option_name}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

_server_get_console() {
    _run_command tmux capture-pane -p -t "${option_name}" -S-
}

_server_send_command() {
    local cmd=${option_execute_command// / SPACE }
    _run_command tmux send-keys -t "${option_name}" "${cmd}" ENTER
}

_debug_command() {
    echo -e "Command: \n" \
        "cd ${option_dir}; ${last_executed}"
}

_tmux_check() {
    if ! command -v tmux &> /dev/null; then
        return 1
    fi

    return 0
}

main() {
    if ! _tmux_check; then
        echo -e "Tmux not found. Please install" >> /dev/stderr
        return 1
    fi

    case ${option_command} in
    start | run)
        if _server_start; then
            echo -e "Server started";

            exit 0
        else
            echo -e "Server not started";
            _debug_command

            exit 1
        fi
        ;;

    stop | kill)
        if _server_stop; then
            echo -e "Server stopped";
            exit 0
        else
            echo -e "Server not stopped";
            exit 1
        fi
        ;;

    restart)
        _server_stop >> /dev/null

        if _server_start; then
            echo -e "Server restarted"
            exit 0
        else
            echo -e "Server not restarted"
            exit 1
        fi
        ;;

    status)
        if _server_status; then
           echo "Server is UP"
           exit 0
        else
           echo "Server is Down"
           exit 1
        fi
        ;;

    get_console | output)
        _server_get_console
        ;;

    send_command | input)
        _server_send_command
        ;;

    *)
        _show_help
        ;;
    esac
}

_parse_options "$@"
main