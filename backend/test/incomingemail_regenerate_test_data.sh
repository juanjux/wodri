#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingmail_generatetestdata --force && ./test && rm -f ./test
