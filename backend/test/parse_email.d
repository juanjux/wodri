#!/usr/bin/env rdmd 

import std.stdio;
import std.file: dirEntries, DirEntry, SpanMode;
import std.path;
import std.conv;
import std.string;
import std.ascii;
import std.array;
import std.base64;

// lib.dictionarylist is vibed.utils.dictionarylist modified so it doesnt need
// vibed's event loop (with key deletions removed but we doesn't need it here)
// It's like a hash but keeping insert order and can assign multiple values to
// every key
import lib.dictionarylist;
import lib.characterencodings;

// XXX Clase para excepciones de parseo
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
    Appender!string content; 

    this()
    {
        content = appender!string();
    }

    this(ref ContentData content_type, ref ContentData content_disposition)
    {
        ctype = content_type;
        disposition = content_disposition;
    }
}

struct ContentData
{
    string name;
    string[string] fields;
}


class ProtoEmail
{
    DictionaryList!(string, false) headers;
    // idx of these fields in the Header[] array, the properties to
    // read them will return the text
    MIMEPart[] parts;
    string textBody;
    string htmlBody;

    dchar[] content; // for non multipart mails

    this(File emailf)
    {
        parseEmail(emailf);
    }


    void parseEmail(File email_file) 
    {
        string line;
        bool inBody = false;
        bool firstBodyLine = true;
        bool prevWasStart = false;
        bool bodyHasParts = false;
        bool inPartHeader = false;
        auto headerBuffer = appender!string();
        auto bodyBuffer = appender!string();
        ContentData content_type;
        ContentData content_disposition;
        string content_transfer_encoding;
        MIMEPart bodyParentPart;
        // XXX probar con referencias
        MIMEPart* currentPart = null;

        headerBuffer.reserve(16000);

        uint count = 0;
        while (!email_file.eof()) 
        {
            ++count;
            line = email_file.readln();

            if (count == 1 && line.length > 5 && line[0..5] == "From ") // mbox initial line
                continue;

            if (!inBody) // Header
            { 

                if (prevWasStart) 
                { 
                    if (line[0] == ' ' || line[0] == '\t') 
                        prevWasStart = false; // second line of multiline header

                    else 
                    {
                        // Previous was a singleline header and this is a new header start so add the previous
                        addHeader(headerBuffer.data);
                        headerBuffer.clear();
                        headerBuffer.reserve(16000);
                    }
                }
                else 
                {
                    if (line[0] != ' ' && line[0] != '\t') 
                    {  // Not indented, previous line was the last line of multiline header, add the previous
                       // and save the current line in the new header buffer
                        addHeader(headerBuffer.data);
                        headerBuffer.clear();
                        headerBuffer.reserve(16000);
                        prevWasStart = true;
                    }
                }
                headerBuffer.put(line);

                if (line == "\r\n") // Body
                {
                    inBody = true; 
                    content_transfer_encoding = getHeadersContentInfo(content_type, content_disposition);
                    
                    if (content_type.name != "text/plain" && content_type.name != "text/html")
                    {
                        bodyHasParts = true;
                        bodyParentPart = new MIMEPart(content_type, content_disposition);  
                        currentPart = &bodyParentPart; // XXX bodyParentPart redundante?
                    }
                }

            }
            else // Body
            { 
                // Read the rest of the body, we'll parse after the loop
                if (bodyHasParts)
                {
                    // XXX poner la parte del inPartHeader antes de buscar boundaries
                    if (line.length > 2 && line[0..2] == "--")
                    {
                        if (line.length > 4 && line[$-4..$] == "--\r\n" && currentPart != null)
                        {
                            // Boundary end, new currentPart is the current part parent
                           currentPart = (*currentPart).parent;
                        }
                        else if (currentPart != null)                        
                        {
                            // New subpart of the current part
                            MIMEPart newPart = new MIMEPart();
                            newPart.parent = currentPart;
                            currentPart = &newPart;
                            inPartHeader = true;
                        }
                        
                    }
                    else if (inPartHeader) 
                    {
                        // Part headers parsing (first lines after boundary until \r\n)
                        auto lowline = toLower(line);

                        if (line.length == 2 && line == "\r\n")
                            inPartHeader = false;

                        else if (line.length > 13 && lowline[0..13] == "content-type:")
                        {
                            parseContentHeader((*currentPart).ctype, strip(split(line, ":")[1]));
                            writeln("ctype:", line);
                            writeln((*currentPart).ctype);
                        }
                        else if (line.length > 20 && lowline[0..20] == "content-disposition:")
                        {
                            parseContentHeader((*currentPart).disposition, strip(split(line, ":")[1]));
                            writeln("cdisposition:", line);
                            writeln((*currentPart).disposition);
                        }
                        else if (line.length > 26 && lowline[0..26] == "content-transfer-encoding:")
                        {
                            (*currentPart).content_transfer_encoding = strip(split(line, ":")[1]);
                            writeln("ctransfer: ", (*currentPart).content_transfer_encoding);
                        }
                        else
                        {
                            // text/plain doesnt need headers, can start just after the boundary
                            inPartHeader = false;
                        }
                        
                    }
                    else // in part body (not header, not boundary)
                    {
                        // Add non-boundary, non-part-header line to the part content
                        if (currentPart != null)
                            (*currentPart).content.put(line);
                    }
                }
                bodyBuffer.put(line);
            }
        }

        if (bodyHasParts)
        {
            // XXX
        }
        else // text/plain|html, just decode and set
        {
            string body_;
            if (content_transfer_encoding == "quoted-printable")
                body_ = convertToUtf8Lossy(decodeQuotedPrintable(bodyBuffer.data), 
                                           content_type.fields["charset"]);
            else if (content_transfer_encoding == "base64")
                body_ = convertToUtf8Lossy(Base64.decode(removechars(bodyBuffer.data, "\r\n")), content_type.fields["charset"]);
            else
                body_ = bodyBuffer.data;

            write(body_); // XXX
        }
    }


    void addHeader(string raw) 
    {
        auto idxSeparator = indexOf(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length)) 
            return; // Not header, probably mbox indicator or broken header
    
        string name  = raw[0..idxSeparator];
        string value = raw[idxSeparator+1..$];
        headers.addField(name, decodeEncodedWord(value));
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

                content_data.fields[param[0..eqIndex]] = param[eqIndex+1..$];
            }
        }
    }


    // content-type and content-disposition by ref, returns content-transfer-encoding
    private string getHeadersContentInfo(ref ContentData ct_type, ref ContentData ct_disp)
    {
        string ct_transfer_encoding;
        parseContentHeader(ct_type, headers.get("Content-Type", ""));
        parseContentHeader(ct_disp, headers.get("Content-Disposition", ""));

        if ("Content-Transfer-Encoding" in headers)
            ct_transfer_encoding = strip(removechars(headers["Content-Transfer-Encoding"], "\""));

        return ct_transfer_encoding;
    }


    string print_headers(bool as_string=false) 
    {
        auto textheaders = appender!string();
        foreach(string name, string value; headers) 
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
}


void main()
{

    writeln("XXX 1");
    auto email_file = File("emails/with_attachments/single_mails/5614", "r");
    writeln("XXX 0");
    auto email = new ProtoEmail(email_file);
    writeln("XXX -1");
    email.print_headers();
    writeln("XXX -2");
    // Imprimir From, To, Cc, Bcc, Data, Subject
    writeln("\n\nCommon headers:");
    writeln("To: ", email.headers.get("To", ""));
    writeln("From: ", email.headers.get("From", ""));
    writeln("Subject: ", email.headers.get("Subject", ""));
    writeln("Date: ", email.headers.get("Date", ""));
    writeln("Cc: ", email.headers.get("Cc", ""));
    writeln("Bcc: ", email.headers.get("Bcc", ""));
}


unittest
{
    /* For every mail in the testing-mails repo, parse the email, print the headers
     * and compare line by line with the (decoded) original */
    writeln("Starting unittest");
    string repodir = "emails/with_attachments/single_mails/";

    foreach (DirEntry e; dirEntries(repodir, SpanMode.shallow))
    {
        writeln(e.name);
        //if (indexOf(e.name, "7038") == -1) continue;
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
            }
            ++idx;
        }
    }
}
