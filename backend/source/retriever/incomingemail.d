#!/usr/bin/env rdmd
module retriever.incomingemail;

import std.stdio;
import std.path;
import std.regex;
import std.file;
import std.range;
import std.conv;
import std.algorithm;
import std.string;
import std.ascii;
import std.array;
import std.base64;
import std.random;
import std.datetime;
import vibe.utils.dictionarylist;
import retriever.characterencodings;

version(incomingemail_createtestdata) version     = anyincomingmailtest;
version(incomingemail_regeneratetestdata) version = anyincomingmailtest;
version(incomingemail_singletest) version         = anyincomingmailtest;
version(incomingemail_allemailstest) version       = anyincomingmailtest;
version(anyincomingmailtest)
{
    import retriever.db: getConfig;
    import std.process;
}

auto EMAIL_REGEX = ctRegex!(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}\b", "g");
auto MSGID_REGEX = ctRegex!(r"[\w@.=%+\-!#\$&'\*/\?\^`\{\}\|~]*\b", "g");
string[] MONTH_CODES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/**
 * Try to normalize headers to the most common capitalizations
 * RFC 2822 specifies that headers are case insensitive, but better
 * to be safe than sorry 
 */
private pure string capitalizeHeader(string name)
{
    string res = toLower(name);
    switch(name)
    {
        case "domainkey-signature": return "DomainKey-Signature";
        case "x-spam-setspamtag": return "X-Spam-SetSpamTag";
        default:
    }
    auto tokens = split(res, "-");
    string newres;
    foreach(idx, tok; tokens)
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
    unittest
    {
        assert(capitalizeHeader("mime-version")   == "MIME-Version");
        assert(capitalizeHeader("subject")        == "Subject");
        assert(capitalizeHeader("received-spf")   == "Received-SPF");
        assert(capitalizeHeader("dkim-signature") == "DKIM-Signature");
        assert(capitalizeHeader("message-id")     == "Message-ID");
    }


private string randomString(uint length)
{
    return iota(length).map!(_ => lowercase[uniform(0, $)]).array; 
}


private string randomFileName(string directory, string extension="")
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


final class MIMEPart // #mimepart
{
    MIMEPart parent = null;
    MIMEPart[] subparts;
    ContentData ctype;
    ContentData disposition;
    string cTransferEncoding;
    string contentId;
    string textContent;
    Attachment attachment;
}


struct ContentData
{
    string name;
    string[string] fields;
}


struct Attachment // #attach
{
    string realPath;
    string ctype;
    string filename;
    string contentId;
    ulong size;
    version(unittest)
    {
        bool wasEncoded = false;
        string origEncodedContent;
    }
}


struct HeaderValue
{
    string rawValue;
    string[] addresses;
}


final class IncomingEmail
{
    string attachmentStore;
    string rawEmailStore;

    DictionaryList!(HeaderValue, false) headers; // Note: keys are case insensitive
    MIMEPart rootPart;
    MIMEPart[] textualParts; // shortcut to the textual (text or html) parts in display
    Attachment[] attachments;
    DateTime date;
    bool dateSet = false;
    string[] fromAddrs;
    string[] toAddrs;
    string[] ccAddrs;
    string[] bccAddrs;
    string rawEmailPath;
    string lineSep = "\r\n";

    this(string rawEmailStore, string attachmentStore)
    {
        this.attachmentStore = attachmentStore;
        this.rawEmailStore    = rawEmailStore;
        this.rootPart        = new MIMEPart();
    }

    @property bool isValid()
    {
        // From and Message-ID and at least one of to/cc/bcc/delivered-to
        return (getHeader("from").addresses.length &&
                (getHeader("to").addresses.length        ||
                getHeader("cc").addresses.length         ||
                getHeader("bcc").addresses.length        ||
                getHeader("delivered-to").addresses.length));
    }


    /**
        Return the header if it exists. If not, returns an empty HeaderValue.
        Useful when you want a default empty value.
    */
    HeaderValue getHeader(string name)
    {
        if (name in this.headers)
            return this.headers[name];

        HeaderValue hv;
        return hv;
    }


    void loadFromFile(string emailPath, bool copyRaw=true)
    {
        auto f = File(emailPath);
            loadFromFile(f);
    }


    void loadFromFile(File emailFile, bool copyRaw=true)
    {
        string currentLine;
        bool bodyHasParts          = false;
        // Need to know if reading from stdin/stderr for the rawCopy:
        bool inputIsStdInput       = false; 
        Appender!string stdinLines = null;
        auto partialBuffer         = appender!string;

        if (copyRaw && among(emailFile, std.stdio.stdin, std.stdio.stderr))
        {
            inputIsStdInput = true;
            stdinLines = appender!string;
        }

        // === Header ===
        currentLine = emailFile.readln();
        if (currentLine.length)
        {
            this.lineSep = currentLine.endsWith("\r\n")?"\r\n": "\n";
            if (currentLine.startsWith("From "))
                // mbox format indicator, ignore
                currentLine = emailFile.readln();
        }

        while (currentLine.length && !emailFile.eof())
        {
            if (inputIsStdInput)
                stdinLines.put(currentLine);

            if (partialBuffer.data.length && !among(currentLine[0], ' ', '\t'))
            {
                // Not indented, so this line starts a new header (or
                // body): add the buffer (with the text of the previous
                // lines without the current line) as new header
                addHeader(partialBuffer.data);
                partialBuffer.clear();
            }
            partialBuffer.put(currentLine);

            if (currentLine == this.lineSep)
            {
                // Body mark found
                getRootContentInfo(this.rootPart);
                partialBuffer.clear();
                break;
            }
            currentLine = emailFile.readln();
        }

        // === Body=== (read all into the buffer, the parsing is done outside the loop)
        while (currentLine.length && !emailFile.eof())
        {
            currentLine = emailFile.readln();

            if (inputIsStdInput)
                stdinLines.put(currentLine);

            partialBuffer.put(currentLine);
        }

        if (this.rootPart.ctype.name.startsWith("multipart"))
            parseParts(split(partialBuffer.data, this.lineSep), this.rootPart);
        else
            setTextPart(this.rootPart, partialBuffer.data);

        // Finally, copy the email to rawEmailPath
        // (the user of the class is responsible for deleting the original)
        if (copyRaw && this.rawEmailStore.length)
        {
            auto destFilePath = randomFileName(this.rawEmailStore);

            if (inputIsStdInput)
            {
                auto f = File(destFilePath, "w");
                f.write(stdinLines.data);
            }
            else
                copy(emailFile.name, destFilePath);

            this.rawEmailPath = destFilePath;
        }
    }


    string printHeaders(bool asString=false)
    {
        auto textheaders = appender!string;
        foreach(string name, HeaderValue value; this.headers)
        {
            if (asString)
            {
                textheaders.put(name ~ ":");
                textheaders.put(value.rawValue ~ this.lineSep);
            }
            else
                write(name, ":", value);
        }
        return textheaders.data;
    }


    void generateMessageId(string domain="")
    {
        // FIXME: check domain
        this.headers.removeAll("message-id");
        if (!domain.length)
            domain = randomString(30) ~ ".com";

        addHeader("Message-ID: <" ~ to!string(stdTimeToUnixTime(Clock.currStdTime)) ~ 
                                            randomString(50) ~ "@" ~ 
                                            domain ~ "> " ~ this.lineSep);
    }


    void addHeader(string raw)
    {
        auto idxSeparator = countUntil(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length))
            return; // Not header, probably mbox indicator or broken header

        HeaderValue value;
        string name     = raw[0..idxSeparator];
        string valueStr = decodeEncodedWord(raw[idxSeparator+1..$]);

        if (valueStr.endsWith("\r\n"))
            value.rawValue = valueStr[0..$-2];
        else
            value.rawValue = valueStr;

        // add the bare emails to the value.addresses field
        auto lowname = toLower(name);
        string tmpValue;
        switch(lowname)
        {
			case "from":
            case "to":
            case "cc":
            case "bcc":
            case "delivered-to":
            case "x-forwarded-to":
            case "x-forwarded-for":
                 foreach(c; match(value.rawValue, EMAIL_REGEX))
                 {
                    tmpValue = c.hit;
                    if (tmpValue.length)
                        value.addresses ~= tmpValue;
                 }
                break;
            case "message-id":
                value.addresses = [match(value.rawValue, MSGID_REGEX).hit];
                break;
            case "references":
                 foreach(c; match(value.rawValue, MSGID_REGEX))
                 {
                    tmpValue = c.hit;
                    if (tmpValue.length)
                        value.addresses ~= tmpValue;
                 }
                break;
            case "date":
                this.date = parseDate(value.rawValue);
                break;
            default:
        }
        this.headers.addField(name, value);
    }


    DateTime parseDate(string strDate)
    {
        // Default to current time so we've some date if
        // the format is broken
        DateTime ldate = to!DateTime(Clock.currTime);
        auto tokDate = strip(strDate).split(' ').filter!(a => !a.empty).array;

        if (!tokDate.length)
            return ldate;

        try
        {
            uint posAdjust = 0;
            if (tokDate.length >= 5)
            {
                // like: Tue, 18 Mar 2014 16:09:36 +0100
                if (tokDate.length >= 6 &&
                    among(tokDate[0][0..3], "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"))
                    ++posAdjust;
                // else like: 4 Jan 2005 07:04:19 -0000

                auto month     = to!int(countUntil(MONTH_CODES, tokDate[1+posAdjust])+1);
                auto year      = to!int(tokDate[2+posAdjust]);
                auto day       = to!int(tokDate[0+posAdjust]);
                auto hmsTokens = tokDate[3+posAdjust].split(":");
                auto hour      = to!int(hmsTokens[0]);
                auto minute    = to!int(hmsTokens[1]);
                int second = hmsTokens.length > 2? to!int(hmsTokens[2]):0;
                string tz      = tokDate[4+posAdjust];
                ldate = DateTime(Date(year, month, day),
                                     TimeOfDay(hour, minute, second));

                // The date is saved on UTC, so we add/substract the TZ
                if (tz.length == 5 && tz[1..$] != "0000")
                {
                    int multiplier = tz[0] == '+'? -1: 1;
                    ldate += dur!"hours"(to!int(tz[1..3])*multiplier);
                    ldate += dur!"minutes"(to!int(tz[3..5])*multiplier);
                }
            }
        } catch(std.conv.ConvException e) { /* Broken date, use default */}

        return ldate;
    }


    private void parseParts(string[] lines, MIMEPart parent)
    {
        int startIndex = -1;
        string boundaryPart = format("--%s", parent.ctype.fields["boundary"]);
        string boundaryEnd  = format("%s--", boundaryPart);

        // Find the starting boundary
        foreach (int i, string line; lines)
        {
            if (strip(line) == boundaryPart)
            {
                startIndex = i+1;
                break;
            }
        }

        int endIndex;
        bool finished   = false;
        int globalIndex = startIndex;

        while (!finished && (globalIndex <= lines.length))
        {
            endIndex = -1;
            // Find the next boundary
            foreach(int j, string bline; lines[startIndex..$])
            {
                if (strip(bline) == boundaryPart)
                {
                    endIndex = startIndex+j;
                    break;
                }
                if (strip(bline) == boundaryEnd)
                {
                    endIndex = startIndex+j;
                    finished = true;
                    break;
                }
            }
            if (endIndex == -1)
                return;

            MIMEPart thisPart = new MIMEPart();
            // parsePartHeaders modifies thisPart by reference and returns the
            // real content start index
            int contentStart  = startIndex + parsePartHeaders(thisPart,
                                                              lines[startIndex..endIndex]);
            parent.subparts  ~= thisPart;
            thisPart.parent   = parent;

            if (thisPart.ctype.name.startsWith("multipart"))
                parseParts(lines[startIndex..endIndex], thisPart);

            if (among(thisPart.ctype.name, "text/plain", "text/html"))
            {
                setTextPart(thisPart, join(lines[contentStart..endIndex], this.lineSep));
                debug
                {
                    writeln("========= AFTER PARSEPARTS, CONTENT: ======", thisPart.ctype.name);
                    write(thisPart.textContent);
                    writeln("===========================================");
                }
            }
            else if (among(thisPart.disposition.name, "attachment", "inline"))
                setAttachmentPart(thisPart, lines[contentStart..endIndex]);

            startIndex = endIndex+1;
            ++globalIndex;
        }
    }


    private void setTextPart(MIMEPart part, string text)
    {
        string newtext;
        if ("charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";

        if (part.cTransferEncoding == "quoted-printable")
            newtext = convertToUtf8Lossy(decodeQuotedPrintable(text), 
                                         part.ctype.fields["charset"]);

        else if (part.cTransferEncoding == "base64")
            newtext = convertToUtf8Lossy(decodeBase64Stubborn(text), 
                                         part.ctype.fields["charset"]);

        else
            newtext = text;

        part.textContent = newtext;
        textualParts    ~= part;

        debug
        {
            if (part.textContent.length)
            {
                writeln("===EMAIL OBJECT TEXTUAL PART===");
                write(part.textContent);
                writeln("===END TEXTUAL PART===");
            }
        }
    }


    private void setAttachmentPart(MIMEPart part, string[] lines)
    {
        immutable(ubyte)[] attContent;
        version(unittest) bool wasEncoded = false;

        if (part.cTransferEncoding == "base64")
        {
            attContent = decodeBase64Stubborn(join(lines));
            version(unittest) wasEncoded = true;
        }
        else // binary, 7bit, 8bit, no need to decode... I think...
            attContent = cast(immutable(ubyte)[]) join(lines, this.lineSep);

        string attachFileName;
        string origFileName = part.disposition.fields.get("filename", "");

        if (!origFileName.length) // wild shot, but sometimes it is like that
            origFileName = part.ctype.fields.get("name", "");

        auto attachFullPath = randomFileName(this.attachmentStore, origFileName.extension);
        auto f = File(attachFullPath, "w");
        f.rawWrite(attContent);
        f.close();

        Attachment att;
        att.realPath   = attachFullPath;
        att.ctype      = part.ctype.name;
        att.filename   = origFileName;
        att.size       = att.realPath.getSize;
        att.contentId  = part.contentId;

        version(unittest)
        {
            att.wasEncoded = wasEncoded;
            att.origEncodedContent = join(lines);
        }

        part.attachment   = att;
        this.attachments ~= att;
    }


    private void parseContentHeader(ref ContentData contentData, string headerText)
    {
        if (headerText.length == 0)
            return;

        auto valueTokens = split(strip(headerText), ";");
        if (valueTokens.length == 0) // ???
        {
            contentData.name= "";
            return;
        }

        contentData.name = strip(removechars(valueTokens[0], "\""));
        if (valueTokens.length > 1)
        {
            foreach(string param; valueTokens[1..$])
            {
                param        = strip(removechars(param, "\""));
                auto eqIndex = countUntil(param, "=");
                if (eqIndex == -1)
                    continue;

                contentData.fields[strip(toLower(param[0..eqIndex]))] = strip(param[eqIndex+1..$]);
            }
        }
    }


    // Returns the start index of the real content after the part headers
    private int parsePartHeaders(MIMEPart part, string[] lines)
    {
        void addPartHeader(string text)
        {
            auto idxSeparator = countUntil(text, ":");
            if (idxSeparator == -1 || (idxSeparator+1 > text.length))
                // Some email generators dont put a CRLF
                // after the part header in the text/plain part but
                // something like "----------"
                return;

            string name  = toLower(strip(text[0..idxSeparator]));
            string value = text[idxSeparator+1..$];

            switch(name)
            {
                case "content-type":
                    parseContentHeader(part.ctype, value);
                    break;
                case "content-disposition":
                    parseContentHeader(part.disposition, value);
                    break;
                case "content-transfer-encoding":
                    part.cTransferEncoding = toLower(strip(removechars(value, "\"")));
                    break;
                case "content-id":
                    part.contentId = strip(removechars(value, "\""));
                    break;
                default:
            }
        }

        if (strip(lines[0]).length == 0)
        {
            // a part without part headers is supossed to be text/plain
            part.ctype.name = "text/plain";
            return 0;
        }


        auto partialBuffer = appender!string;
        int idx;
        foreach (string line; lines)
        {
            if (!line.length) // end of headers
            {
                if (partialBuffer.data.length)
                {
                    addPartHeader(partialBuffer.data);
                    partialBuffer.clear();
                }
                break;
            }

            if (partialBuffer.data.length && !among(line[0], ' ', '\t'))
            {
                addPartHeader(partialBuffer.data);
                partialBuffer.clear();
            }
            partialBuffer.put(line);
            ++idx;
        }
        return idx;
    }


    private void getRootContentInfo(MIMEPart part)
    {
        if ("content-type" in this.headers)
            parseContentHeader(part.ctype, headers["content-type"].rawValue);

        if ("content-disposition" in this.headers)
            parseContentHeader(part.disposition, headers["content-disposition"].rawValue);

        if ("content-transfer-encoding" in this.headers)
            part.cTransferEncoding = toLower(strip(removechars(headers["content-transfer-encoding"].rawValue, "\"")));

        if (!part.ctype.name.startsWith("multipart") && "charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";
    }


    ulong computeSize()
    {
        ulong totalSize;
        totalSize += computeBodySize();

        foreach(Attachment attachment; this.attachments)
            totalSize += attachment.size;
        return totalSize;
    }


    ulong computeBodySize()
    {
        ulong totalSize;
        foreach(MIMEPart textualPart; this.textualParts)
            totalSize += textualPart.textContent.length;
        return totalSize;
    }
}



//  _    _       _ _   _            _
// | |  | |     (_) | | |          | |
// | |  | |_ __  _| |_| |_ ___  ___| |_
// | |  | | '_ \| | __| __/ _ \/ __| __|
// | |__| | | | | | |_| ||  __/\__ \ |_
//  \____/|_| |_|_|\__|\__\___||___/\__|
/*
 * HOW TO TEST:
 *
 * Since I'm not putting my personal email collection inside the unittests dirs,
 * here's how to do it yourself:
 *
 * - Get all your emails (or the emails you want to test) into a single mbox file.
 *   For example, Gmail exports all your email in that format with Google Takeout
 *   (https://www.google.com/settings/takeout/custom/gmail)
 *
 * - Split that mbox in single emails running:
 *      rdmd --main -unittest -version=createtestemails incomingemail.d
 *      (you only need to do this once)
 * - Replace, for example with "sed", all your real address for testuser@testdatabase.com:
 *   sed -i 's/myrealemail@gmail.com/testuser@testdatabase.com/g' *
 * - If you want, remove the chats (gmail gives you chat messages as emails and the tests
 *   will fail with them because the to: address is not always yours)
 * - With a stable version (that is, before your start to hack the code), generate
 *   the mime info files with:
 *      rdmd --main -unittest -version=generatetestdata
*       (you only need to do this once, unless you change the mimeinfo format in
*       the function createPartInfoText)
 *
 * Once you have the single emails and the test data you can do:
 *      rdmd --main -unittest => run all the tests on all emails
 *      rdmd --main -singletest => run the code in the singletest version (usually with a
 *      problematic email number hardcoded)
 */

version(unittest)
{
    void visitParts(MIMEPart part)
    {
        writeln("===========");
        writeln("CType Name: "          , part.ctype.name);
        writeln("CType Fields: "        , part.ctype.fields);
        writeln("CDisposition Name: "   , part.disposition.name);
        writeln("CDisposition Fields: " , part.disposition.fields);
        writeln("CID: "                 , part.contentId);
        writeln("Subparts: "            , part.subparts.length);
        writeln("Object hash: "         , part.toHash());
        writeln("===========");

        foreach(MIMEPart subpart; part.subparts)
            visitParts(subpart);
    }


    DirEntry[] getSortedEmailFilesList(string emailsDir)
    {
        DirEntry[] emailFiles;
        foreach(DirEntry e; dirEntries(emailsDir, SpanMode.shallow))
            if (!e.isDir) emailFiles ~= e;

        bool intFileComp(DirEntry x, DirEntry y)
        {
            return to!int(baseName(x.name)) < to!int(baseName(y.name));
        }
        sort!(intFileComp)(emailFiles);

        return emailFiles;
    }

    void createPartInfoText(MIMEPart part, ref Appender!string ap, int level)
    {
        string parentStr;

        ap.put(format("==#== PART ==#==\n"));

        if (part.parent !is null)
            ap.put(format("Son of: %s\n", part.parent.ctype.name));
        else
            ap.put("Root part\n");

        ap.put(format("Level: %d\n", level));
        ap.put(format("Content-Type: %s\n", part.ctype.name));
        ap.put("\tfields: \n");

        if ("charset" in part.ctype.fields)
            ap.put(format("\t\tcharset: %s\n", part.ctype.fields["charset"]));
        if ("boundary" in part.ctype.fields)
            ap.put(format("\t\tboundary: %s\n", part.ctype.fields["boundary"]));

        if (part.disposition.name.length)
        {
            ap.put(format("Content-Disposition: %s\n", part.disposition.name));
            if ("filename" in part.disposition.fields)
                ap.put(format("\t\tfilename: %s\n", part.disposition.fields["filename"]));
        }

        if (part.cTransferEncoding.length)
            ap.put(format("Content-Transfer-Encoding: %s\n", part.cTransferEncoding));

        // attachments are compared with an md5 on the files, not here
        if (part.textContent.length && !among(part.disposition.name, "attachment", "inline"))
        {
            ap.put(format("Content Length: %d\n", part.textContent.length));
            ap.put("##=## CONTENT ##=##\n");
            ap.put(part.textContent);
            ap.put("##=## ENDCONTENT ##=##\n");
        }

        ++level;
        foreach(MIMEPart subpart; part.subparts)
            createPartInfoText(subpart, ap, level);
    }
}


unittest
{
    version(anyincomingmailtest)
    {
        string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
        string origEmailDir     = buildPath(backendTestDir, "emails", "single_emails");
        string rawEmailStore    = buildPath(backendTestDir, "rawemails");
        string attachmentStore = buildPath(backendTestDir, "attachments");
        string base64Dir       = buildPath(backendTestDir, "base64_test");
    }

    version(incomingemail_createtestdata)
    {
        writeln("Splitting test emails...");
        auto mboxFileName = buildPath(backendTestDir, "emails", "testmails.mbox");
        assert(mboxFileName.exists);
        assert(mboxFileName.isFile);

        writeln("Splitting mailbox: ", mboxFileName);

        if (!exists(origEmailDir))
            mkdir(origEmailDir);

        auto mboxf = File(mboxFileName);
        ulong emailindex = 0;
        File emailFile;

        while (!mboxf.eof())
        {
            string line = chomp(mboxf.readln());
            if (line.length > 6 && line[0..5] == "From ")
            {
                if (emailFile.isOpen)
                {
                    emailFile.flush();
                    emailFile.close();
                }

                emailFile = File(buildPath(origEmailDir, to!string(++emailindex)), "w");
                writeln(emailindex);
            }
            emailFile.write(line ~ "\r\n");
        }
    }

    else version(incomingemail_regeneratetestdata)
    {
        // For every email in emaildir, parse, create a emailname_test dir, and create a testinfo file inside
        // with a description of every mime part (ctype, charset, transfer-encoding, disposition, length, etc)
        // and their contents. This will be used in the unittest for comparing the email parsing output with
        // these. Obviously, it's very important to regenerate these files only with Good and Tested versions :)
        writeln("Generating test data, make sure to do this with a stable version");
        auto sortedFiles = getSortedEmailFilesList(origEmailDir);
        foreach(DirEntry e; sortedFiles)
        {
            // parsear email e.name
            // sacar info de partes desde la principal
            // - ctype, charset, content-disposition, length, subparts, parent, transfer-encoding, contenido
            // guardar en fichero
            writeln("Generating testfile for ", e.name);
            if (e.name.isDir)
                continue;

            auto testDir = format("%s_t", e.name);
            if (!testDir.exists)
                mkdir(testDir);

            auto testAttachDir = buildPath(testDir, "attachments");
            if (!testAttachDir.exists)
                mkdir(testAttachDir);

            auto email = new IncomingEmail(rawEmailStore, attachmentStore);
            email.loadFromFile(File(e.name), true);

            auto headerFile = File(buildPath(testDir, "header.txt"), "w");
            headerFile.write(email.printHeaders(true));
            headerFile.close();

            auto ap = appender!string;
            createPartInfoText(email.rootPart, ap, 0);
            auto f = File(buildPath(testDir, "mime_info.txt"), "w");
            f.write(ap.data);
            f.close();
        }

    }

    else version(incomingemail_singletest)
    {

        writeln("Starting single email test...");
        auto filenumber = 30509;
        auto emailFile = File(format("%s/%d", origEmailDir, filenumber), "r"); 
        auto email      = new IncomingEmail(rawEmailStore, attachmentStore);
        email.loadFromFile(emailFile, true);

        visitParts(email.rootPart);
        foreach(MIMEPart part; email.textualParts)
            writeln(part.ctype.name, ":", part.toHash());

        assert("date" in email.headers);
        email.headers.removeAll("references");
        email.addHeader("References: <30140609205429.01E5AC000035B@1xj.tpn.terra.com>\r\n");
        assert(email.headers["references"].addresses.length == 1, "must have one reference");

        email.headers.removeAll("references");
        email.addHeader("References: <20140609205429.01E5AC000035B@1xj.tpn.terra.com> <otracosa@algo.cosa.com>");
        assert(email.headers["references"].addresses.length == 2, "must have two referneces");
        //auto f2 = File("/home/juanjux/webmail/backend/test/dates.txt");
        //while(!f2.eof)
        //{
            //auto line = strip(f2.readln());
            //email.parseDate(line);
        //}
    }

    else version(incomingemail_allemailstest) // normal huge test with all the emails in
    {
        writeln("Starting all emails test...");
        // broken emails, no newline after headers or parts, etc:
        int[string] brokenEmails = ["53290":0, "64773":0, "87900":0, "91208":0, "91210":0,]; 

        // Not broken, but for putting emails that need to be skipped for some reaso
        //int[string] skipMails  = ["41051":0, "41112":0];
        int[string] skipEmails;
        bool copyEmail = true;

        foreach (DirEntry e; getSortedEmailFilesList(origEmailDir))
        {
            //if (indexOf(e, "62877") == -1) continue; // For testing a specific email
            //if (to!int(e.name.baseName) < 32000) continue; // For testing from some email forward

            writeln(e.name, "...");
            if (baseName(e.name) in brokenEmails || baseName(e.name) in skipEmails)
                continue;

            auto email = new IncomingEmail(rawEmailStore, attachmentStore);
            email.loadFromFile(File(e.name), copyEmail);

            if (email.computeBodySize() > 16*1024*1024)
                assert(0);

            auto fRef = File(buildPath(format("%s_t", e.name), "header.txt"));
            string headersStr = email.printHeaders(true);
            auto refTextAppender = appender!string;
            while(!fRef.eof)
                refTextAppender.put(fRef.readln());

            if (headersStr != refTextAppender.data)
            {
                auto mis = mismatch(headersStr, refTextAppender.data);
                writeln("UNMATCHED HEADER IN FILE: ", e.name);
                writeln("---ORIGINAL FOLLOWS FROM UNMATCHING POSITION:");
                writeln(mis[0]);
                writeln("---PARSED FOLLOWS FROM UNMATCHING POSITION:");
                writeln(mis[1]);
                assert(0);
            }
            writeln("\t\t...headers ok!");

            // TEST: Body parts
            auto testFilePath = buildPath(format("%s_t", e.name), "mime_info.txt");
            auto f            = File(testFilePath, "r");
            auto ap1          = appender!string;
            auto ap2          = appender!string;

            while(!f.eof)
                ap1.put(f.readln());

            createPartInfoText(email.rootPart, ap2, 0);

            if (ap1.data == ap2.data)
                writeln("\t\t...MIME parts ok!");
            else
            {
                writeln("Body parts different"                                 );
                writeln("Parsed email: "                                       );
                writeln("----------------------------------------------------" );
                write(ap2.data                                                 );
                writeln("----------------------------------------------------" );
                writeln("Text from testfile: "                                 );
                writeln("----------------------------------------------------" );
                write(ap1.data                                                 );
                writeln("----------------------------------------------------" );
                assert(0);
            }

            // TEST: Attachments
            if (!base64Dir.exists)
                mkdir(base64Dir);

            auto bufBase64  = new ubyte[1024*1024*2]; // 2MB
            auto bufOurfile = new ubyte[1024*1024*2];

            foreach (Attachment att; email.attachments)
            {
                // FIXME: this only text the base64-encoded attachments
                if (!att.wasEncoded)
                    continue;

                system(format("rm -f %s/*", base64Dir));

                auto fnameEncoded = buildPath(base64Dir, "encoded.txt");
                auto encodedFile   = File(fnameEncoded, "w");
                encodedFile.write(att.origEncodedContent);
                encodedFile.flush(); encodedFile.close();

                auto fnameDecoded = buildPath(base64Dir, "decoded");
                auto base64Cmd    = format("base64 -d %s > %s", fnameEncoded, fnameDecoded);
                assert(system(base64Cmd) == 0);
                auto decodedFile  = File(fnameDecoded);
                auto ourFile      = File(buildPath(att.realPath));

                while (!decodedFile.eof)
                {
                    auto bufread1 = decodedFile.rawRead(bufBase64);
                    auto bufread2 = ourFile.rawRead(bufOurfile);
                    ulong idx1, idx2;

                    while (idx1 < bufread1.length && idx2 < bufread2.length)
                    {
                        if (bufread1[idx1] != bufread2[idx2])
                        {
                            writeln("Different attachments!");
                            writeln("Our decoded attachment: "            , ourFile.name);
                            writeln("Base64 command decoded attachment: " , decodedFile.name);
                            assert(0);
                        }
                        ++idx1;
                        ++idx2;
                    }
                }
            }
            writeln("\t...attachments ok!");

            // clean the attachment files and the rawemail
            foreach(Attachment att; email.attachments)
                std.file.remove(att.realPath);
            if (copyEmail)
                std.file.remove(email.rawEmailPath);
        }
    }

    version(incomingemail_allemailstest)
    {
        // Clean the attachment and rawEmail dirs
        system(format("rm -f %s/*", attachmentStore));
        system(format("rm -f %s/*", rawEmailStore));
    }
}

