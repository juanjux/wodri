#!/usr/bin/env rdmd 

import std.stdio;
import std.file: dirEntries, DirEntry, SpanMode;
import std.path;
import std.conv;
import std.string;
import std.ascii;
import std.array;

import lib.dictionarylist;
import arsd.email;

// XXX Clase para excepciones de parseo
// XXX const, immutable y toda esa mierda
// Hash de cabecera: indice para acceso sin recorer todo


class MIMEPart
{
    MIMEPart[] subparts;
    string type;
    wchar[] content; 
}

struct Header
{
    string name;
    string value;
}

class ProtoEmail
{
    // I want to keep the insertion order unchanged, so no dict
    Header[] headers;
    // idx of these fields in the Header[] array, the properties to
    // read them will return the text
    private int m_to, m_from, m_cc, m_bcc, m_date, m_subject, m_content_type, 
                m_content_disposition, m_content_transfer_encoding;
    MIMEPart[] parts;
    dchar[] content; // for non multipart mails

    this() 
    {
        m_to = m_from = m_cc = m_bcc = m_date = m_subject = -1;
    }

    this(File emailf)
    {
        this();
        parseEmail(emailf);
    }

    @property string To()      { return m_to != -1 ?      strip(headers[m_to].value)      : ""; }
    @property string From()    { return m_from != -1 ?    strip(headers[m_from].value)    : ""; }
    @property string Cc()      { return m_cc != -1 ?      strip(headers[m_cc].value)      : ""; }
    @property string Bcc()     { return m_bcc != -1 ?     strip(headers[m_bcc].value)     : ""; }
    @property string Date()    { return m_date != -1 ?    strip(headers[m_date].value)    : ""; }
    @property string Subject() { return m_subject != -1 ? strip(headers[m_subject].value) : ""; }
    @property string ContentType() { return m_content_type != -1 ? strip(headers[m_content_type].value) : ""; }
    @property string ContentDisposition() { return m_content_disposition != -1 ? strip(headers[m_content_disposition].value) : ""; }
    @property string ContentTransferEncoding() { return m_content_transfer_encoding != -1 ? strip(headers[m_content_transfer_encoding].value) : ""; }

    @property string To(string to)
    {
        to = strip(to);
        to = " " ~ to;
        if (m_to == -1)
            headers ~= Header("To", to);
        else 
            headers[m_to].value = to;
        return to;
    }
    @property string From(string from)
    {
        from = strip(from);
        from = " " ~ from;
        if (m_from == -1)
            headers ~= Header("From", from);
        else 
            headers[m_from].value = from;
        return from;
    }
    @property string Cc(string cc)
    {
        cc = strip(cc);
        cc = " " ~ cc;
        if (m_cc == -1)
            headers ~= Header("Cc", cc);
        else 
            headers[m_cc].value = cc;
        return cc;
    }
    @property string Bcc(string bcc)
    {
        bcc = strip(bcc);
        bcc = " " ~ bcc;
        if (m_bcc == -1)
            headers ~= Header("Bcc", bcc);
        else 
            headers[m_bcc].value = bcc;
        return bcc;
    }
    @property string Date(string date)
    {
        date = strip(date);
        date = " " ~ date;
        if (m_date == -1)
            headers ~= Header("Date", date);
        else 
            headers[m_date].value = date;
        return date;
    }
    @property string Subject(string subject)
    {
        subject = strip(subject);
        subject = " " ~ subject;
        if (m_subject == -1)
            headers ~= Header("Subject", subject);
        else 
            headers[m_subject].value = subject;
        return subject;
    }
    @property string ContentType(string content_type)
    {
        content_type = strip(content_type);
        content_type = " " ~ content_type;
        if (m_content_type == -1)
            headers ~= Header("Subject", content_type);
        else 
            headers[m_content_type].value = content_type;
        return content_type;
    }
    @property string ContentDisposition(string content_disposition)
    {
        content_disposition = strip(content_disposition);
        content_disposition = " " ~ content_disposition;
        if (m_content_disposition -1)
            headers ~= Header("Subject", content_disposition);
        else 
            headers[m_content_disposition].value = content_disposition;
        return content_disposition;
    }
    @property string ContentTransferEncoding(string content_transfer_encoding)
    {
        content_transfer_encoding = strip(content_transfer_encoding);
        content_transfer_encoding = " " ~ content_transfer_encoding;
        if (m_content_transfer_encoding == -1)
            headers ~= Header("Subject", content_transfer_encoding);
        else 
            headers[m_content_transfer_encoding].value = content_transfer_encoding;
        return content_transfer_encoding;
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
        }

        // Add the index to the common headers
        foreach(int idx, Header h; headers)
        {
            switch(toLower(h.name)) 
            {
                case "from":
                    m_from = idx;
                    break;
                case "to":
                    m_to = idx;
                    break;
                case "cc":
                    m_cc = idx;
                    break;
                case "bcc":
                    m_bcc = idx;
                    break;
                case "date":
                    m_date = idx;
                    break;
                case "subject":
                    m_subject = idx;
                    break;
                case "content-type":
                    m_content_type = idx;
                default:
            }
        }
    }


    void addHeader(string raw) 
    {
        auto idxSeparator = indexOf(raw, ":");
        if (idxSeparator == -1 || (idxSeparator+1 > raw.length)) 
            return; // Not header, probably mbox indicator or broken header
    
        string name  = raw[0..idxSeparator];
        string value = raw[idxSeparator+1..$];
        headers ~= Header(name, decodeHeaderValue(value));
    }


    string decodeHeaderValue(string origValue)
    {
        return decodeEncodedWord(origValue);
    }


    string print_headers(bool as_string=false) 
    {
        string textheaders;
        foreach(Header header; headers) 
        {
            if (as_string) {
                textheaders ~= header.name ~= ":";
                textheaders ~= header.value;
            }
            else
                write(header.name, ":", header.value);
        }
        return textheaders;
    }
}


void main()
{
/*
    auto email_file = File("emails/with_attachments/single_mails/5614", "r");
    auto email = new ProtoEmail(email_file);
    email.print_headers();
    // Imprimir From, To, Cc, Bcc, Data, Subject

    writeln("\n\nCommon headers:");
    writeln("To: ", email.To);
    writeln("From: ", email.From);
    writeln("Subject: ", email.Subject);
    writeln("Date: ", email.Date);
    writeln("Cc: ", email.Cc);
    writeln("Bcc: ", email.Bcc);
*/
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
        writeln(e.name);
        writeln(email.ContentType);
        writeln;
    }
}
