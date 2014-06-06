#!/usr/bin/env rdmd 

import std.stdio;
import std.file;
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

// XXX Clase para excepciones de parseo
// XXX const, immutable, pure, nothrow, safe, in, out, etc
// XXX mandar los fixes a Adam Druppe

class MIMEPart // #mimepart
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


struct Attachment // #attach
{
    string realPath;
    string cType;
    string filename;
    string content_id;
    ulong size;
    version(unittest) 
    {
        bool was_encoded = false;
        string original_encoded_content;
    }
}


class IncomingEmail
{ 
    string attachDir;
    string rawMailDir;

    DictionaryList!(string, false) headers;
    MIMEPart rootPart;
    MIMEPart[] textualParts; // shortcut to the textual (text or html) parts in display order

    string rawMailPath;
    Attachment[] attachments;
    bool[string] tags; 

    this(string rawMailDir, string attachDir)
    {
        this.attachDir = attachDir;
        this.rawMailDir = rawMailDir;
        this.rootPart = new MIMEPart();
    }


    void loadFromFile(string email_path, bool copyRaw=true)
    {
        auto f = File(email_path);
        this.loadFromFile(f);
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
        }
        else // text/plain||html, just decode and set
            setTextPart(this.rootPart, textBuffer.data);

        // Finally, copy the email to rawMailPath and keep the route 
        // (the user of this class is responsible for deleting the original if needed)
        if (copyRaw && this.rawMailDir.length)
        {
            string destFilePath;
            do {
                destFilePath = buildPath(this.rawMailDir, format("%d_%d", stdTimeToUnixTime(Clock.currStdTime), uniform(0, 100000)));
            } while(destFilePath.exists);
            
            copy(email_file.name, destFilePath);
            this.rawMailPath = destFilePath;
        }
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


    void parseParts(string[] lines, MIMEPart parent)
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
        textualParts ~= part;

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
 

    void setAttachmentPart(MIMEPart part, string[] lines)
    {
        immutable(ubyte)[] att_content;
        version(unittest) bool was_encoded = false;

        if (part.content_transfer_encoding == "base64")
        {
            att_content = decodeBase64Stubborn(join(lines)); 
            version(unittest) was_encoded = true;
        }
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
        version(unittest) 
        {
            att.was_encoded = was_encoded;
            att.original_encoded_content = join(lines);
        }

        part.attachment = att;
        this.attachments ~= att;

        debug writeln("Attachment detected: ", att);
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
    int parsePartHeaders(MIMEPart part, string[] lines)
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


    void getRootContentInfo(MIMEPart part)
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


    version(unittest)
    {
        void visitParts(MIMEPart part)
        {
            writeln("===========");
            writeln("CType Name: ", part.ctype.name);
            writeln("CType Fields: ", part.ctype.fields);
            writeln("CDisposition Name: ", part.disposition.name);
            writeln("CDisposition Fields: ", part.disposition.fields);
            writeln("CID: ", part.content_id);
            writeln("Subparts: ", part.subparts.length);
            writeln("Object hash: ", part.toHash());
            writeln("===========");

            foreach(MIMEPart subpart; part.subparts)
                visitParts(subpart);
        }
    }
}


unittest
{
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


    // #unittest start here
    writeln("Starting unittest");

    string webmailMainDir = "/home/juanjux/webmail";
    string backendTestDir = buildPath(webmailMainDir, "backend", "test");
    string origMailDir = buildPath(backendTestDir, "emails", "single_emails");
    string rawMailDir  = buildPath(backendTestDir, "rawmails");
    string attachDir   = buildPath(backendTestDir, "attachments");
    string base64Dir  = buildPath(backendTestDir, "base64_test");

    version(createtestmails)
    {
        auto mbox_fname = buildPath(backendTestDir, "emails", "testmails.mbox");
        assert(mbox_fname.exists);
        assert(mbox_fname.isFile);

        writeln("Splitting mailbox: ", mbox_fname);

        if (!exists(origMailDir)) 
            mkdir(origMailDir);

        auto mboxf = File(mbox_fname);
        ulong mailindex = 0;
        File email_file;

        while (!mboxf.eof()) {
            string line = chomp(mboxf.readln());
            if (line.length > 6 && line[0..5] == "From ") {
                if (email_file.isOpen) {
                    email_file.flush();
                    email_file.close();
                    //run_munpack(email_file.name);
                }

                email_file = File(buildPath(origMailDir, to!string(++mailindex)), "w");
                writeln(mailindex);
            }
            email_file.write(line ~ "\r\n");
        }
    }

    else version(generatetestdata)
    {
        // For every mail in maildir, parse, create a mailname_test dir, and create a testinfo file inside 
        // with a description of every mime part (ctype, charset, transfer-encoding, disposition, length, etc) 
        // and their contents. This will be used in the unittest for comparing the email parsing output with
        // these. Obviously, it's very important to regenerate these files only with Good and Tested versions :)
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

            auto email = new IncomingEmail(rawMailDir, attachDir);
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
        auto filenumber = 40398;
        auto email_file = File(format("%s/%d", origMailDir, filenumber), "r"); // text/plain UTF-8 quoted-printable
        auto email = new IncomingEmail(rawMailDir, attachDir);
        email.loadFromFile(email_file, true);
        
        email.visitParts(email.rootPart);
        foreach(MIMEPart part; email.textualParts)
            writeln(part.ctype.name, ":", part.toHash());

    }

    else // normal huge test with all the emails in 
    {
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
            if (to!int(e.name.baseName) < 32000) continue; // For testing from some mail forward

            writeln(e.name, "...");
            if (baseName(e.name) in brokenMails || baseName(e.name) in skipMails)
                continue;

            auto email = new IncomingEmail(rawMailDir, attachDir);
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
            auto testFilePath = buildPath(format("%s_t", e.name), "mime_info.txt");
            auto f = File(testFilePath, "r");
            auto ap1 = appender!string();
            auto ap2 = appender!string();

            while(!f.eof)
                ap1.put(f.readln());

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
            if (!base64Dir.exists)
                mkdir(base64Dir);

            auto buf_base64  = new ubyte[1024*1024*2]; // 2MB
            auto buf_ourfile = new ubyte[1024*1024*2];

            foreach (Attachment att; email.attachments)
            {
                // FIXME: this only text the base64-encoded attachments
                if (!att.was_encoded) 
                    continue;

                system(format("rm -f %s/*", base64Dir));

                auto fname_encoded = buildPath(base64Dir, "encoded.txt");
                auto encoded_f = File(fname_encoded, "w");
                encoded_f.write(att.original_encoded_content);
                encoded_f.flush(); encoded_f.close();

                auto fname_decoded = buildPath(base64Dir, "decoded");
                auto base64_cmd = format("base64 -d %s > %s", fname_encoded, fname_decoded);
                assert(system(base64_cmd) == 0);
                auto decoded_file = File(fname_decoded);
                auto our_file = File(buildPath(att.realPath));

                while (!decoded_file.eof)
                {
                    auto bufread1 = decoded_file.rawRead(buf_base64);
                    auto bufread2 = our_file.rawRead(buf_ourfile);
                    ulong idx1, idx2;

                    while (idx1 < bufread1.length && idx2 < bufread2.length)
                    {
                        if (bufread1[idx1] != bufread2[idx2])
                        {
                            writeln("Different attachments!");
                            writeln("Our decoded attachment: ", our_file.name);
                            writeln("Base64 command decoded attachment: ", decoded_file.name);
                            assert(0);
                        }
                        ++idx1;
                        ++idx2;
                    }
                }
            }
            writeln("\t...attachments ok!");

            // clean the attachment files
            foreach(Attachment att; email.attachments)
                std.file.remove(att.realPath);
        }
    }

    // Clean the attachment and rawMail dirs
    system(format("rm -f %s/*", attachDir));
    system(format("rm -f %s/*", rawMailDir));

}
