#!/usr/bin/env rdmd

import std.stdio;
import std.file;
import std.path;
import std.conv;
import std.string;

// XXX Clase para excepciones de parseo

class MIMEPart
{
    MIMEPart[] subparts;
    string type;
    wchar[] content; 

}

class ProtoEmail
{
    wchar[char] headers;
    MIMEPart[] parts;
    wchar[] content; // for non multipart mails

    void addHeader(string[] rawlines) 
    {
        char[] raw;
        foreach(string line; rawlines) raw ~= line;
        write(raw);

        // XXX decodificar
    }
}


void main() //test
{
    auto email_file = File("emails/with_attachments/single_mails/11", "r");

    auto email = new ProtoEmail();

    string line;
    bool inBody = false;
    bool prevWasStart = false;
    string[] headerBuffer;

    while (!email_file.eof()) 
    {
        line = email_file.readln();

        if (line == "\r\n") // Body separator
            inBody = true;

        if (!inBody) // Header
        { 

            if (prevWasStart) 
            { 
                if (line[0] == ' ') 
                    prevWasStart = false; // multiline header (first indented line)

                else 
                {
                    // Previous was a single line header and this is a new header start so add the previous
                    email.addHeader(headerBuffer);
                    headerBuffer.length = 0;
                }
                headerBuffer ~= line;
            }
            else 
            {
                if (line[0] != ' ') 
                {  // Not indented, end of multiline header, add it
                    email.addHeader(headerBuffer);
                    headerBuffer.length = 0;
                    prevWasStart = true;
                }
                headerBuffer ~= line;
            }
        }
        else // Body
        { 
        }
    }
}
