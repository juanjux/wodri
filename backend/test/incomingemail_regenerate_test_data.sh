#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingemail_createtestdata --force && ./test && rm -f ./test
