module retriever.incomingemail;

import arsd.characterencodings;
import common.utils;
import std.algorithm;
import std.array;
import std.ascii;
import std.base64;
import std.conv;
import std.datetime;
import std.file;
import std.path;
import std.random;
import std.range;
import std.regex;
import std.stdio;
import std.string;
import std.typecons;
import vibe.utils.dictionarylist;

version(incomingemail_createtestdata)     version = anyincomingmailtest;
version(incomingemail_regeneratetestdata) version = anyincomingmailtest;
version(incomingemail_singletest)         version = anyincomingmailtest;
version(incomingemail_allemailstest)      version = anyincomingmailtest;
version(anyincomingmailtest)
{
    import db.config: getConfig;
    import std.process;
}

auto EMAIL_REGEX = ctRegex!(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}\b", "g");
auto MSGID_REGEX = ctRegex!(r"[\w@.=%+\-!#\$&'\*/\?\^`\{\}\|~]*\b", "g");
string[] MONTH_CODES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul",
                        "Aug", "Sep", "Oct", "Nov", "Dec"];


struct ContentData
{
    string name;
    string[string] fields;
}


private struct MIMEPart
{
    MIMEPart *parent = null;
    MIMEPart[] subparts;
    ContentData ctype;
    ContentData disposition;
    string cTransferEncoding;
    string contentId;
    string textContent;
    Attachment attachment;
}


struct Attachment
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
    // FIXME: postblit constructor copying both values (cant do now
    // because of DMD 2.0.66 bug)
}


final class IncomingEmail
{
    private
    {
        DictionaryList!(HeaderValue, false) m_headers; // Note: keys are case insensitive
        DateTime     m_date;
        MIMEPart[]   m_textualParts;
        Attachment[] m_attachments;
        MIMEPart     rootPart;
        string       m_rawEmailPath;
        string       lineSep = "\r\n";
    }
    version(anyincomingmailtest)
        package bool generatedMessageId = false;


    @property Flag!"IsValidEmail" isValid() const
    {
        return ((getHeader("to").addresses.length  ||
                 getHeader("cc").addresses.length  ||
                 getHeader("bcc").addresses.length ||
                 getHeader("delivered-to").addresses.length)) ? Yes.IsValidEmail
                                                              : No.IsValidEmail;
    }
    @property ref const(DictionaryList!(HeaderValue, false)) headers() const
    {
        return m_headers;
    }
    @property ref const(DateTime) date()         const { return m_date; }
    @property const(Attachment[]) attachments()  const { return m_attachments; }
    @property string              rawEmailPath() const { return m_rawEmailPath; }
    @property const(MIMEPart[])   textualParts() const { return m_textualParts; }


    /**
        Return the header if it exists. If not, returns an empty HeaderValue.
        Useful when you want a default empty value.
    */
    const(HeaderValue) getHeader(in string name) const
    {
        return hasHeader(name)? m_headers[name]: HeaderValue("", []);
    }


    void removeHeader(in string name)
    {
        m_headers.removeAll(name);
    }


    bool hasHeader(in string name) const
    {
        return (name in m_headers) !is null;
    }


    void loadFromFile(in string emailPath,
                               in string attachStore,
                               in string rawEmailStore="")
    {
        loadFromFile(File(emailPath), attachStore, rawEmailStore);
    }

    void loadFromFile(File emailFile,
                               in string attachStore,
                               in string rawEmailStore = "")
    {
        Appender!string stdinLines;
        string currentLine;

        immutable bool inputIsStdInput = (rawEmailStore.length &&
                                          among(emailFile,
                                          std.stdio.stdin, std.stdio.stderr));

        // === Header ===
        currentLine = emailFile.readln();
        if (currentLine.length)
        {
            // get the style of the line endings used on this email
            // (RFC emails should be \r\n but when reading from stdin they're usually \n)
            this.lineSep = currentLine.endsWith("\r\n") ? "\r\n" : "\n";

            if (currentLine.startsWith("From "))
                // mbox format header, ignore and read next line
                currentLine = emailFile.readln();
        }
        else
            return; // empty input (premature EOF?) => empty email

        string headerStr;
        while (currentLine.length && !emailFile.eof())
        {
            if (inputIsStdInput)
                stdinLines.put(currentLine);

            if (headerStr.length && !among(currentLine[0], ' ', '\t'))
            {
                // Not indented, this line starts a new header (or body)
                addHeader(headerStr); // previous header is loaded, save it
                headerStr = "";
            }
            headerStr ~= currentLine;

            if (currentLine == this.lineSep)
            {
                // Body mark found (line with only a newline character)
                // load the email content info data from the headers into the rootPart
                getRootContentInfo();
                break;
            }
            currentLine = emailFile.readln();
        }

        // check date and message-id headers and provide a default if missing
        if (!hasHeader("date"))
            parseDate("NOW");

        if (!hasHeader("message-id"))
        {
            addHeader("Message-ID: <" ~ generateMessageId ~ "> " ~ this.lineSep);
            version(anyincomingmailtest)this.generatedMessageId = true;
        }

        // === Body=== (read all into the buffer, the parsing is done outside the loop)
        Appender!string bodyBuffer;
        while (currentLine.length && !emailFile.eof())
        {
            currentLine = emailFile.readln();

            if (inputIsStdInput)
                stdinLines.put(currentLine);

            bodyBuffer.put(currentLine);
        }

        if (this.rootPart.ctype.name.startsWith("multipart"))
            parseParts(split(bodyBuffer.data, this.lineSep), this.rootPart, attachStore);
        else
            setTextPart(this.rootPart, bodyBuffer.data);

        // Finally, copy the email to rawEmailPath
        // (the user of the class is responsible for deleting the original)
        if (rawEmailStore.length)
        {
            auto destFilePath = randomFileName(rawEmailStore);
            if (inputIsStdInput)
                File(destFilePath, "w").write(stdinLines.data);
            else
                copy(emailFile.name, destFilePath);

            m_rawEmailPath = destFilePath;
        }
    }


    string headersToString()
    {
        Appender!string textHeaders;
        foreach(string name, const ref value; m_headers)
        {
            textHeaders.put(name ~ ":");
            textHeaders.put(value.rawValue ~ this.lineSep);
        }
        return textHeaders.data;
    }


    void addHeader(in string raw)
    {
        immutable idxSeparator = countUntil(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length))
            return; // Not header, probably mbox indicator or broken header

        HeaderValue value;
        immutable string name     = raw[0..idxSeparator];
        immutable string valueStr = decodeEncodedWord(raw[idxSeparator+1..$]);

        if (valueStr.endsWith("\r\n"))
            value.rawValue = valueStr[0..$-2];
        else
            value.rawValue = valueStr;

        // add the bare emails to the value.addresses field
        switch(toLower(name))
        {
            case "from":
            case "to":
            case "cc":
            case "bcc":
            case "delivered-to":
            case "x-forwarded-to":
            case "x-forwarded-for":
                 foreach(ref c; match(value.rawValue, EMAIL_REGEX))
                    if (c.hit.length) value.addresses ~= c.hit;
                break;
            case "message-id":
                value.addresses = [match(value.rawValue, MSGID_REGEX).hit];
                break;
            case "references":
                 foreach(ref c; match(value.rawValue, MSGID_REGEX))
                    if (c.hit.length) value.addresses ~= c.hit;
                break;
            case "date":
                parseDate(value.rawValue);
                break;
            default:
        }
        m_headers.addField(name, value);
    }


    private void parseDate(in string strDate)
    {
        // Default to current time so we've some date if the format is broken
        DateTime ldate = to!DateTime(Clock.currTime);
        // split by newlines removing empty tokens
        immutable string[] tokDate = strip(strDate).split(' ').filter!(a => !a.empty).array;

        if (strDate != "NOW" && tokDate.length)
        {
            try
            {
                uint posAdjust = 0;
                if (tokDate.length >= 5)
                {
                    // like: Tue, 18 Mar 2014 16:09:36 +0100
                    if (tokDate.length >= 6 &&
                        among(tokDate[0][0..3],
                              "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"))
                        ++posAdjust;
                    // else like: 4 Jan 2005 07:04:19 -0000

                    immutable int month = to!int(countUntil(MONTH_CODES, tokDate[1+posAdjust])+1);
                    immutable int year  = to!int(tokDate[2+posAdjust]);
                    immutable int day   = to!int(tokDate[0+posAdjust]);

                    immutable string[] hmsTokens = tokDate[3+posAdjust].split(":");
                    immutable int hour   = to!int(hmsTokens[0]);
                    immutable int minute = to!int(hmsTokens[1]);
                    immutable int second = hmsTokens.length > 2 ? to!int(hmsTokens[2]) : 0;
                    immutable string tz  = tokDate[4+posAdjust];
                    ldate = DateTime(Date(year, month, day), TimeOfDay(hour, minute, second));

                    // The date is saved on UTC, so we add/substract the TZ
                    if (tz.length == 5 && tz[1..$] != "0000")
                    {
                        immutable int multiplier = tz[0] == '+'? -1: 1;
                        ldate += dur!"hours"(to!int(tz[1..3])*multiplier);
                        ldate += dur!"minutes"(to!int(tz[3..5])*multiplier);
                    }
                }
            } catch(std.conv.ConvException e) { /* Broken date, use default */ }
        }
        // else: broken date, use default
        m_date = ldate;
    }


    // Note: modified MIMEPart (parent) to add itself as son
    private void parseParts(in string[] lines, ref MIMEPart parent, in string attachStore)
    {
        immutable boundaryPart = format("--%s", parent.ctype.fields["boundary"]);
        immutable boundaryEnd  = format("%s--", boundaryPart);

        // Find the starting boundary
        int startIndex = -1;
        foreach (int i, const ref string line; lines)
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
                immutable stripBline = strip(bline);
                if (stripBline == boundaryPart)
                {
                    // start of anidated part
                    endIndex = startIndex+j;
                    break;
                }
                if (stripBline == boundaryEnd)
                {
                    // end of part
                    endIndex = startIndex+j;
                    finished = true;
                    break;
                }
            }

            if (endIndex == -1)
                return;

            // parsePartHeaders updates thisPart by reference and returns the real content
            MIMEPart thisPart;
            // start index
            int contentStart = startIndex +
                               parsePartHeaders(thisPart, lines[startIndex..endIndex]);
            parent.subparts ~= thisPart;
            thisPart.parent  = &parent;

            if (thisPart.ctype.name.lowStartsWith("multipart"))
            {
                parseParts(lines[startIndex..endIndex], thisPart, attachStore);
            }
            else if (thisPart.ctype.name.lowStartsWith("message/") ||
                     thisPart.disposition.name.lowStartsWith("attachment") ||
                     thisPart.disposition.name.lowStartsWith("inline"))
            {
                setAttachmentPart(thisPart, lines[contentStart..endIndex], attachStore);
            }
            // startsWith to protect against some broken emails with text/html blabla
            else if (thisPart.ctype.name.lowStartsWith("text/plain") ||
                     thisPart.ctype.name.lowStartsWith("text/html"))
            {
                setTextPart(thisPart, join(lines[contentStart..endIndex], this.lineSep));
                debug
                {
                    writeln("========= AFTER PARSEPARTS, CONTENT: ======", thisPart.ctype.name);
                    write(thisPart.textContent);
                    writeln("===========================================");
                }
            }

            startIndex = endIndex+1;
            ++globalIndex;
        }
    }


    private void setTextPart(ref MIMEPart part, in string text)
    {
        if ("charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";

        if (part.ctype.name.length == 0)
            part.ctype.name = "text/plain";

        string newtext;
        if (part.cTransferEncoding == "quoted-printable")
        {
            newtext = convertToUtf8Lossy(decodeQuotedPrintable(text),
                                         part.ctype.fields["charset"]);
        }
        else if (part.cTransferEncoding == "base64")
        {
            newtext = convertToUtf8Lossy(decodeBase64Stubborn(text),
                                         part.ctype.fields["charset"]);
        }
        else
        {
            newtext = text;
        }

        part.textContent = newtext;
        m_textualParts  ~= part;

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


    // Modifies part
    private void setAttachmentPart(
            ref MIMEPart part, in string[] lines, in string attachStore
    )
    {
        immutable(ubyte)[] attContent;
        version(unittest) bool wasEncoded = false;

        if (part.cTransferEncoding == "base64")
        {
            attContent = decodeBase64Stubborn(join(lines));
            version(unittest) wasEncoded = true;
        }
        else
            // binary, 7bit, 8bit, no need to decode... I think...
            attContent = cast(immutable(ubyte)[]) join(lines, this.lineSep);

        string origFileName = part.disposition.fields.get("filename", "");
        if (!origFileName.length) // wild shot, but sometimes it is "name" instead
            origFileName = part.ctype.fields.get("name", "");

        immutable string attachFullPath = randomFileName(attachStore, origFileName.extension);
        File(attachFullPath, "w").rawWrite(attContent);

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

        part.attachment = att;
        m_attachments  ~= att;
    }


    // Returns the start index of the real content after the part headers
    private int parsePartHeaders(ref MIMEPart part, in string[] lines)
    {
        void addPartHeader(string text)
        {
            immutable long idxSeparator = countUntil(text, ":");
            if (idxSeparator == -1 || (idxSeparator+1 > text.length))
                // Some email generators (or idiots with a script that got a job at
                // Yahoo!) dont put a CRLF after the part header in the text/plain part
                // but something like "----------"
                return;

            immutable string name  = lowStrip(text[0..idxSeparator]);
            immutable string value = text[idxSeparator+1..$];

            switch(name)
            {
                case "content-type":
                    parseContentHeader(part.ctype, value);
                    break;
                case "content-disposition":
                    parseContentHeader(part.disposition, value);
                    break;
                case "content-transfer-encoding":
                    part.cTransferEncoding = lowStrip(removechars(value, "\""));
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
            if (line.length == 0) // end of headers
            {
                if (partialBuffer.data.length)
                {
                    addPartHeader(partialBuffer.data);
                    partialBuffer = appender!string;
                }
                break;
            }

            if (partialBuffer.data.length && !among(line[0], ' ', '\t'))
            {
                addPartHeader(partialBuffer.data);
                partialBuffer = appender!string;
            }
            partialBuffer.put(line);
            ++idx;
        }
        return idx;
    }


    private void parseContentHeader(ref ContentData contentData, in string headerText)
    {
        if (headerText.length == 0)
            return;

        auto valueTokens = split(strip(headerText), ";");
        if (valueTokens.length == 0) // ???
        {
            contentData.name= "";
            return;
        }

        contentData.name = lowStrip(removechars(valueTokens[0], "\""));
        if (valueTokens.length > 1)
        {
            foreach(string param; valueTokens[1..$])
            {
                param = strip(removechars(param, "\""));
                immutable long eqIndex = countUntil(param, "=");
                if (eqIndex == -1)
                    continue;

                immutable string key   = lowStrip(param[0..eqIndex]);
                immutable string value = strip(param[eqIndex+1..$]);
                contentData.fields[key] = value;
            }
        }
    }


    /** Returns loads the content info obtained from the email headers into "part" */
    private void getRootContentInfo()
    {
        if (hasHeader("content-type"))
            parseContentHeader(this.rootPart.ctype, headers["content-type"].rawValue);

        if (hasHeader("content-disposition"))
            parseContentHeader(
                    this.rootPart.disposition, headers["content-disposition"].rawValue
            );

        if (hasHeader("content-transfer-encoding"))
            this.rootPart.cTransferEncoding = lowStrip(
                                       removechars(
                                             headers["content-transfer-encoding"].rawValue,
                                             "\""
            ));

        // set a default charset if missing
        if (!this.rootPart.ctype.name.startsWith("multipart") &&
            "charset" !in this.rootPart.ctype.fields)
            this.rootPart.ctype.fields["charset"] = "latin1";
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
 * Since I'm not putting my personal email collection inside the unittests dirs, here's
 * how to do it yourself:
 *
 * - Get all your emails (or the emails you want to test) into a single mbox file.  For
 * example, Gmail exports all your email in that format with Google Takeout
 * (https://www.google.com/settings/takeout/custom/gmail)
 *
 * - Split that mbox in single emails running:
 *
 * sh test/incomingmail_createmails.sh
 * (you only need to do this once)

 * - Replace, for example with "sed", all your real address on * the emails for
 * testuser@testdatabase.com:
 *
 * sed -i * 's/myrealemail@gmail.com/testuser@testdatabase.com/g' *
 *
 * - If you want, remove the chats (gmail gives you chat messages as emails and the tests
 * will fail with them because the to: address is not always yours)
 *
 * - With a stable * version (that is, before your start to hack the code), generate the
 * mime info files with:
 *
 * sh test/incomingmail_regenerate_test_data.sh
 * (you only need to do this once, unless you change the mimeinfo format in the function
 * createPartInfoText)
 *
 * Once you have the single emails and the test data you can do:
 *
 * sh test/test_incomingemail_all.sh
 *
 * to run the tests with all your emails. If you want to run the tests over a single
 * email (usually a problematic email) change the hardcoded email number in the test
 * and run:
 *
 * sh test/test_incomingemail_single.sh
 */

version(unittest)
{
    void visitParts(const ref MIMEPart part)
    {
        writeln("===========");
        writeln("CType Name: "          , part.ctype.name);
        writeln("CType Fields: "        , part.ctype.fields);
        writeln("CDisposition Name: "   , part.disposition.name);
        writeln("CDisposition Fields: " , part.disposition.fields);
        writeln("CID: "                 , part.contentId);
        writeln("Subparts: "            , part.subparts.length);
        writeln("Struct address: "      , &part);
        writeln("===========");

        foreach(subpart; part.subparts)
            visitParts(subpart);
    }


    DirEntry[] getSortedEmailFilesList(string emailsDir)
    {
        DirEntry[] emailFiles;
        foreach(ref e; dirEntries(emailsDir, SpanMode.shallow))
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
        foreach(subpart; part.subparts)
            createPartInfoText(subpart, ap, level);
    }
}


unittest
{
    version(anyincomingmailtest)
    {
        string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
        string origEmailDir    = buildPath(backendTestDir, "emails", "single_emails");
        string rawEmailStore   = buildPath(backendTestDir, "rawemails");
        string attachStore     = buildPath(backendTestDir, "attachments");
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
        foreach(ref DirEntry e; sortedFiles)
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

            auto email = new IncomingEmail();
            email.loadFromFile(File(e.name), attachStore, rawEmailStore);

            auto headerFile = File(buildPath(testDir, "header.txt"), "w");
            headerFile.write(email.headersToString);
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
        auto filenumber = 20013;
        auto emailFile  = File(format("%s/%d", origEmailDir, filenumber), "r");
        auto email      = new IncomingEmail();
        email.loadFromFile(emailFile, attachStore, rawEmailStore);
        assert(email.isValid);

        visitParts(email.rootPart);
        foreach(part; email.textualParts)
            writeln(part.ctype.name, ":", &part);

        assert("date" in email.headers);
        email.removeHeader("references");
        email.addHeader("References: <30140609205429.01E5AC000035B@1xj.tpn.terra.com>\r\n");
        assert(email.headers["references"].addresses.length == 1, "must have one reference");

        email.removeHeader("references");
        email.addHeader("References: <20140609205429.01E5AC000035B@1xj.tpn.terra.com> <otracosa@algo.cosa.com>");
        assert(email.headers["references"].addresses.length == 2, "must have two referneces");
        //auto f2 = File("/home/juanjux/wodri/backend/test/dates.txt");
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
        int[string] brokenEmails = ["53290":0, "64773":0, "87900":0, "91208":0, "91210":0,
                                    "2312":0];

        // Not broken, but for putting emails that need to be skipped for some reaso
        int[string] skipEmails  = ["-1":0];

        auto emailStore = rawEmailStore; // put to "" to avoid copying in the test
        foreach (ref DirEntry e; getSortedEmailFilesList(origEmailDir))
        {
            //if (indexOf(e, "62877") == -1) continue; // For testing a specific email
            //if (to!int(e.name.baseName) < 10072) continue; // For testing from some email forward

            writeln(e.name, "...");
            if (baseName(e.name) in brokenEmails || baseName(e.name) in skipEmails)
                continue;

            auto email = new IncomingEmail();
            email.loadFromFile(File(e.name), attachStore, emailStore);
            assert(email.isValid);

            uint numPlain, numHtml, other;
            foreach(part; email.textualParts)
            {
                auto ls = lowStrip(part.ctype.name);
                if (ls.startsWith("text/plain")) ++numPlain;
                else if (ls.startsWith("text/html")) ++numHtml;
                else if (ls.startsWith("message/")) continue;
                else ++other;
            }
            assert(other == 0);

            // TEST: Headers
            if (!email.generatedMessageId)
            {
                auto fRef            = File(buildPath(format("%s_t", e.name), "header.txt"));
                string headersStr    = email.headersToString();
                auto refTextAppender = appender!string;

                while(!fRef.eof)
                    refTextAppender.put(fRef.readln());

                if (headersStr != refTextAppender.data)
                {
                    auto mis = mismatch(headersStr, refTextAppender.data);
                    // Ignore mismatchs on message-id only, we regenerate the msgid when missing
                    writeln("UNMATCHED HEADER IN FILE: ", e.name);
                    writeln("---ORIGINAL FOLLOWS FROM UNMATCHING POSITION:");
                    writeln(mis[0]);
                    writeln("---PARSED FOLLOWS FROM UNMATCHING POSITION:");
                    writeln(mis[1]);
                    assert(0);
                }
                writeln("\t\t...headers ok!");
            }

            // TEST: Body parts
            auto testFilePath = buildPath(format("%s_t", e.name), "mime_info.txt");
            auto f            = File(testFilePath, "r");
            auto ap1          = appender!string;
            auto ap2          = appender!string;

            while(!f.eof) ap1.put(f.readln());

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

            foreach (ref Attachment att; email.m_attachments)
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
            foreach(ref Attachment att; email.m_attachments)
                std.file.remove(att.realPath);
            if (emailStore.length)
                std.file.remove(email.rawEmailPath);
        }
        // Clean the attachment and rawEmail dirs
        system(format("rm -f %s/*", attachStore));
        system(format("rm -f %s/*", rawEmailStore));
    }
}


unittest // capitalizeHeader
{
    assert(capitalizeHeader("mime-version")   == "MIME-Version");
    assert(capitalizeHeader("subject")        == "Subject");
    assert(capitalizeHeader("received-spf")   == "Received-SPF");
    assert(capitalizeHeader("dkim-signature") == "DKIM-Signature");
    assert(capitalizeHeader("message-id")     == "Message-ID");
}
