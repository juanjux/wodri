#!/usr/bin/env rdmd
module retriever.incomingemail;

version(createtestdata) version     = anyincomingmailtest;
version(regeneratetestdata) version = anyincomingmailtest;
version(singletest) version         = anyincomingmailtest;
version(allmailstest) version       = anyincomingmailtest;

import std.stdio;
import std.path;
import std.regex;
import std.file;
import std.conv;
import std.algorithm;
import std.string;
import std.ascii;
import std.array;
import std.base64;
import std.random;
import std.datetime;
import std.process;
import vibe.utils.dictionarylist;
import retriever.characterencodings;
version(anyincomingmailtest) import retriever.db: getConfig;

auto EMAIL_REGEX = ctRegex!(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}\b", "g");
auto MSGID_REGEX = ctRegex!(r"[a-zA-Z0-9.=_%+\-!#\$&'\*/\?\^`\{\}\|~]+@[a-zA-Z0-9.=_%+\-!#\$&'\*/\?\^`\{\}\|~]+\.[a-zA-Z0-9.=_%+\-!#\$&'\*/\?\^`\{\}\|~]{2,4}\b", "g");


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


final class IncomingEmail { string attachmentStore; string rawMailStore; string
conversationId;

    DictionaryList!(HeaderValue, false) headers; // Note: keys are case insensitive
    MIMEPart rootPart;
    MIMEPart[] textualParts; // shortcut to the textual (text or html) parts in display
    Attachment[] attachments;
    string[] fromAddrs;
    string[] toAddrs;
    string[] ccAddrs;
    string[] bccAddrs;
    string rawMailPath;
    string lineSep = "\r\n";

    this(string rawMailStore, string attachmentStore)
    {
        this.attachmentStore = attachmentStore;
        this.rawMailStore    = rawMailStore;
        this.rootPart        = new MIMEPart();
    }

    @property bool isValid()
    {
        // FIXME: Check the minimal valid headers and the values
        return (
                ("From"          in  headers && headers["From"].addresses.length) &&
                (("To"           in  headers && headers["To"].addresses.length) ||
                 ("Cc"           in  headers && headers["Cc"].addresses.length) ||
                 ("Bcc"          in  headers && headers["Bcc"].addresses.length) ||
                 ("Delivered-To" in  headers && headers["Delivered-To"].addresses.length))
                );
    }


    void loadFromFile(string emailPath, bool copyRaw=true)
    {
        auto f = File(emailPath);
            loadFromFile(f);
    }


    void loadFromFile(File emailFile, bool copyRaw=true)
    {
        enum ParseState
        {
            NotStarted, InHeader, InBody
        }
        ParseState parseState = ParseState.NotStarted;

        string currentLine;
        bool bodyHasParts          = false;
        bool inputIsStdInput       = false; // Need to know if reading from stdin/stderr for the rawCopy
        Appender!string stdinLines = null;
        auto partialBuffer         = appender!string;

        if (copyRaw && among(emailFile, std.stdio.stdin, std.stdio.stderr))
        {
            inputIsStdInput = true;
            stdinLines = appender!string;
        }

        // === Header ===
        uint count = 0;
        while (!emailFile.eof())
        {
            ++count;
            currentLine = emailFile.readln();

            if (!currentLine.length)
                // Possible end of stdin/stderr input
                break;

            if (count == 1)
            {
                this.lineSep = currentLine.endsWith("\r\n")?"\r\n": "\n";
                if (currentLine.startsWith("From "))
                    // mbox format indicator, ignore
                    continue;
            }

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
        }

        // === Body=== (read all into the buffer, the parsing is done outside the loop)
        while (!emailFile.eof())
        {
            if (!currentLine.length)
                break;

            currentLine = emailFile.readln();

            if (inputIsStdInput)
                stdinLines.put(currentLine);

            partialBuffer.put(currentLine);
        }

        if (this.rootPart.ctype.name.startsWith("multipart"))
            parseParts(split(partialBuffer.data, this.lineSep), this.rootPart);
        else
            setTextPart(this.rootPart, partialBuffer.data);

        // Finally, copy the email to rawMailPath
        // (the user of the class is responsible for deleting the original)
        if (copyRaw && this.rawMailStore.length)
        {
            string destFilePath;
            do
            {
                destFilePath = buildPath(this.rawMailStore, format("%d_%d", stdTimeToUnixTime(Clock.currStdTime), uniform(0, 100000)));
            } while(destFilePath.exists);

            if (inputIsStdInput)
            {
                auto f = File(destFilePath, "w");
                f.write(stdinLines.data);
            }
            else
                copy(emailFile.name, destFilePath);

            this.rawMailPath = destFilePath;
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
                textheaders.put(value.rawValue);
            }
            else
                write(name, ":", value);
        }
        return textheaders.data;
    }


    ulong computeSize()
    {
        ulong totalSize;

        foreach(MIMEPart textualPart; this.textualParts)
            totalSize += textualPart.textContent.length;

        foreach(Attachment attachment; this.attachments)
            totalSize += attachment.size;

        return totalSize;
    }


    private void addHeader(string raw)
    {
        auto idxSeparator = indexOf(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length))
            return; // Not header, probably mbox indicator or broken header

        HeaderValue value;
        string name     = raw[0..idxSeparator];
        value.rawValue  = decodeEncodedWord(raw[idxSeparator+1..$]);

        // add the bare emails to the value.addresses field
        auto lowname = toLower(name);
        if (among(lowname, "from", "to", "cc", "bcc", "delivered-to", "x-forwarded-to", "x-forwarded-for"))
            foreach(c; match(value.rawValue, EMAIL_REGEX))
                value.addresses ~= c.hit;
        if (lowname == "references")
            foreach(c; match(value.rawValue, MSGID_REGEX))
                value.addresses ~= c.hit;

        this.headers.addField(name, value);
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
            // parsePartHeaders modifies thisPart by reference and returns the real content start index
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
                    writeln("========= DESPUES PARSEPARTS, CONTENT: ======", thisPart.ctype.name);
                    write(thisPart.textContent);
                    writeln("=============================================");
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
            newtext = convertToUtf8Lossy(decodeQuotedPrintable(text), part.ctype.fields["charset"]);

        else if (part.cTransferEncoding == "base64")
            newtext = convertToUtf8Lossy(decodeBase64Stubborn(text), part.ctype.fields["charset"]);

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

        do {
            attachFileName = format("%d_%d%s", stdTimeToUnixTime(Clock.currStdTime), uniform(0, 100000), extension(origFileName));
        } while(attachFileName.exists);

        string attachFullPath = buildPath(this.attachmentStore, attachFileName);
        auto f = File(attachFullPath, "w");
        f.rawWrite(attContent);
        f.close();

        Attachment att;
        att.realPath   = buildPath(this.attachmentStore, attachFileName);
        att.ctype      = part.ctype.name;
        att.filename   = origFileName;
        att.size       = att.realPath.getSize;
        att.contentId = part.contentId;

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
                auto eqIndex = indexOf(param, "=");
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
            auto idxSeparator = indexOf(text, ":");
            if (idxSeparator == -1 || (idxSeparator+1 > text.length))
                // Some mail generators dont put a CRLF
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
        if ("Content-Type" in this.headers)
            parseContentHeader(part.ctype, this.headers["Content-Type"].rawValue);

        if ("Content-Disposition" in this.headers)
            parseContentHeader(part.disposition, this.headers["Content-Disposition"].rawValue);

        if ("Content-Transfer-Encoding" in this.headers)
            part.cTransferEncoding = toLower(strip(removechars(this.headers["Content-Transfer-Encoding"].rawValue, "\"")));

        if (!part.ctype.name.startsWith("multipart") && "charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";
    }


    version(anyincomingmailtest)
    {
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
 * Since I'm not putting my personal email collection inside the unittests dirs, here's how to do it yourself:
 * - Get all your mails (or the mails you want to test) into a single mbox file. For example, Gmail exports
 *   all your mail in that format with Google Takeout (https://www.google.com/settings/takeout/custom/gmail)
 *
 * - Split that mbox in single emails running:
 *      rdmd --main -unittest -version=createtestemails incomingemail.d
 *      (you only need to do this once)
 *
 * - With a stable version (that is, before your start to hack the code), generate the mime info files with:
 *      rdmd --main -unittest -version=generatetestdata
*       (you only need to do this once, unless you change the mimeinfo format in the function createPartInfoText)
 *
 * Once you have the single mails and the test data you can do:
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


    DirEntry[] getSortedEmailFilesList(string mailsDir)
    {
        DirEntry[] emailFiles;
        foreach(DirEntry e; dirEntries(mailsDir, SpanMode.shallow))
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
    // #unittest start here
    // FIXME XXX: read connection data and DB name from text config file
    version(anyincomingmailtest)
    {
        string backendTestDir  = buildPath(getConfig().mainDir, "backend", "test");
        string origMailDir     = buildPath(backendTestDir, "emails", "single_emails");
        string rawMailStore    = buildPath(backendTestDir, "rawmails");
        string attachmentStore = buildPath(backendTestDir, "attachments");
        string base64Dir       = buildPath(backendTestDir, "base64_test");
    }

    version(createtestdata)
    {
        writeln("Splitting test emails...");
        auto mboxFileName = buildPath(backendTestDir, "emails", "testmails.mbox");
        assert(mboxFileName.exists);
        assert(mboxFileName.isFile);

        writeln("Splitting mailbox: ", mboxFileName);

        if (!exists(origMailDir))
            mkdir(origMailDir);

        auto mboxf = File(mboxFileName);
        ulong mailindex = 0;
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

                emailFile = File(buildPath(origMailDir, to!string(++mailindex)), "w");
                writeln(mailindex);
            }
            emailFile.write(line ~ "\r\n");
        }
    }

    else version(regeneratetestdata)
    {
        // For every mail in maildir, parse, create a mailname_test dir, and create a testinfo file inside
        // with a description of every mime part (ctype, charset, transfer-encoding, disposition, length, etc)
        // and their contents. This will be used in the unittest for comparing the email parsing output with
        // these. Obviously, it's very important to regenerate these files only with Good and Tested versions :)
        writeln("Generating test data, make sure to do this with a stable version");
        auto sortedFiles = getSortedEmailFilesList(origMailDir);
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

            auto email = new IncomingEmail(rawMailStore, attachmentStore);
            email.loadFromFile(File(e.name), true);

            auto ap = appender!string;
            createPartInfoText(email.rootPart, ap, 0);
            auto testFile = buildPath(testDir, "mime_info.txt");
            auto f = File(testFile, "w");
            f.write(ap.data);
            f.close();
        }

    }

    else version(singletest)
    {

        // Specific tests
        // 22668 => multipart base64
        // 1973  => text/plain UTF-8 quoted-printable
        // 10000 => text/plain UTF-8 7bit
        // 36004 => mixed, alternative: plain us-ascii&html quoted-printable, adjunto message/rfc822
        // 40000 => multipart/alternative ISO8859-1 quoted-printable
        // 40398 => muchos adjuntos png referenciados en el html
        // 50000 => multipart/alternative, text/plain sin encoding 7 bit y fuera de parte, text/html ISO8859-1 base64
        // 60000 => multipart/alternative Windows-1252 quoted-printable
        // 80000 => multipart/alternative ISO8859-1 quoted-printable
        writeln("Starting single email test...");
        auto filenumber = 40398;
        auto emailFile = File(format("%s/%d", origMailDir, filenumber), "r"); // text/plain UTF-8 quoted-printable
        auto email      = new IncomingEmail(rawMailStore, attachmentStore);
        email.loadFromFile(emailFile, true);

        email.visitParts(email.rootPart);
        foreach(MIMEPart part; email.textualParts)
            writeln(part.ctype.name, ":", part.toHash());

    }

    else version(allmailstest) // normal huge test with all the emails in
    {
        writeln("Starting all mails test...");
        int[string] brokenMails = ["53290":0, "64773":0, "87900":0, "91208":0, "91210":0,]; // broken mails, no newline after headers or parts, etc

        // Not broken, but for putting mails that need to be skipped for some reaso
        //int[string] skipMails  = ["41051":0, "41112":0];
        int[string] skipMails;
        bool copyMail = true;

        foreach (DirEntry e; getSortedEmailFilesList(origMailDir))
        {
            //if (indexOf(e, "62877") == -1) continue; // For testing a specific mail
            //if (to!int(e.name.baseName) < 32000) continue; // For testing from some mail forward

            writeln(e.name, "...");
            if (baseName(e.name) in brokenMails || baseName(e.name) in skipMails)
                continue;

            auto email = new IncomingEmail(rawMailStore, attachmentStore);
            email.loadFromFile(File(e.name), copyMail);

            string headersStr = email.printHeaders(true);
            auto headerLines  = split(headersStr, email.lineSep);
            auto origFile     = File(e.name);

            // Consume the first line (with the mbox From)
            origFile.readln();

            // TEST: HEADERS
            int idx = 0;
            while(!origFile.eof())
            {
                string origLine = decodeEncodedWord(origFile.readln());
                if (origLine == email.lineSep) // Body start, stop comparing
                    break;

                auto headerLine = headerLines[idx] ~ email.lineSep;
                if (origLine != headerLine)
                {
                    writeln("UNMATCHED HEADER IN FILE: ", e.name);
                    write("\nORIGINAL: |",origLine, "|");
                    write("\nOUR     : |", headerLine, "|");
                    writeln("All headers:");
                    writeln(join(headerLines, "\r\n"));
                    writeln("------------------------------------------------------");
                    assert(0);
                    //break;
                }
                ++idx;
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

            // clean the attachment files and the rawmail
            foreach(Attachment att; email.attachments)
                std.file.remove(att.realPath);
            if (copyMail)
                std.file.remove(email.rawMailPath);
        }
    }
    version(anyincomingmailtest)
        // Clean the attachment and rawMail dirs
        system(format("rm -f %s/*", attachmentStore));
}
