#!/bin/sh
cd ../source/retriever
dub build --build=plain --config=incomingemail_allemailstest && ./test && rm -f ./test
