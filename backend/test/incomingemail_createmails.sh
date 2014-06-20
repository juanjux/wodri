#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingemail_createtestemails --force && ./test && rm -f ./test
