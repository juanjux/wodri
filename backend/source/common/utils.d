module common.utils;

import std.datetime;
import std.path;
import std.string;
import std.algorithm;
import std.range;
import std.ascii;
import std.random;
import std.file;
import vibe.core.log;

T[] removeDups(T)(const T[] input)
{
    bool[T] dict;
    T[] result;

    foreach(T item; input)
    {
        if (item !in dict)
        {
            dict[item] = true;
            result ~= item;
        }
    }
    return result;
}


string randomString(uint length)
{
    return iota(length).map!(_ => lowercase[uniform(0, $)]).array;
}


string randomFileName(string directory, string extension="")
{
    string destPath;
    // ensure .something
    if (extension.length > 0 && !extension.startsWith("."))
        extension = "." ~ extension;

    // yep, not 100% warranteed to be unique but incredibly improbable, still FIXME
    do
    {
        destPath = format("%d_%s%s",
                          stdTimeToUnixTime(Clock.currStdTime),
                          randomString(10),
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

// XXX unittest
pure string removeStartSlash(string path)
{
    return path.startsWith("/") ? path[1..$] : path;
}

// XXX unittest
pure string removeEndSlash(string path)
{
    return path.endsWith("/") ? path[0..$-1] : path;
}

// XXX unittest
pure string removeStartEndSlashes(string path)
{
    return removeStartSlash(removeEndSlash(path));
}


// XXX unittest
pure string ensureStartSlash(string path)
{
    return path.startsWith("/") ? path : "/" ~ path;
}



//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|

version(unittest)import std.stdio;

unittest 
{
    writeln("Testing Utils.removeDups");
    assert(removeDups(["a", "b", "cde", "fg"]) == ["a", "b", "cde", "fg"]);
    assert(removeDups(["a", "a", "b", "cde", "cde", "fg"]) == ["a", "b", "cde", "fg"]);
    assert(removeDups(["a", "b", "cde", "a", "fg", "b"]) == ["a", "b", "cde", "fg"]);
    int[] empty;
    assert(removeDups(empty).length == 0);
    assert(removeDups([3, 5, 16, 23, 5]) == [3, 5, 16, 23]);
    assert(removeDups([3,3,3,3,3,3,3,3,3,3,3]) == [3]);
}

unittest
{
    writeln("Testing Utils.randomString");
    assert(randomString(10).length == 10);
    assert(randomString(1000).length == 1000);
}

unittest
{
    writeln("Testing Utils.randomFileName");
    auto rf = randomFileName(buildPath("home", "test"), ".jpg");
    assert(rf.startsWith(buildPath("home", "test")));
    assert(rf.endsWith(".jpg"));
    rf = randomFileName("", ".jpg");
    assert(rf.countUntil("/") == -1);
    assert(rf.endsWith(".jpg"));
    rf = randomFileName("", "jpg");
    assert(rf.endsWith(".jpg"));
    rf = randomFileName("", "");
    assert(rf.countUntil(".") == -1);
}

unittest
{
    writeln("Testing Utils.generateMessageId");
    auto domain = "somedomain.com";
    auto msgid = generateMessageId(domain);
    assert(msgid.countUntil(domain) != -1);
    assert(msgid.endsWith("@" ~ domain));
    msgid = generateMessageId();
    assert(msgid.countUntil("@") != -1);
    assert(!msgid.startsWith("@"));
    assert(msgid.endsWith(".com"));
}


unittest
{
    writeln("Testing Utils.domainFromAddress");
    assert(domainFromAddress("someaddr@somedomain.com") == "somedomain.com");
    assert(domainFromAddress("someaddr@") == "");
    assert(domainFromAddress("someaddr") == "");
    assert(domainFromAddress("") == "");
    assert(domainFromAddress("someaddr@somedomain@someother.com") == "somedomain");
}

unittest
{
    writeln("Testing Utils.capitalizeHeader");
    assert(capitalizeHeader("mime-version")   == "MIME-Version");
    assert(capitalizeHeader("subject")        == "Subject");
    assert(capitalizeHeader("received-spf")   == "Received-SPF");
    assert(capitalizeHeader("dkim-signature") == "DKIM-Signature");
    assert(capitalizeHeader("message-id")     == "Message-ID");
}
