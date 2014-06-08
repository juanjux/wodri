// Write the emails send by postfix to the fake_received dir

import std.stdio;
import std.file;
import std.array;
import std.random;

int main() 
{
    // FIXME: pillar el directorio del ejecutable y hacer un buildPath
    string out_dir = "/home/juanjux/webmail/backend/test/fake_received";
    auto input  = std.stdio.stdin;
    auto output = File(format("%s/%s", out_dir, uniform(0,1000000)), "w");

    if (!out_dir.exists)
        mkdir(out_dir);

    while(!input.eof)
    {
        output.write(input.readln());
    }

    return 0;
}
