#!/usr/bin/env rdmd

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.string;
import std.process;

/* Test reliability of munpack */

void main() {
    
    void run_munpack(string mailpath) 
    {
        // Create a dir for the parts
        auto orig_dir = getcwd();
        auto parts_dir = mailpath ~ "_dir";
        mkdir(parts_dir);
        chdir(parts_dir);

        auto munpack_cmd = "munpack -t ../" ~ baseName(mailpath);
        //writeln(getcwd());
        //writeln(munpack_cmd);
        auto munpack = executeShell(munpack_cmd);
        if (munpack.status != 0) throw new Exception("munpack failed for: " ~ mailpath);
        chdir(orig_dir);
    }

    auto mbox_file = "emails/todo_gmail.mbox";
    auto single_mails_dir = "emails/single_emails";

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
            if (email_file.isOpen) {
                email_file.flush();
                email_file.close();
                //run_munpack(email_file.name);
            }

            email_file = File(buildPath(single_mails_dir, to!string(++mailindex)), "w");
            writeln(mailindex);
        }
        email_file.write(line ~ "\r\n");
    }

}
