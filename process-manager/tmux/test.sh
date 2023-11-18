#!/bin/bash

set -e

assert() {
    local actual=$1
    local expected=$2

    if [[ "$actual" == "$expected" ]]; then
        echo
        echo "OK: $actual == $expected"
        echo
        echo --------------------------------
        return 0
    else
        echo "Assertion failed: $actual != $expected"
        echo
        echo --------------------------------
        exit 1
    fi
}

contains() {
    string="$1"
    substring="$2"

    if [[ "$string" == *"$substring"* ]]; then
        echo
        echo "OK: '$substring' is in '$string'"
        echo
        echo --------------------------------
        return 0
    else
        echo
        echo "Assertion failed: '$substring' is not in '$string'"
        echo
        echo --------------------------------
        exit 1
    fi
}

# Test start command
output=$(./runner.sh start -d $PWD -n test_01 -c "echo 'hello, it is test_01'; sleep 10")
contains "$output" "Server started"

# Test status command
output=$(./runner.sh status -n test_01)
contains "$output" "Server is UP"

# Test output
output=$(./runner.sh output -n test_01)
contains "$output" "hello, it is test_01"

# Test stop command
output=$(./runner.sh stop -n test_01)
contains "$output" "Server stopped"



useradd testuser

output=$(./runner.sh start -d $PWD -n test_02 -u testuser -c "echo 'hello, it is test_02'; sleep 10")
contains "$output" "Server started"

# Test status command
output=$(./runner.sh status -n test_02 -u testuser)
contains "$output" "Server is UP"

# Test output
output=$(./runner.sh output -n test_02 -u testuser)
contains "$output" "hello, it is test_02"

# Test stop command
output=$(./runner.sh stop -n test_02 -u testuser)
contains "$output" "Server stopped"

echo
echo --------------------------------
echo "All tests passed"

exit 0