#!/bin/sh
cd ../source/webbackend
DUB=/usr/local/bin/dub
$DUB build  -v --build=plain --config=apitest && rm -f test.o && ./test
if [ $? -eq 0 ]; then
    $DUB run&
    sleep 5
    rdmd ../../test/apilivetests.d
    killall dub
    killall webbackend
fi
