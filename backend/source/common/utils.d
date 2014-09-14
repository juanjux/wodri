module common.utils;

import arsd.characterencodings;
import std.algorithm;
import std.ascii;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.random;
import std.range;
import std.regex;
import std.string;
import std.typecons;
import std.utf;
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


// the following functions are mostly translated from the Python lib ones

enum ESCAPE = '=';
enum MAXLINESIZE = 76;
enum HEX = "0123456789ABCDEF";

/**
Decide whether a particular character needs to be quoted.

    The 'quotetabs' flag indicates whether embedded tabs and spaces should be
    quoted.  Note that line-ending tabs and spaces are always encoded, as per
    RFC 1521. The header flag indicates if spaces should be encoded as "_"
    chars, as per the almost-Q encoding used to encode MIME headers.
**/

private bool needsQuoting(dchar c, Flag!"QuoteTabs" quotetabs, Flag!"Header" header)
{
    if (c == '\n')
        return false;
    
    if (among(c, ' ', '\t'))
        return to!bool(quotetabs);

    if (c == '_')
        // if header, we have to escape _ because _ is used to escape space
        return to!bool(header);

    return c == ESCAPE || !((' ' <= c) && (c <= '~'));
}

private string quote(dchar input)
{
    string ret = "";
    string utfstr = to!string(input);
    foreach(i; utfstr)
    {
        auto cval = cast(ubyte)i;
        ret ~=[ESCAPE, HEX[((cval >> 4) & 0x0F)], HEX[(cval & 0x0F)]];
    }
    return ret;
}


string[] encodeQuotedPrintable(string[] input,
                             Flag!"QuoteTabs" quotetabs,
                             Flag!"Header" header,
                             string lineEnd = "\n")
{
    string[] ret;
    string prevLine;

    void saveLine(string line)
    {
        // RFC 1521 requires that the line ending in a space or tab must have that trailing
        // character encoded.
        if (line.length > 1 && among(line[$-2], ' ', '\t'))
            ret ~= line[0..$-2] ~ quote(line[$-2]) ~ line[$-1..$];
        else if (line == ".")
            ret ~= quote(line[0]);
        else
            ret ~= line;
    }

    foreach(line; input)
    {
        if (!line.length)
            break;

        Appender!string lineBuffer;
        
        foreach(codepoint; std.range.stride(line, 1))
        {
            if (needsQuoting(codepoint, quotetabs, header))
                lineBuffer.put(quote(codepoint));
            else if (header && codepoint == ' ')
                lineBuffer.put("_");
            else
                lineBuffer.put(codepoint);
        }

        if (prevLine.length)
            saveLine(prevLine);

        auto thisLine = lineBuffer.data;
        while(thisLine.length > MAXLINESIZE)
        {
            auto limit = MAXLINESIZE-1;
            // dont split by an encoded token
            while ((0 < limit) &&
                  ((1 < limit) && (thisLine[limit-1] == '=')) ||
                  ((2 < limit) && (thisLine[limit-2] == '=')))
            {
                --limit;
            }

            if (!limit) // all "=" chars????
                break;

            saveLine(thisLine[0..limit] ~ "=" ~ lineEnd);
            thisLine = thisLine[limit..$];
        }
        prevLine = thisLine;
    }

    if (prevLine.length)
        saveLine(prevLine);
    return ret;
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
    writeln("Testing Utils.needsQuoting");

    dchar c = '\n';
    assert(!needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    
    c = 'a';
    assert(!needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    assert(!needsQuoting(c, No.QuoteTabs, No.Header));
    assert(!needsQuoting(c, Yes.QuoteTabs, No.Header));
    assert(!needsQuoting(c, No.QuoteTabs, Yes.Header));

    c = 'ñ';
    assert(needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    assert(needsQuoting(c, No.QuoteTabs, No.Header));
    assert(needsQuoting(c, Yes.QuoteTabs, No.Header));
    assert(needsQuoting(c, No.QuoteTabs, Yes.Header));

    c = ' ';
    assert(needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    assert(!needsQuoting(c, No.QuoteTabs, No.Header));
    assert(needsQuoting(c, Yes.QuoteTabs, No.Header));
    assert(!needsQuoting(c, No.QuoteTabs, Yes.Header));

    c = '\t';
    assert(needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    assert(!needsQuoting(c, No.QuoteTabs, No.Header));
    assert(needsQuoting(c, Yes.QuoteTabs, No.Header));
    assert(!needsQuoting(c, No.QuoteTabs, Yes.Header));

    c = '_';
    assert(needsQuoting(c, Yes.QuoteTabs, Yes.Header));
    assert(!needsQuoting(c, No.QuoteTabs, No.Header));
    assert(!needsQuoting(c, Yes.QuoteTabs, No.Header));
    assert(needsQuoting(c, No.QuoteTabs, Yes.Header));
}

unittest
{
    writeln("Testing Utils.quote");

    dchar c = 'a';
    assert(quote(c) == "=61");
    c = ' ';
    assert(quote(c) == "=20");
    c = 'ñ';
    assert(quote(c) == "=C3=B1");
}

// XXX test de todo acentos seguidos
unittest
{
    // XXX mas tests llamando a decodeQuotedPrintable
    writeln("Testing Utils.encodeQuotedPrintable");

    string[] a = ["abc\n", "deññálolo\n"];
    auto res1 = encodeQuotedPrintable(a, Yes.QuoteTabs, No.Header);
    assert(res1 == ["abc\n", "de=C3=B1=C3=B1=C3=A1lolo\n"]);
    assert(a[1] == decodeQuotedPrintable(res1[1]));

    string[] b = ["abc\n", "sometab\tandsomemore\t\n"];
    auto res2 = encodeQuotedPrintable(b, Yes.QuoteTabs, No.Header);
    assert(res2 == ["abc\n", "sometab=09andsomemore=09\n"]);
    assert(b[1] == decodeQuotedPrintable(res2[1]));

    // even without quotetabs, tabs before newline must be quoted
    assert(encodeQuotedPrintable(b, No.QuoteTabs, No.Header) ==
           ["abc\n", "sometab\tandsomemore=09\n"]);

    string[] c = ["abc\n", "with spaces end\n"];
    assert(encodeQuotedPrintable(c, No.QuoteTabs, Yes.Header) == 
           ["abc\n", "with_spaces_end\n"]);
    assert(encodeQuotedPrintable(c, No.QuoteTabs, No.Header) == 
           ["abc\n", "with spaces end\n"]);

    string[] d = ["ñaña\n", "po ñaña\tla"];
    auto res3 = encodeQuotedPrintable(d, Yes.QuoteTabs, Yes.Header);
    assert(res3 == ["=C3=B1a=C3=B1a\n", "po=20=C3=B1a=C3=B1a=09la"]);
    assert(d[1] == decodeQuotedPrintable(res3[1]));

    string[] f = ["one ñaña two ñoño three ááá four ééé five" ~
                  " ñaña six ñaña seven ñaña eight ñaña\n"];

    // XXX descomentar al acabar las pruebas
    // assert(encodeQuotedPrintable(f, No.QuoteTabs, Yes.Header) ==
    //        ["one_=C3=B1a=C3=B1a_two_=C3=B1o=C3=B1o_three_=C3=A1=C3=A1=C3=A1_four_=C3=A=\n",
    //         "9=C3=A9=C3=A9_five_=C3=B1a=C3=B1a_six_=C3=B1a=C3=B1a_seven_=C3=B1a=C3=B1a_=\n",
    //         "eight_=C3=B1a=C3=B1a\n"]);

    string[] quijotipsum = ["En un lugar de la Mancha, de cuyo nombre no quiero "~
        "acordarme, no ha mucho tiempo que vivía un hidalgo de los de lanza en "~
        "astillero, adarga antigua, rocín flaco y galgo corredor. Una olla de "~
        "algo más vaca que carnero, salpicón las más noches, duelos y quebrantos"~
        " los sábados, lantejas los viernes, algún palomino de añadidura los"~
        " domingos, consumían las tres partes de su hacienda. El resto della"~
        " concluían sayo de velarte, calzas de velludo para las fiestas, con"~
        " sus pantuflos de lo mesmo, y los días de entresemana se honraba con"~
        " su vellorí de lo más fino. Tenía en su casa una ama que pasaba de los"~
        " cuarenta, y una sobrina que no llegaba a los veinte, y un mozo de"~
        " campo y plaza, que así ensillaba el rocín como tomaba la podadera."~
        " Frisaba la edad de nuestro hidalgo con los cincuenta años; era de"~
        " complexión recia, seco de carnes, enjuto de rostro, gran madrugador"~
        " y amigo de la caza. Quieren decir que tenía el sobrenombre de"~
        " Quijada, o Quesada, que en esto hay alguna diferencia en los autores"~
        " que deste caso escriben; aunque, por conjeturas verosímiles, se deja"~
        " entender que se llamaba Quejana. Pero esto importa poco a nuestro"~
        " cuento; basta que en la narración dél no se salga un punto de la verdad.\n"]; 

    auto res4 = encodeQuotedPrintable(quijotipsum, No.QuoteTabs, No.Header);
    auto decoded = cast(string)decodeQuotedPrintable(join(res4));
    assert(quijotipsum[0] == decoded);
}

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
