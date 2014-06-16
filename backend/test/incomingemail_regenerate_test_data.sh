#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_createtestdata --force && ./test && rm -f ./test
