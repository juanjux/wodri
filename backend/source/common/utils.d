/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/

module common.utils;

import arsd.characterencodings;
import core.exception: AssertError;
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
auto MSGID_REGEX = ctRegex!(r"[\w@.=%+\-!#\$&'\*/\?\^`\{\}\|~]*\b", "g");
auto EMAIL_REGEX = ctRegex!(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}\b", "g");
auto EMAIL_REGEX2 = ctRegex!(r"<?[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[>a-zA-Z]{2,4}\b>?", "g");
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


// Quoting utils
enum MAXLINESIZE = 76;
enum HEX = "0123456789ABCDEF";

/**
   Detect = detecting when a char or word should be encoded. All characters
   withing the 0..127 range are safe.
   Header = encode espaces (as underlines), and equal signs
   Body = encode equals, tabs and newlines (but not spaces)
 */
enum QuoteMode
{
    Detect,
    Header,
    Body
}

/**
Decide whether a particular character needs to be quoted.

    The 'quotetabs' flag indicates whether embedded tabs and spaces should be quoted. Note
    that line-ending tabs and spaces are always encoded, as per RFC 1521. The header flag
    indicates if '_' chars must be encoded , as per the almost-Q encoding used to encode MIME
    headers. When 'detecting' '=' chars wont make this return true, since they're valid 7bit
    ASCII (but must be quoted inside a quoted-printable string)
**/
private bool dcharNeedsQuoting(dchar c, QuoteMode mode)
pure nothrow
{
    if (among(c, '\n', '\r', '\t'))
        return mode == QuoteMode.Body;

    if (among(c, ' ', '_'))
        return mode == QuoteMode.Header;

    if (c == '=')
        return mode != QuoteMode.Detect;

    return !((' ' <= c) && (c <= '~'));
}


bool needsQuoting(string s, QuoteMode mode)
pure
{
    foreach(codepoint; std.range.stride(s, 1))
    {
        if (dcharNeedsQuoting(codepoint, mode))
            return true;
    }
    return false;
}


private string quote(dchar input, Flag!"Header" headerVariant = No.Header)
pure
{
    string ret = "";
    string utfstr = to!string(input);
    foreach(i; utfstr)
    {
        if (i == ' ' && headerVariant)
            ret ~= '_';
        else
        {
            auto cval = cast(ubyte)i;
            ret ~=['=', HEX[((cval >> 4) & 0x0F)], HEX[(cval & 0x0F)]];
        }
    }
    return ret;
}


string quoteHeader(string word)
pure
{
    // FIXME: this calls needsQuoting twice for every dchar (one time
    // here and one inside the foreach)
    if (!needsQuoting(word, QuoteMode.Detect))
        return word;

    Appender!string res;
    res.put("=?UTF-8?Q?");
    foreach(c; std.range.stride(word, 1))
    {
        if (dcharNeedsQuoting(c, QuoteMode.Header))
            res.put(quote(c, Yes.Header));
        else
            res.put(c);
    }
    res.put("?=");
    return res.data;
}


string quoteHeaderAddressList(string addresses)
{
    Appender!string resApp;
    try
    {
        auto c = match(addresses, EMAIL_REGEX2);
        bool addSpace = false;
        if (c.pre.length)
        {
            resApp.put(quoteHeader(strip(c.pre)) ~ " ");
        }
        if (c.hit.length)
        {
            resApp.put(c.hit);
        }
        if (strip(c.post).length)
        {
            resApp.put(quoteHeaderAddressList(c.post));
        }
        return resApp.data;
    } catch (AssertError) {
        logWarn("Warning, could not regexp-parse address list: ", addresses);
        return addresses;
    }
}


string encodeQuotedPrintable(string input, QuoteMode mode, string lineEnd = "\n")
pure
{
    Appender!string retApp;
    string prevLine;
    auto headerVariant = (mode == QuoteMode.Header ? Yes.Header : No.Header);

    void saveLine(string line, string lineEndInner = lineEnd)
    {
        // RFC 1521 requires that the line ending in a space or tab must have that trailing
        // character encoded.
        if (line.length > 1 && among(line[$-1], ' ', '\t'))
            retApp.put(line[0..$-1] ~ quote(line[$-1], headerVariant) ~ lineEndInner);
        else
            retApp.put(line ~ lineEndInner);
    }

    auto tokens = split(input, lineEnd);
    string finalLineEnd = "";
    if (tokens.length && tokens[$-1] == "")
    {
        // the final lineEnd will be added automatically, remove this one
        tokens = tokens[0..$-1];
        finalLineEnd = lineEnd;
    }

    foreach(line; tokens)
    {
        if (prevLine.length)
            saveLine(prevLine);

        if (!line.length)
        {
            prevLine = "";
            retApp.put(lineEnd);
            continue;
        }

        Appender!string lineBuffer;
        foreach(codepoint; std.range.stride(line, 1))
        {
            if (codepoint == ' ' && mode == QuoteMode.Header)
                lineBuffer.put("_");
            else if (dcharNeedsQuoting(codepoint, mode))
                lineBuffer.put(quote(codepoint, headerVariant));
            else
                lineBuffer.put(codepoint);
        }

        auto thisLine = lineBuffer.data;
        while(thisLine.length > MAXLINESIZE)
        {
            auto limit = MAXLINESIZE-1;
            // dont split by an encoded token
            while (limit > 1 && thisLine[limit-1] == '=' ||
                   limit > 2 && thisLine[limit-2] == '=')
            {
                --limit;
            }

            if (!limit) // all "=" chars????
                break;

            saveLine(thisLine[0..limit], "=" ~ lineEnd);
            thisLine = thisLine[limit..$];
        }
        prevLine = thisLine;
    }

    if (prevLine.length)
    {
        saveLine(prevLine, finalLineEnd);
    }

    return retApp.data;
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
    writeln("Testing Utils.dcharNeedsQuoting(dchar)");

    dchar c = '\n';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert(!dcharNeedsQuoting(c, QuoteMode.Header));
    assert(dcharNeedsQuoting(c, QuoteMode.Body));

    c = '\t';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert(!dcharNeedsQuoting(c, QuoteMode.Header));
    assert( dcharNeedsQuoting(c, QuoteMode.Body));

    c = '\r';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert(!dcharNeedsQuoting(c, QuoteMode.Header));
    assert( dcharNeedsQuoting(c, QuoteMode.Body));

    c = 'a';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert(!dcharNeedsQuoting(c, QuoteMode.Header));
    assert(!dcharNeedsQuoting(c, QuoteMode.Body));

    c = 'ñ';
    assert(dcharNeedsQuoting(c, QuoteMode.Detect));
    assert(dcharNeedsQuoting(c, QuoteMode.Header));
    assert(dcharNeedsQuoting(c, QuoteMode.Body));

    c = ' ';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert( dcharNeedsQuoting(c, QuoteMode.Header));
    assert(!dcharNeedsQuoting(c, QuoteMode.Body));

    c = '_';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert( dcharNeedsQuoting(c, QuoteMode.Header));
    assert(!dcharNeedsQuoting(c, QuoteMode.Body));

    c = '=';
    assert(!dcharNeedsQuoting(c, QuoteMode.Detect));
    assert( dcharNeedsQuoting(c, QuoteMode.Header));
    assert( dcharNeedsQuoting(c, QuoteMode.Body));
}

unittest
{
    writeln("Testing Utils.needsQuoting(string)");
    string s = "AANLkTi=KRf9FL0EqQ0AVm=pA3DCBgiXYR=vnECs1gUMe@mail.gmail.com";
    assert(quoteHeader(s) == s);

    s = "Juanjo Álvarez <juanjux@gmail.com>";
    auto q = quoteHeader(s);
    assert(q == "=?UTF-8?Q?Juanjo_=C3=81lvarez_<juanjux@gmail.com>?=");
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

unittest
{
    writeln("Testing Utils.quoteHeaderAddressList");
    string addrList = "Juanjo Álvarez <juanjux@gmail.com>, "~
                      "Pepito Perez <pepe@perez.com>, "~
                      "Manolo Ñoño manolo@gmail.com";
    auto res = quoteHeaderAddressList(addrList);
    assert(res == "=?UTF-8?Q?Juanjo_=C3=81lvarez?= <juanjux@gmail.com>, Pepito Perez <pepe@perez.com>=?UTF-8?Q?,_Manolo_=C3=91o=C3=B1o?= manolo@gmail.com");
}

unittest
{
    writeln("Testing Utils.encodeQuotedPrintable");

    string a = "\n";
    auto res1 = encodeQuotedPrintable(a, QuoteMode.Header);
    assert(res1 == "\n");
    assert(a == decodeQuotedPrintable(res1, true));

    a = "\n\n";
    res1 = encodeQuotedPrintable(a, QuoteMode.Header);
    assert(res1 == "\n\n");
    assert(a == decodeQuotedPrintable(res1, true));

    a = "\n\n\nabc\ndeññálolo\n";
    res1 = encodeQuotedPrintable(a, QuoteMode.Header);
    assert(res1 == "\n\n\nabc\nde=C3=B1=C3=B1=C3=A1lolo\n");
    assert(a == decodeQuotedPrintable(res1, true));

    a = "\n\n\nabc\ndeññálolo";
    res1 = encodeQuotedPrintable(a, QuoteMode.Header);
    assert(res1 == "\n\n\nabc\nde=C3=B1=C3=B1=C3=A1lolo");
    assert(a == decodeQuotedPrintable(res1, true));

    string b = "abc\nsometab\tandsomemore\t\n";
    auto res2 = encodeQuotedPrintable(b, QuoteMode.Header);
    // Tabs before newline should be encoded always
    assert(res2 == "abc\nsometab\tandsomemore=09\n");
    assert(b == decodeQuotedPrintable(res2, true));
    assert(encodeQuotedPrintable(b, QuoteMode.Detect) ==
           "abc\nsometab\tandsomemore=09\n");
    auto res2_1 = encodeQuotedPrintable(b, QuoteMode.Body);
    assert(res2_1 == "abc\nsometab=09andsomemore=09\n");

    string c = "abc\nwith spaces end\n";
    assert(encodeQuotedPrintable(c, QuoteMode.Header) == "abc\nwith_spaces_end\n");
    assert(encodeQuotedPrintable(c, QuoteMode.Detect) == "abc\nwith spaces end\n");

    string d = "ñaña\npo ñaña\tla";
    auto res3 = encodeQuotedPrintable(d, QuoteMode.Body);
    assert(res3 == "=C3=B1a=C3=B1a\npo =C3=B1a=C3=B1a=09la");
    assert(d == decodeQuotedPrintable(res3, false));

    string f = "one ñaña two ñoño three ááá four ééé five" ~
                  " ñaña six ñaña seven ñaña eight ñaña\n";
    auto res4 = encodeQuotedPrintable(f, QuoteMode.Detect);
    assert(f == decodeQuotedPrintable(res4, false));
    res4 = encodeQuotedPrintable(f, QuoteMode.Header);
    assert(f == decodeQuotedPrintable(res4, true));
    res4 = encodeQuotedPrintable(f, QuoteMode.Body);
    assert(f == decodeQuotedPrintable(res4, false));

    string quijotipsum = "En un lugar de la Mancha, de cuyo nombre no quiero "~
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
        " cuento; basta que en la narración dél no se salga un punto de la verdad.\n";
    auto res5 = encodeQuotedPrintable(quijotipsum, QuoteMode.Detect);
    assert(quijotipsum == decodeQuotedPrintable(res5, false));
    res5 = encodeQuotedPrintable(quijotipsum, QuoteMode.Header);
    assert(quijotipsum == decodeQuotedPrintable(res5, true));
    res5 = encodeQuotedPrintable(quijotipsum, QuoteMode.Body);
    assert(quijotipsum == decodeQuotedPrintable(res5, false));

    string g = "áááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááááá";
    auto res6 = encodeQuotedPrintable(g, QuoteMode.Body);
    auto shouldBeRes6 =
        "=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=\n"~
        "=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=\n"~
        "=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=\n"~
        "=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=\n"~
        "=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=A1=C3=\n"~
        "=A1=C3=A1=C3=A1=C3=A1";
    assert(res6 == shouldBeRes6);
    assert(g == decodeQuotedPrintable(res6));
    res6 = encodeQuotedPrintable(g, QuoteMode.Detect);
    assert(g == decodeQuotedPrintable(res6));
    res6 = encodeQuotedPrintable(g, QuoteMode.Header);
    assert(g == decodeQuotedPrintable(res6, true));

    // test that it doesn't strips the last \n
    string h = g ~ "\n";
    auto res7 = encodeQuotedPrintable(h, QuoteMode.Header);
    auto shouldBeRes7 = shouldBeRes6 ~ "\n";
    assert(shouldBeRes7 == res7);
    assert(h == decodeQuotedPrintable(res7));
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
