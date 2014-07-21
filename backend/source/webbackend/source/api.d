module webbackend.api;

import std.algorithm;
import std.typecons;
import std.array;
import std.conv;
import std.stdio;
import vibe.web.common;
import vibe.http.common;
import retriever.db;
import retriever.conversation;
import webbackend.apiconversationsummary;
import webbackend.apiconversation;


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
            // returns an ApiConversationSummary for every Conversation
            return getConversationsByTag(name, limit, page)
                   .map!(i => ApiConversationSummary(i)).array;
        }


        ApiConversation getConversation(string id)
        {
            return ApiConversation(getConversationById(id));
        }
}


