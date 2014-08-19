module common.utils;

import std.datetime;
import std.path;
import std.string;
import std.algorithm;
import std.range;
import std.ascii;
import std.random;
import std.file;

T[] removeDups(T)(const T[] input)
{
    bool[T] dict;

    foreach(T item; input)
    {
        if (item !in dict)
            dict[item] = true;
    }
    return dict.keys;
}


string randomString(uint length)
{
    return iota(length).map!(_ => lowercase[uniform(0, $)]).array;
}


string randomFileName(string directory, string extension="")
{
    string destPath;
    do
    {
        destPath = format("%d_%s%s",
                          stdTimeToUnixTime(Clock.currStdTime),
                          randomString(6),
                          extension);
    } while (destPath.exists);
    return buildPath(directory, destPath);
}


pure bool lowStartsWith(string input, string startsw)
{
    return lowStrip(input).startsWith(startsw);
}


pure string lowStrip(string input)
{
    return toLower(strip(input));
}
