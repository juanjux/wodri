module webbackend.apiconversation;

import std.typecons;
import db.conversation;
import db.email: EmailSummary, Email;

final class ApiConversation
{
    EmailSummary[] summaries;
    string id;
    string lastDate;
    string subject;
    string[] tags;

    this(Conversation conv)
    {
        this.id     = conv.id;
        this.lastDate = conv.lastDate;
        this.tags     = conv.tagsArray;
        this.subject  = conv.cleanSubject;

        foreach(link; conv.links)
        {
            if (link.emailDbId.length)
            {
                summaries ~= Email.getSummary(link.emailDbId);
            }
        }
    }
}
