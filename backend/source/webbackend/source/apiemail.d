/*
    Copyright (C) 2014-2015  Juan Jose Alvarez Martinez <juanjo@juanjoalvarez.net>

    This file is part of Wodri. Wodri is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License version 3 as published by the
    Free Software Foundation.

    This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
    without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
    See the GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License along with this
    program. If not, see <http://www.gnu.org/licenses/>.
*/
module webbackend.apiemail;

import db.config;
import db.email: Email, SendStatus;
import std.array;
import std.path: baseName;
import std.stdio;
import vibe.inet.path: joinPath;

struct ApiAttachment
{
    string Url;
    string id;
    string ctype;
    string filename;
    string contentId;
    ulong  size;
}

final class ApiEmail
{
    string id;
    string messageId;
    string from;
    string to;
    string cc;
    string bcc;
    string subject;
    string isoDate;
    string date;
    string bodyHtml;
    string bodyPlain;
    ApiAttachment[] attachments;
    bool   deleted        = false;
    bool   draft          = false;

    this() {}

    this(in Email dbEmail)
    {
        this.id         = dbEmail.id;
        this.deleted    = dbEmail.deleted;
        this.draft      = dbEmail.draft;
        this.messageId  = dbEmail.messageId;
        this.isoDate    = dbEmail.isoDate;
        this.from       = dbEmail.from.rawValue;
        this.to         = dbEmail.getHeader("to").rawValue;
        this.cc         = dbEmail.getHeader("cc").rawValue;
        this.bcc        = dbEmail.getHeader("bcc").rawValue;
        this.date       = dbEmail.getHeader("date").rawValue;
        this.subject    = dbEmail.getHeader("subject").rawValue;

        // attachments
        foreach(ref attach; dbEmail.attachments.list)
        {
            ApiAttachment att;
            att.size      = attach.size;
            att.id        = attach.id;
            att.ctype     = attach.ctype;
            att.filename  = attach.filename;
            att.contentId = attach.contentId;
            att.Url       = joinPath("/", joinPath(getConfig().URLAttachmentPath,
                                                   baseName(attach.realPath)));
            this.attachments ~= att;
        }

        // Append all parts of the same type
        Appender!string bodyPlain;
        Appender!string bodyHtml;
        foreach(ref part; dbEmail.textParts)
        {
            if (part.ctype == "text/html")
                bodyHtml.put(part.content);
            else
                bodyPlain.put(part.content);
        }
        this.bodyHtml  = bodyHtml.data;
        this.bodyPlain = bodyPlain.data;
    }
}
