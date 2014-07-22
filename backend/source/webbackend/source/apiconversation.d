module webbackend.apiconversation;

import retriever.conversation;
import retriever.db: EmailSummary, getEmailSummary;

struct ApiConversation
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
                summaries ~= getEmailSummary(link.emailDbId);

    }
}
