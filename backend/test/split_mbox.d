#!/usr/bin/env rdmd

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.string;

void main() {
    auto mbox_file = "emails/with_attachments/conadjuntos.mbox";
    auto single_mails_dir = "emails/with_attachments/single_mails";

    assert(exists(mbox_file));
    assert(mbox_file.isFile);

    writeln("Splitting: ", mbox_file);

    if (!exists(single_mails_dir)) mkdir(single_mails_dir);

    auto mboxf = File(mbox_file, "r");
    string line;
    auto mailindex = 0;
    File email_file;

    while (!mboxf.eof()) {
        line = chomp(mboxf.readln());
        if (line.length > 6 && line[0..5] == "From ") {
            // New email
            email_file = File(buildPath(single_mails_dir, to!string(++mailindex)), "w");
            writeln(mailindex);
        }

        email_file.write(line ~ "\r\n");
    }

}
