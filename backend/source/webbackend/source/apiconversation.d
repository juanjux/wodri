module webbackend.apiconversation;

import std.typecons;
import db.conversation;
import db.email: EmailSummary, Email;

final class ApiConversation
{
    EmailSummary[] summaries;
    string dbId;
    string lastDate;
    string subject;
    string[] tags;
 
    this(Conversation conv)
    {
        this.dbId     = conv.dbId;
        this.lastDate = conv.lastDate;
        this.tags     = conv.tagsArray;
        this.subject  = conv.cleanSubject;

        foreach(link; conv.links)
            if (link.emailDbId.length) 
                summaries ~= Email.getSummary(link.emailDbId);

    }
}
