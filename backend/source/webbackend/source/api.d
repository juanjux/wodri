module api;

import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import vibe.web.common;
import vibe.http.common;
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

struct MessageSummary
{
    string subject;
    string from;
    string date;
    string[] attachFileNames;
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
    string[] attachFileNames;

    this(string subject, string[] tags, MessageSummary[] summaries)
    {
        this.subject = subject; // XXX clean it?
        this.summaries = summaries;

        string lastDate;
        string[] attFileNames;
        foreach(msgSummary; summaries)
        {
            lastDate = max(this.lastMessageDate, msgSummary.date);
            attFileNames ~= msgSummary.attachFileNames;
        }
        this.lastMessageDate = lastDate;
        this.attachFileNames = attFileNames;
    }
}


@rootPathFromName
interface Api
{
    @method(HTTPMethod.GET) @path("tag/")
    ConversationSummary[] getTagConversations(string name, int limit=50, int page=0);
}


class ApiImpl: Api
{
    override:
        ConversationSummary[] getTagConversations(string name, 
                                                  int limit=50, 
                                                  int page=0)
        {
            ConversationSummary[] ret;
            auto dbConversations = getConversationsByTag(name, limit, page);
            foreach(dbConv; dbConversations)
                ret ~=  ConversationSummary(dbConv);
            return ret;
        }
}


