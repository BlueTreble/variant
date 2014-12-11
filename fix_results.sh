#!/bin/sh

cmd='^(ok |\set ECHO 0|1\.\.[0-9]+|$)'

if [ -z $(egrep -qv "$cmd" results/*) ]; then
    echo "No errors found; copying results"
    cp results/*.out test/expected
    git status -s test/expected
else
    echo "Errors found:"
    egrep -v "$cmd" results/*
fi
