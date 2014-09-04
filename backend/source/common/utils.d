module common.utils;

import std.algorithm;
import std.ascii;
import std.datetime;
import std.file;
import std.path;
import std.random;
import std.range;
import std.regex;
import std.string;
import vibe.core.log;

/**
 * From removes variants of "Re:"/"RE:"/"re:" in the subject
 */
auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");

string clearSubject(in string subject)
{
    return replaceAll!(x => "")(subject, SUBJECT_CLEAN_REGEX);
}


T[] removeDups(T)(in T[] input)
pure nothrow
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


string randomString(in uint length)
{
    return iota(length).map!(_ => lowercase[uniform(0, $)]).array;
}


string randomFileName(in string directory, in string extension="")
{
    string destPath;
    string ext = extension;

    // ensure .something
    if (ext.length > 0 && !ext.startsWith("."))
        ext = "." ~ ext;

    // yep, not 100% warranteed to be unique but incredibly improbable, still FIXME
    do
    {
        destPath = format("%d_%s%s",
                          stdTimeToUnixTime(Clock.currStdTime),
                          randomString(10),
                          ext);
    } while (destPath.exists);
    return buildPath(directory, destPath);
}


bool lowStartsWith(in string input, in string startsw)
pure
{
    return lowStrip(input).startsWith(startsw);
}


string lowStrip(in string input)
pure
{
    return toLower(strip(input));
}


string generateMessageId(in string domain="")
{
    string dom = domain;
    if (dom.length == 0)
        dom = randomString(10) ~ ".com";

    immutable preDomain = randomString(15);
    return preDomain ~ "@" ~ dom;
}


string domainFromAddress(in string address)
pure
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
string capitalizeHeader(in string name)
pure
{
    switch(name)
    {
        case "domainkey-signature": return "DomainKey-Signature";
        case "x-spam-setspamtag": return "X-Spam-SetSpamTag";
        default:
    }

    const tokens = split(toLower(name), "-");
    string result;
    foreach(idx, ref tok; tokens)
    {
        if (among(tok, "mime", "dkim", "id", "spf"))
            result ~= toUpper(tok);
        else
            result ~= capitalize(tok);
        if (idx < tokens.length-1)
            result ~= "-";
    }
    return result;
}

string removeStartSlash(in string path)
pure nothrow
{
    return path.startsWith("/") ? path[1..$] : path;
}


string removeEndSlash(string path)
pure nothrow
{
    return path.endsWith("/") ? path[0..$-1] : path;
}


string removeStartEndSlashes(in string path)
pure nothrow
{
    return removeStartSlash(removeEndSlash(path));
}


string ensureStartSlash(in string path)
pure nothrow
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

unittest
{
    writeln("Testing Utils.lowStartsWith");
    assert(lowStartsWith("abcDEF", "abcd"));
    assert(lowStartsWith("hijk", ""));
}


unittest
{
    writeln("Testing Utils.lowStrip");
    assert(lowStrip(" \tabcDEF") == "abcdef");
    assert(lowStrip(" ABCdef \t \n") == "abcdef");
}


unittest
{
    writeln("Testing Utils.removeStartSlash/End/StartEnd");
    assert(removeStartSlash("abcDEF") == "abcDEF");
    assert(removeStartSlash("/abcdef") == "abcdef");
    assert(removeStartSlash("/abcdef/") == "abcdef/");
    assert(removeStartSlash("///abcdef") == "//abcdef");

    assert(removeEndSlash("abcDEF") == "abcDEF");
    assert(removeEndSlash("abcDEF/") == "abcDEF");
    assert(removeEndSlash("abcDEF///") == "abcDEF//");
    assert(removeEndSlash("/abcDEF/") == "/abcDEF");

    assert(removeStartEndSlashes("abcDEF") == "abcDEF");
    assert(removeStartEndSlashes("/abcDEF") == "abcDEF");
    assert(removeStartEndSlashes("//abcDEF//") == "/abcDEF/");
    assert(removeStartEndSlashes("abcDEF//") == "abcDEF/");

}

unittest // clearSubject
{
    writeln("Testing Utils.clearSubject");
    assert(clearSubject("RE: polompos") == "polompos");
    assert(clearSubject("Re: cosa RE: otracosa re: mascosas") == "cosa otracosa mascosas");
    assert(clearSubject("Pok and something Re: things") == "Pok and something things");
}
