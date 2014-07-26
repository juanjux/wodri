module webbackend.apiconversation;

import db.conversation;
import db.email: EmailSummary, Email;

class ApiConversation
{
    EmailSummary[] summaries;
    string lastDate;
    string subject;
    string[] tags;
 
    this(Conversation conv)
    {
        this.lastDate = conv.lastDate;
        this.tags = conv.tags;
        this.subject = conv.cleanSubject;

        foreach(link; conv.links)
            if (link.emailDbId.length)
                summaries ~= Email.getSummary(link.emailDbId);

    }
}
