#!/bin/sh
cd ../source/webbackend
DUB=/usr/local/bin/dub
$DUB build --force -v -build=plain --config=curltest
./test&
rdmd ../../test/apilivetests.d
killall test
rm test
