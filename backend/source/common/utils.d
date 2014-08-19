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


string generateMessageId(string domain="")
{
    if (domain.length == 0)
        domain = randomString(10) ~ ".com";

    auto curDate = stdTimeToUnixTime(Clock.currStdTime);
    auto preDomain = randomString(15);
    return preDomain ~ "@" ~ domain;
}


string domainFromAddress(string address)
{
    if (countUntil(address, "@") == -1)
        return "";

    return strip(address).split('@')[1];
}


/**
 * Try to normalize headers to the most common capitalizations
 * RFC 2822 specifies that headers are case insensitive, but better
 * to be safe than sorry
 */
pure string capitalizeHeader(string name)
{
    string res = toLower(name);
    switch(name)
    {
        case "domainkey-signature": return "DomainKey-Signature";
        case "x-spam-setspamtag": return "X-Spam-SetSpamTag";
        default:
    }

    const tokens = split(res, "-");
    string newres;
    foreach(idx, ref tok; tokens)
    {
        if (among(tok, "mime", "dkim", "id", "spf"))
            newres ~= toUpper(tok);
        else
            newres ~= capitalize(tok);
        if (idx < tokens.length-1)
            newres ~= "-";
    }

    return newres;
}


//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|


unittest // capitalizeHeader
{
    assert(capitalizeHeader("mime-version")   == "MIME-Version");
    assert(capitalizeHeader("subject")        == "Subject");
    assert(capitalizeHeader("received-spf")   == "Received-SPF");
    assert(capitalizeHeader("dkim-signature") == "DKIM-Signature");
    assert(capitalizeHeader("message-id")     == "Message-ID");
}
