#!/usr/bin/env rdmd 

import std.stdio;
import std.file: dirEntries, DirEntry, SpanMode;
import std.path;
import std.conv;
import std.algorithm;
import std.string;
import std.ascii;
import std.array;
import std.base64;
import core.exception;

// lib.dictionarylist is vibed.utils.dictionarylist modified so it doesnt need
// vibed's event loop 
import lib.dictionarylist; import lib.characterencodings;

// XXX Clase para excepciones de parseo
// Capturer AssertError en los encode de Base64
// XXX ContentInfo.type deberia ser un enum?
// XXX const, immutable y toda esa mierda
// XXX mandar los fixes a Adam Druppe

class MIMEPart
{
    MIMEPart* parent = null;
    MIMEPart[] subparts;
    ContentData ctype;
    ContentData disposition;
    string content_transfer_encoding;
    string textContent;

    this()
    {
    }


    this(ref ContentData content_type, ref ContentData content_disposition, string ct_transfer_encoding)
    {
        ctype = content_type;
        disposition = content_disposition;
        content_transfer_encoding = ct_transfer_encoding;
    }
}

struct ContentData
{
    string name;
    string[string] fields;
}


class ProtoEmail
{
    // XXX faltan attachments (list de structs attachments)
    DictionaryList!(string, false) headers;
    MIMEPart rootPart;
    string textBody;
    string htmlBody;

    this()
    {
        this.rootPart = new MIMEPart();
    }

    this(File emailf)
    {
        this();
        parseEmail(emailf);
    }


    void parseEmail(File email_file) 
    {
        string line;
        bool inBody = false;
        bool bodyHasParts = false;
        auto headerBuffer = appender!string();
        auto bodyBuffer = appender!string();

        uint count = 0;
        while (!email_file.eof()) 
        {
            ++count;
            line = email_file.readln();

            //if (count == 1 && line.length > 5 && line[0..5] == "From ") // mbox initial line
            if (count == 1 && line.startsWith("From "))
                continue;

            if (!inBody) // Header
            { 
                //if (line[0] != ' ' && line[0] != '\t') 
                if (!among(line[0], ' ', '\t'))
                { 
                    // New header, add the current (previous) header buffer to the object and clear it
                    addHeader(headerBuffer.data);
                    headerBuffer.clear();
                }
                // else: indented lines of multiline headers just get added to the headerBuffer
                headerBuffer.put(line);

                if (line == "\r\n") // Body
                {
                    inBody = true; 
                    getBodyHeadersContentInfo(this.rootPart);
                    
                    if (this.rootPart.ctype.name.startsWith("multipart"))
                    {
                        bodyHasParts = true;
                        headerBuffer.clear();
                    }
                }
            }
            else // Body
                bodyBuffer.put(line);
        }

        if (bodyHasParts)
        {
            parseParts(split(bodyBuffer.data, "\r\n"), this.rootPart.ctype.fields["boundary"], this.rootPart);
            visitParts(this.rootPart);
        }
        else // text/plain||html, just decode and set
        {
            setTextPart(this.rootPart, bodyBuffer.data);
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
        {
            //newtext = convertToUtf8Lossy(Base64.decode(removechars(text, "\r\n")), part.ctype.fields["charset"]);
            string nolinetext = removechars(text, "\r\n");
            try
            {
                auto rem = nolinetext.length % 4;
                if (rem)
                {
                    auto padAppender = appender!string();
                    padAppender.put(nolinetext);
                    for (int i; i<(4-rem); i++) padAppender.put("=");
                    nolinetext = padAppender.data;
                }
                
                newtext = convertToUtf8Lossy(Base64.decode(nolinetext), part.ctype.fields["charset"]);
            } catch (AssertError e) 
            {
                // When the former method fails this usually works (and vice versa) :-/
                ubyte[] bytetext;
                foreach (string line; split(text, "\r\n")) 
                    bytetext ~= Base64.decode(line);
                newtext = convertToUtf8Lossy(bytetext.idup, part.ctype.fields["charset"]);
            }

        }
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
    

    void parseParts(string[] lines, string boundary, ref MIMEPart parent)
    {
        int startIndex = -1;
        string boundaryPart = format("--%s", boundary);
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

        while (!finished && globalIndex <= lines.length)
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
            int contentStart = parsePartHeaders(thisPart, lines[startIndex..endIndex]);

            parent.subparts ~= thisPart;

            if (thisPart.ctype.name.length > 9 && thisPart.ctype.name[0..9] == "multipart")
                parseParts(lines[startIndex..endIndex], thisPart.ctype.fields["boundary"], thisPart);

            if (thisPart.ctype.name == "text/plain" || thisPart.ctype.name == "text/html")
            {
                setTextPart(thisPart, join(lines[startIndex+contentStart..endIndex], "\r\n"));
                debug
                {
                    writeln("========= DESPUES PARSEPARTS, CONTENT: ======", thisPart.ctype.name);
                    write(thisPart.textContent); 
                    writeln("=============================================");
                }
            }

            // XXX thisPart.disposition.name == "attachment" || "inline":
            // 1. sacar el contenido, decodificarlo
            // 2. guardar en emails/attachments con un nombre unico
            // 3. poner como contenido <<ruta>>

            startIndex = endIndex+1;
            ++globalIndex;
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


    private void parseContentHeader(ref ContentData content_data, string header_text)
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


    int parsePartHeaders(ref MIMEPart part, string[] lines)
    // Return the start of the real content without headers
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
            string ct_transfer_encoding;

            if (name == "content-type")
                parseContentHeader(part.ctype, value);
            else if (name == "content-disposition")
                parseContentHeader(part.disposition, value);
            else if (name == "content-transfer-encoding") 
                part.content_transfer_encoding = strip(removechars(value, "\""));
        }

        if (strip(lines[0]).length == 0) 
        {
            // a part without part headers is supossed to be text/plain
            part.ctype.name = "text/plain";
            return 0;
        }


        auto headerBuffer = appender!string();
        int idx;
        foreach (string line; lines)
        {
            if (!line.length) // end of headers
            {
                if (headerBuffer.data.length)
                {
                    addPartHeader(headerBuffer.data);
                    headerBuffer.clear();
                }
                break;
            }

            if (headerBuffer.data.length && !among(line[0], ' ', '\t'))
            {
                addPartHeader(headerBuffer.data);
                headerBuffer.clear();
            }
            headerBuffer.put(line);
            ++idx;
        }
        return idx;
    }


    void getBodyHeadersContentInfo(ref MIMEPart part)
    {
        string ct_transfer_encoding;
        parseContentHeader(part.ctype, this.headers.get("Content-Type", ""));
        parseContentHeader(part.disposition, this.headers.get("Content-Disposition", ""));

        if ("Content-Transfer-Encoding" in this.headers)
            part.content_transfer_encoding = strip(removechars(this.headers["Content-Transfer-Encoding"], "\""));

        if ("charset" !in part.ctype.fields)
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
            writeln("Name: ", part.ctype.name);
            writeln("Fields: ", part.ctype.fields);
            writeln("Subparts: ", part.subparts.length);
            writeln("===========");
        }

        foreach(MIMEPart subpart; part.subparts)
            visitParts(subpart);
    }
}


void main()
{

    // 22668 => multipart base64
    // 1973  => text/plain UTF-8 quoted-printable
    // 10000 => text/plain UTF-8 7bit
    // 40000 => multipart/alternative ISO8859-1 quoted-printable
    // 50000 => multipart/alternative, text/plain sin encoding 7 bit y fuera de parte, text/html ISO8859-1 base64
    // 60000 => multipart/alternative Windows-1252 quoted-printable
    // 80000 => multipart/alternative ISO8859-1 quoted-printable
    auto filenumber = 22668;
    auto email_file = File(format("emails/single_emails/%d", filenumber), "r"); // text/plain UTF-8 quoted-printable

    auto email = new ProtoEmail(email_file);
    //email.print_headers();
    //// Imprimir From, To, Cc, Bcc, Data, Subject
    //writeln("\n\nCommon headers:");
    //writeln("To: ", email.headers.get("To", ""));
    //writeln("From: ", email.headers.get("From", ""));
    //writeln("Subject: ", email.headers.get("Subject", ""));
    //writeln("Date: ", email.headers.get("Date", ""));
    //writeln("Cc: ", email.headers.get("Cc", ""));
    //writeln("Bcc: ", email.headers.get("Bcc", ""));
}


unittest
{
    /* For every mail in the testing-mails repo, parse the email, print the headers
     * and compare line by line with the (decoded) original */
    writeln("Starting unittest");
    string repodir = "emails/single_emails/";

    // Dont these these mails 
    int[string] brokenMails = ["53290":0, "64773":0, "87900":0, "91208":0, "91210":0];


    DirEntry[] emailFiles;
    foreach(DirEntry e; dirEntries(repodir, SpanMode.shallow))
        emailFiles ~= e;

    bool intFileComp(DirEntry x, DirEntry y) 
    {
        return to!int(baseName(x.name)) < to!int(baseName(y.name));
    }
    sort!(intFileComp)(emailFiles);

    foreach (DirEntry e; emailFiles)
    {
        //if (indexOf(e.name, "7038") == -1) continue;
        writeln(e.name);
        if (baseName(e.name) in brokenMails) continue;

        auto email = new ProtoEmail(File(e.name));
        string headers_str = email.print_headers(true);
        auto header_lines = split(headers_str, "\r\n");
        auto orig_file = File(e.name);
        // Consume the first line (with the mbox From)
        orig_file.readln();
        
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
    }
}
