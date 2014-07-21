module webbackend.apiconversation;

import std.regex;
import retriever.conversation;
import retriever.db: EmailSummary, getEmailSummary;

auto SUBJECT_CLEAN_REGEX = ctRegex!(r"([\[\(] *)?(RE?) *([-:;)\]][ :;\])-]*|$)|\]+ *$", "gi");
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

        foreach(link; conv.links)
        {
            if (link.emailDbId.length)
            {
                auto emailSummary = getEmailSummary(link.emailDbId);
                auto filteredSubject = replaceAll!(x => "")(emailSummary.subject,
                                                           SUBJECT_CLEAN_REGEX);
                if (!this.subject.length && filteredSubject.length)
                    this.subject = filteredSubject;
                // some bytes less to send (it's the ApiConv.subject)
                emailSummary.subject = "";
                summaries ~= emailSummary;
            }
        }

    }
}
