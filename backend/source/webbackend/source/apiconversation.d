module webbackend.apiconversation;

import std.typecons;
import db.conversation;
import db.email: EmailSummary, Email;

final class ApiConversation
{
    EmailSummary[] summaries;
    string lastDate;
    string subject;
    string[] tags;
 
    this(Conversation conv, bool loadDeleted = false)
    {
        this.lastDate = conv.lastDate;
        this.tags = conv.tags;
        this.subject = conv.cleanSubject;

        foreach(link; conv.links)
            if (link.emailDbId.length && (loadDeleted || !link.deleted))
                summaries ~= Email.getSummary(link.emailDbId);

    }
}
