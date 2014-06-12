#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_createtestmails --force && ./test && rm -f ./test
