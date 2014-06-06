#!/usr/bin/env rdmd 

import std.stdio;
import std.file: dirEntries, DirEntry, SpanMode, isDir, exists, mkdir, getSize, copy;
import std.path;
import std.conv;
import std.algorithm;
import std.string;
import std.ascii;
import std.array;
import std.base64;
import std.random;
import std.datetime;
import std.process;


// lib.dictionarylist is vibed.utils.dictionarylist modified so it doesnt need
// vibed's event loop 
import lib.dictionarylist; import lib.characterencodings;

// XXX FIXME: Ver que pasa con los adjuntos que fallan y porque los decodifica distinto, probar cosas
// XXX Clase para excepciones de parseo
// XXX ContentInfo.type deberia ser un enum?
// XXX const, immutable, pure, nothrow, safe, in, out, etc
// XXX mandar los fixes a Adam Druppe

class MIMEPart
{
    MIMEPart parent = null;
    MIMEPart[] subparts;
    ContentData ctype;
    ContentData disposition;
    string content_transfer_encoding;
    string content_id;
    string textContent;
    Attachment attachment;
}


struct ContentData
{
    string name;
    string[string] fields;
}


// XXX Mirar otros campos
struct Attachment
{
    string realPath;
    string cType;
    string filename;
    string content_id;
    ulong size;
    version(unittest) string original_encoded_content;
}


class ProtoEmail
{ 
    string attachDir;
    string rawMailDir;

    DictionaryList!(string, false) headers;
    MIMEPart rootPart;

    string textBody;
    string htmlBody;
    string rawMailPath;
    Attachment[] attachments;
    bool[string] tags; // XXX usar set?

    this(string rawMailDir, string attachDir)
    {
        this.attachDir = attachDir;
        this.rawMailDir = rawMailDir;
        this.rootPart = new MIMEPart();
    }


    void loadFromFile(File email_file, bool copyRaw=true) 
    {
        string line;
        bool inBody = false;
        bool bodyHasParts = false;
        auto textBuffer = appender!string();

        uint count = 0;
        while (!email_file.eof()) 
        {
            ++count;
            line = email_file.readln();

            if (count == 1 && line.startsWith("From "))
                // mbox start indicator, ignore
                continue;

            if (!inBody) // Header
            { 
                if (!among(line[0], ' ', '\t'))
                { 
                    // New header, register the current header buffer and clear it
                    addHeader(textBuffer.data);
                    textBuffer.clear();
                }
                // else: indented lines of multiline headers dont register it ey
                textBuffer.put(line);

                if (line == "\r\n") // Body
                {
                    inBody = true; 
                    getRootContentInfo(this.rootPart);
                    textBuffer.clear();
                    
                    if (this.rootPart.ctype.name.startsWith("multipart"))
                        bodyHasParts = true;

                }
            }
            else // Body
                textBuffer.put(line);
        }

        if (bodyHasParts)
        {
            parseParts(split(textBuffer.data, "\r\n"), this.rootPart);
            visitParts(this.rootPart);
        }
        else // text/plain||html, just decode and set
            setTextPart(this.rootPart, textBuffer.data);
    }


    void addHeader(string raw) 
    {
        auto idxSeparator = indexOf(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length)) 
            return; // Not header, probably mbox indicator or broken header
    
        string name  = raw[0..idxSeparator];
        string value = raw[idxSeparator+1..$];
        this.headers.addField(name, decodeEncodedWord(value));
    }


    void parseParts(string[] lines, ref MIMEPart parent)
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
        bool finished = false;
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
                return; // correct?

            MIMEPart thisPart = new MIMEPart();
            int contentStart = startIndex + parsePartHeaders(thisPart, lines[startIndex..endIndex]);
            parent.subparts ~= thisPart;
            thisPart.parent = parent;

            if (thisPart.ctype.name.length > 9 && thisPart.ctype.name[0..9] == "multipart")
                parseParts(lines[startIndex..endIndex], thisPart);

            if (among(thisPart.ctype.name, "text/plain", "text/html"))
            {
                setTextPart(thisPart, join(lines[contentStart..endIndex], "\r\n"));
                debug
                {
                    writeln("========= DESPUES PARSEPARTS, CONTENT: ======", thisPart.ctype.name);
                    write(thisPart.textContent); 
                    writeln("=============================================");
                }
            }
            else if (among(thisPart.disposition.name, "attachment", "inline"))
            {
                setAttachmentPart(thisPart, lines[contentStart..endIndex]);
            }

            startIndex = endIndex+1;
            ++globalIndex;
        }
    }


    void setTextPart(MIMEPart part, string text)
    {
        string newtext;
        if ("charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";

        if (part.content_transfer_encoding == "quoted-printable")
            newtext = convertToUtf8Lossy(decodeQuotedPrintable(text), part.ctype.fields["charset"]);

        else if (part.content_transfer_encoding == "base64")
            newtext = convertToUtf8Lossy(decodeBase64Stubborn(text), part.ctype.fields["charset"]);

        else
            newtext = text;

        part.textContent = newtext;

        if (part.ctype.name == "text/html")
            this.htmlBody = newtext;
        else
            this.textBody = newtext;

        debug
        {
            if (this.htmlBody.length) 
            {
                writeln("===EMAIL OBJECT HTMLBODY===");
                write(this.htmlBody); 
                writeln("===ENDHTMLBODY===");
            }
            if (this.textBody.length)
            {
                writeln("===EMAIL OBJECT TEXTBODY==="); 
                write(this.textBody); writeln;
                writeln("===ENDTEXTBODY===");
            }
        }
    }
 

    // XXX mirar valor/referencia para content y part
    void setAttachmentPart(MIMEPart part, string[] lines)
    {
        immutable(ubyte)[] att_content;

        if (part.content_transfer_encoding == "base64")
            att_content = decodeBase64Stubborn(join(lines)); 
        else // binary, 7bit, 8bit, no need to decode... I think
            att_content = cast(immutable(ubyte)[]) join(lines, "\r\n");

        string attachFileName;
        string origFileName = part.disposition.fields.get("filename", "");

        if (!origFileName.length) // wild shot, but sometimes it is like that
            origFileName = part.ctype.fields.get("name", "");

        do {
            attachFileName = format("%d_%d%s", stdTimeToUnixTime(Clock.currStdTime), uniform(0, 100000), extension(origFileName));
        } while(attachFileName.exists);

        string attachFullPath = buildPath(this.attachDir, attachFileName);
        auto f = File(attachFullPath, "w");
        f.rawWrite(att_content);
        f.close();

        Attachment att;
        att.realPath = buildPath(this.attachDir, attachFileName);
        att.cType = part.ctype.name;
        att.filename = origFileName;
        att.size = att.realPath.getSize;
        att.content_id = part.content_id;
        version(unittest) att.original_encoded_content = lines;

        part.attachment = att;
        this.attachments ~= att;

        debug
        {
            writeln("Attachment detected: ", att);
        }
    }


    void parseContentHeader(ref ContentData content_data, string header_text)
    {
        if (header_text.length == 0) return;

        auto value_tokens = split(strip(header_text), ";");
        if (value_tokens.length == 0) // ???
        { 
            content_data.name= "";
            return;
        }
        
        content_data.name = strip(removechars(value_tokens[0], "\""));
        if (value_tokens.length > 1)
        {
            foreach(string param; value_tokens[1..$]) 
            {
                param = strip(removechars(param, "\""));
                auto eqIndex = indexOf(param, "=");
                if (eqIndex == -1) 
                    continue;

                content_data.fields[strip(toLower(param[0..eqIndex]))] = strip(param[eqIndex+1..$]);
            }
        }
    }


    // Returns the start index of the real content after the part headers
    int parsePartHeaders(ref MIMEPart part, string[] lines)
    {
        void addPartHeader(string text)
        {
            auto idxSeparator = indexOf(text, ":");
            if (idxSeparator == -1 || (idxSeparator+1 > text.length))
                // Some mail generators dont put a CRLF 
                // after the part header in the text/plain part but 
                // something like "----------"
                return;

            string name = toLower(strip(text[0..idxSeparator]));
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
                    part.content_transfer_encoding = toLower(strip(removechars(value, "\"")));
                    break;
                case "content-id":
                    part.content_id = strip(removechars(value, "\""));
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


        auto textBuffer = appender!string();
        int idx;
        foreach (string line; lines)
        {
            if (!line.length) // end of headers
            {
                if (textBuffer.data.length)
                {
                    addPartHeader(textBuffer.data);
                    textBuffer.clear();
                }
                break;
            }

            if (textBuffer.data.length && !among(line[0], ' ', '\t'))
            {
                addPartHeader(textBuffer.data);
                textBuffer.clear();
            }
            textBuffer.put(line);
            ++idx;
        }
        return idx;
    }


    void getRootContentInfo(ref MIMEPart part)
    {
        string ct_transfer_encoding;
        parseContentHeader(part.ctype, this.headers.get("Content-Type", ""));
        parseContentHeader(part.disposition, this.headers.get("Content-Disposition", ""));

        if ("Content-Transfer-Encoding" in this.headers)
            part.content_transfer_encoding = toLower(strip(removechars(this.headers["Content-Transfer-Encoding"], "\"")));

        if (!part.ctype.name.startsWith("multipart") && "charset" !in part.ctype.fields)
            part.ctype.fields["charset"] = "latin1";
    }


    string print_headers(bool as_string=false) 
    {
        auto textheaders = appender!string();
        foreach(string name, string value; this.headers) 
        {
            if (as_string)
            {
                textheaders.put(name ~ ":");
                textheaders.put(value);
            }
            else
                write(name, ":", value);
        }
        return textheaders.data;
    }


    void visitParts(MIMEPart part)
    {
        debug
        {
            writeln("===========");
            writeln("CType Name: ", part.ctype.name);
            writeln("CType Fields: ", part.ctype.fields);
            writeln("CDisposition Name: ", part.disposition.name);
            writeln("CDisposition Fields: ", part.disposition.fields);
            writeln("CID: ", part.content_id);
            writeln("Subparts: ", part.subparts.length);
            writeln("===========");
        }

        foreach(MIMEPart subpart; part.subparts)
            visitParts(subpart);
    }
}



// ############### TESTING CODE ###########################


// XXX ponerle version unittest, debug
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


// XXX version debug, unittest
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
    if (part.content_transfer_encoding.length) 
        ap.put(format("Content-Transfer-Encoding: %s\n", part.content_transfer_encoding));

    // attachments are compared with an md5 on the files, not here
    if (part.textContent.length > 0 && !among(part.disposition.name, "attachment", "inline"))
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


void main()
{
    enum State {Disabled, Normal, GenerateTestData}

    version(unittest) 
        State state = State.Disabled;
    else
        State state = State.Normal;

    string webmailMainDir = "/home/juanjux/webmail";
    string origMailsDir = buildPath(webmailMainDir, "backend/test/emails/single_emails");
    string rawMailDir  = buildPath(webmailMainDir, "backend/test/rawmails");
    string attachDir   = buildPath(webmailMainDir, "backend/test/attachments");

    switch(state)
    {
        case State.Normal:

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
            auto filenumber = 40398;
            auto email_file = File(format("%s/%d", origMailsDir, filenumber), "r"); // text/plain UTF-8 quoted-printable
            auto email = new ProtoEmail(rawMailDir, attachDir);
            email.loadFromFile(email_file, true);
        break;

        case State.GenerateTestData:
            // For every mail in maildir, parse, create a mailname_test dir, and create a testinfo file inside 
            // with a description of every mime part (ctype, charset, transfer-encoding, disposition, length, etc) 
            // and their contents. This will be used in the unittest for comparing the email parsing output with
            // these. Obviously, it's very important to regenerate these files only with Good and Tested versions :)
            auto sortedFiles = getSortedEmailFilesList(origMailsDir);
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

                auto email = new ProtoEmail(rawMailDir, attachDir);
                email.loadFromFile(File(e.name), true);

                auto ap = appender!string;
                createPartInfoText(email.rootPart, ap, 0);
                auto testFile = buildPath(testDir, "mime_info.txt");
                auto f = File(testFile, "w");
                f.write(ap.data);
                f.close();
            }
        break;

        default:
    }
}


unittest
{
    // startunittest

    /* For every mail in the testing-mails repo, parse the email, print the headers
     * and compare line by line with the (decoded) original */
    // Note: you need the "base64" binary and the unix "rm" command to run these tests

    writeln("Starting unittest");

    string webmailMainDir = "/home/juanjux/webmail";
    string backendTestDir = buildPath(webmailMainDir, "backend", "test");
    string origMailDir = buildPath(backendTestDir, "emails", "single_emails");
    string rawMailDir  = buildPath(backendTestDir, "rawmails");
    string attachDir   = buildPath(backendTestDir, "attachments");
    string munpackDir  = buildPath(backendTestDir, "munpack_test");

    // Dont these these mails (or munpack decoding \r as \n for some reason)
    int[string] brokenMails = ["53290":0, "64773":0, "87900":0, "91208":0, "91210":0, // broken mails, no newline after headers or parts, etc
                               //"6988":0, "26876": 0, "36004":0, "37674":0, "38511":0, // munpack unpack these files with some different value
                               //"41399":0, "41400":0
                               ];

    // Not broken, but for putting mails that need to be skipped for some reaso
    //int[string] skipMails  = ["41051":0, "41112":0];
    int[string] skipMails;
    
    foreach (DirEntry e; getSortedEmailFilesList(origMailDir))
    {
        //if (indexOf(e, "62877") == -1) continue; // For testing a specific mail
        //if (to!int(e.name.baseName) < 36959) continue; // For testing from some mail forward

        writeln(e.name, "...");
        if (baseName(e.name) in brokenMails || baseName(e.name) in skipMails)
            continue;

        auto email = new ProtoEmail(rawMailDir, attachDir);
        email.loadFromFile(File(e.name));

        string headers_str = email.print_headers(true);
        auto header_lines = split(headers_str, "\r\n");
        auto orig_file = File(e.name);
        // Consume the first line (with the mbox From)
        orig_file.readln();
     
        // TEST: HEADERS
        int idx = 0;
        while(!orig_file.eof())
        {
            string orig_line = decodeEncodedWord(orig_file.readln());
            if (orig_line == "\r\n") // Body start, stop comparing
                break;

            auto header_line = header_lines[idx] ~ "\r\n";
            if (orig_line != header_line)
            {
                writeln("UNMATCHED HEADER IN FILE: ", e.name);
                write("\nORIGINAL: |",orig_line, "|");
                write("\nOUR     : |", header_line, "|");
                writeln("All headers:");
                writeln(join(header_lines, "\r\n"));
                writeln("------------------------------------------------------");
                assert(0);
                //break;
            }
            ++idx;
        }
        writeln("\t\t...headers ok!");

        // TEST: Body parts
        /*
        auto testFilePath = buildPath(format("%s_t", e.name), "mime_info.txt");
        auto f = File(testFilePath, "r");
        auto ap1 = appender!string();
        auto ap2 = appender!string();

        while(!f.eof)
        {
            ap1.put(f.readln());
        }
        createPartInfoText(email.rootPart, ap2, 0);

        if (ap1.data == ap2.data)
            writeln("\t\t...MIME parts ok!");
        else
        {
            writeln("Body parts different");
            writeln("Parsed email: ");
            writeln("----------------------------------------------------");
            write(ap1.data);
            writeln("----------------------------------------------------");
            writeln("Text from testfile: ");
            writeln("----------------------------------------------------");
            write(ap2.data);
            writeln("----------------------------------------------------");
            assert(0);
        }

        // TEST: Attachments
        if (!munpackDir.exists)
            mkdir(munpackDir);

        std.process.system(format("rm %s/*", munpackDir));
        // Copy the original file to munpack_temp
        auto munpack_dest = buildPath(munpackDir, baseName(e.name));
        copy(e.name, munpack_dest);
        std.process.system(format("munpack -q -C %s %s > /dev/null 2>&1", munpackDir, munpack_dest));

        uint[string] filename_trans;  

        // munpack change lot of special chars for "X"
        string munpack_translate(string name)
        {
            dchar[dchar] transTable = ['{': 'X', '}': 'X', '[': 'X', ']': 'X', ' ': 'X', '(': 'X', ')': 'X',
                                       '¿': 'X', '?': 'X'];
            return translate(name, transTable).replace("\t", "XXX");
        }

        // munpack adds a ".1", ".2" to files with the same name, so we do the same
        foreach(uint idxatt, Attachment att; email.attachments)
        {
            uint idxname = 0;
            string newname;
            string separator = ".";
            writeln("XXX att_filename: |", att.filename, "|");
            while (true)
            {
                if (att.filename.length == 0)
                {
                    att.filename = "part";
                    separator = "";
                }

                if (idxname > 0)
                    newname = munpack_translate(format("%s%s%d", att.filename, separator, idxname));
                else
                    newname = munpack_translate(att.filename);

                if (newname !in filename_trans)
                {
                    filename_trans[newname] = idxatt;
                    break;
                }
                ++idxname;
            }
        }

        foreach(string munpack_name, uint att_index; filename_trans)
        {
            writeln("XXX munpack_name: |", munpack_name, "|");
            auto attachment = email.attachments[att_index];
            auto munpack_file = File(buildPath(munpackDir, munpack_name));
            auto our_file = File(attachment.realPath);

            auto buf_munpack = new ubyte[1024*1024*4]; // 4MB
            auto buf_ourfile = new ubyte[1024*1024*4];

            while (!munpack_file.eof)
            {
                auto bufread1 = munpack_file.rawRead(buf_munpack);
                auto bufread2 = our_file.rawRead(buf_ourfile);

                ulong idx1 = 0;
                ulong idx2 = 0;

                while(idx1 < bufread1.length && idx2 < bufread2.length)
                {
                    //write("MUNPACK: ", bufread1[idx1], "\n");
                    //write("WE     : ", bufread2[idx2], "\n");

                    if (bufread1[idx1] != bufread2[idx2])
                    {
                        if (bufread1[idx1] == 10 && bufread2[idx2] == 13)
                            ++idx2; // sometimes munpack changes \n for \r\n on text files 
                        else 
                        {
                            writeln("Different attachments!");
                            writeln("Our decoded attachment: ", our_file.name);
                            writeln("Munpack-decoded attachment: ", munpack_file.name);
                            assert(0);
                        }
                    }
                    ++idx1;
                    ++idx2;
                }
            }
        }
            writeln("\t...attachments ok!");
        */
        // clean the files
        foreach(Attachment att; email.attachments)
            std.file.remove(att.realPath);

    }
}
