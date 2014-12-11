#!/bin/sh

if egrep -v '^(ok |\\set ECHO 0|1\.\.[0-9]+|$)' results/*; then
    cp results/*.out test/expected
fi
