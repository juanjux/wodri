#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingemail_singletest && ./test && rm -f ./test
