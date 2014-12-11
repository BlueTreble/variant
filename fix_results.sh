#!/bin/sh

cmd='^(ok |\set ECHO 0|1\.\.[0-9]+|$)'

if [ -z $(egrep -qv "$cmd" results/*) ]; then
    cp results/*.out test/expected
else
    echo "Errors found:"
    egrep -v "$cmd" results/*
fi
