#!/usr/bin/env rdmd 

import std.stdio;
import std.file: dirEntries, DirEntry, SpanMode;
import std.path;
import std.conv;
import std.string;
import std.ascii;
import std.array;

// lib.dictionarylist is vibed.utils.dictionarylist modified so it doesnt need
// vibed's event loop (with key deletions removed but we doesn't need it here)
// It's like a hash but keeping insert order and can assign multiple values to
// every key
import lib.dictionarylist;
import lib.characterencodings;

// XXX Clase para excepciones de parseo
// XXX const, immutable y toda esa mierda
// XXX mandar los fixes a Adam Druppe


// XXX class o struct?
class MIMEPart
{
    MIMEPart[] subparts;
    string type;
    wchar[] content; 
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
        bool prevWasStart = false;
        auto headerBuffer = appender!string();
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

                if (line == "\r\n") inBody = true; // Body separator

            }
            else // Body
            { 
            }

            if ("Content-Type" !in headers) 
            {
                writeln(email_file.name);
                writeln("NO TIENE CONTENT TYPE");
            }
            else
                writeln("TIENE CONTENT TYPE: ", headers["Content-Type"]);

        }
    }


    void addHeader(string raw) 
    {
        auto idxSeparator = indexOf(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length)) 
            return; // Not header, probably mbox indicator or broken header
    
        string name  = raw[0..idxSeparator];
        string value = raw[idxSeparator+1..$];
        headers.addField(name, decodeHeaderValue(value));
    }


    string decodeHeaderValue(string origValue)
    {
        return decodeEncodedWord(origValue);
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

    auto email_file = File("emails/with_attachments/single_mails/5614", "r");
    auto email = new ProtoEmail(email_file);
    email.print_headers();
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
