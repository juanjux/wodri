import std.algorithm;
import std.conv;
import vibe.web.common;
import retriever.db;
import retriever.conversation;
import webbackend.conversationsummary;

struct Attachment
{
    string Url;
    string ctype;
    string filename;
    string contentId;
    ulong  size;
}


@rootPathFromName
interface Api
{
    ConversationSummary[] getTag(string name = "inbox", int limit = 50, int page=0);
}


class ApiImpl: Api
{
    override:
        ConversationSummary[] getTag(string name = "inbox", int limit = 50, int page=0)
        {
            ConversationSummary[] ret;
            
            auto dbConversations = getConversationsByTag(name, limit, page);
            foreach(dbConv; dbConversations)
                ret ~=  ConversationSummary(dbConv);
            return ret;
        }
}


struct MessageSummary
{
    string subject;
    string from;
    string date;
    string[] attachmentsFilenames;
    string bodyPeak;
    string avatarUrl;
}

struct Message
{
    MessageSummary apiMessageSummary;
    alias apiMessageSummary this;
    string bodyHtml;
    string bodyPlain;
    Attachment[] attachments;
}

struct Conversation
{
    MessageSummary[] summaries;
    string lastMessageDate;
    string subject;
    string[] tags;
    string[] attachmentsFilenames;

    this(string subject, string[] tags, ref MessageSummary[] summaries)
    {
        this.summaries = summaries;

        foreach(msgSummary; summaries)
        {
            this.lastMessageDate = max(this.lastMessageDate, msgSummary.date);
            attachmentsFilenames ~= msgSummary.attachmentsFilenames;
        }
    }
}

