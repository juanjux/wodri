module webbackend.api;

import std.algorithm;
import std.typecons;
import std.regex; // XXX quitar cuando se saque ApiConversation
import std.array;
import std.conv;
import std.stdio;
import vibe.web.common;
import vibe.http.common;
import retriever.db;
import retriever.conversation;
import webbackend.apiconversationsummary;


struct ApiAttachment
{
    string Url;
    string ctype;
    string filename;
    string contentId;
    ulong  size;
}

struct ApiEmail
{
    EmailSummary emailSummary;
    alias  emailSummary this;
    string bodyHtml;
    string bodyPlain;
    ApiAttachment[] attachments;
}

// XXX mover a su propio fichero
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


@rootPathFromName
interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ApiConversationSummary[] getTagConversations(string name, int limit=50, int page=0);
    @method(HTTPMethod.GET) @path("conversation/")
    ApiConversation getConversation(string id);
}


class ApiImpl: Api
{
    override:
        ApiConversationSummary[] getTagConversations(string name,
                                                     int limit=50,
                                                     int page=0)
        {
            ApiConversationSummary[] ret;
            auto dbConversations = getConversationsByTag(name, limit, page);
            foreach(dbConv; dbConversations)
                ret ~= ApiConversationSummary(dbConv);
            return ret;
        }

        
        ApiConversation getConversation(string id)
        {
            return ApiConversation(getConversationById(id));
        }
}


