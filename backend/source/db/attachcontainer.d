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
module db.attachcontainer;

import db.config;
import retriever.incomingemail: Attachment;
import std.path;
import std.array;
import std.typecons;
import std.stdio;
import webbackend.apiemail;
import vibe.data.json;

struct DbAttachment
{
    Attachment attachment;
    alias attachment this;
    string id;

    this(Attachment attach)
    {
        this.attachment = attach;
    }

    this (ApiAttachment apiAttach)
    {
        this.id                 = apiAttach.id;
        this.attachment.ctype     = apiAttach.ctype;
        this.attachment.filename  = apiAttach.filename;
        this.attachment.contentId = apiAttach.contentId;
        this.attachment.size      = apiAttach.size;
        this.attachment.realPath  = buildPath(getConfig.absAttachmentStore,
                                              baseName(apiAttach.Url));
    }


    string toJson() const
    {
        Appender!string jsonAppender;
        jsonAppender.put(`{"contentType": `   ~ Json(this.ctype).toString     ~ `,` ~
                         ` "realPath": `      ~ Json(this.realPath).toString  ~ `,` ~
                         ` "id": `          ~ Json(this.id).toString      ~ `,` ~
                         ` "size": `          ~ Json(this.size).toString      ~ `,`);
        if (this.contentId.length)
            jsonAppender.put(` "contentId": ` ~ Json(this.contentId).toString ~ `,`);
        if (this.filename.length)
            jsonAppender.put(` "fileName": `  ~ Json(this.filename).toString  ~ `,`);
        jsonAppender.put("}");
        return jsonAppender.data;
    }
}


struct AttachContainer
{
    private DbAttachment[] m_attachs;

    // FIXME: implement the range interface
    @property const(DbAttachment[]) list() const
    nothrow
    {
        return m_attachs;
    }

    @property ulong length() const
    nothrow
    {
        return m_attachs.length;
    }


    ulong totalSize() const
    nothrow
    {
        ulong totalSize;
        foreach(ref attachment; m_attachs)
            totalSize += attachment.size;
        return totalSize;
    }


    const(DbAttachment) add(T)(const ref T attach, in string id="")
    if (is(T: ApiAttachment) || is(T: Attachment))
    {
        auto dbattach = DbAttachment(attach);
        if (id.length)
            dbattach.id = id;
        this.m_attachs ~= dbattach;
        return this.m_attachs[$-1];
    }

    const(DbAttachment) add(const ref DbAttachment attach)
    {
        this.m_attachs ~= attach;
        return this.m_attachs[$-1];
    }


    string toJson() const
    {
        Appender!string jsonAppender;
        foreach(const ref attach; this.m_attachs)
            jsonAppender.put(attach.toJson ~ ",");
        return jsonAppender.data;
    }
}
